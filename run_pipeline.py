#!/usr/bin/env python3
"""
run_pipeline.py — end-to-end BASIL pipeline runner for the web app.

Given a job directory pulled from S3 that contains:

  job_dir/
    manifest.json          # job-level config (see schema below)
    raw_counts/            # uploaded bartender / barcodeCounter files

…this script runs the full pipeline locally (no SLURM):

  1. bar2basil.R           -> writes basil_input/ + input.csv
  2. patch input.csv       -> per-sample carrying_capacity / D from manifest
  3. basil_dispatcher.sh   -> runs BASIL per sample (sequential or parallel)
  4. basilHelper.v2.R      -> trajectory, interval, DFE plots
  5. status.json           -> machine-readable progress for the API

Status JSON is rewritten after every meaningful step so the web UI can poll it.

Usage:
    run_pipeline.py --job-dir /path/to/job_xxxx [--basil-public /path/to/BASIL-public]

manifest.json schema:
{
  "job_id": "string",
  "input_type": "bartender" | "barcodeCounter",
  "dilution_factor": 7.5,
  "first_timepoint_to_keep": 1,
  "threads_per_sample": 12,
  "parallel_samples": 1,
  "basil_public_dir": "/opt/BASIL-public",     # optional override
  "samples": [
    {"file_name": "NBC1.csv",       "carrying_capacity": 5e7, "dilution_factor": 7.5},
    {"file_name": "NDM1.csv",       "carrying_capacity": 5e7}
  ]
}
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Any

PIPELINE_DIR = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# Status tracking
# ---------------------------------------------------------------------------
class Status:
    def __init__(self, job_dir: Path) -> None:
        self.path = job_dir / "status.json"
        self.data: dict[str, Any] = {
            "job_id": job_dir.name,
            "state": "pending",          # pending | running | succeeded | failed
            "current_step": None,
            "steps": {
                "preprocess":     {"state": "pending", "log": "preprocess.log"},
                "basil_inference":{"state": "pending", "log": "basil.log",
                                   "samples": {}},
                "visualization":  {"state": "pending", "log": "visualize.log"},
            },
            "started_at": None,
            "finished_at": None,
            "error": None,
            "outputs": {},
        }
        if self.path.exists():
            try:
                self.data.update(json.loads(self.path.read_text()))
            except Exception:
                pass
        self.save()

    def save(self) -> None:
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.data, indent=2, default=str))
        tmp.replace(self.path)

    def set(self, **kw: Any) -> None:
        self.data.update(kw)
        self.save()

    def step(self, name: str, **kw: Any) -> None:
        self.data["steps"][name].update(kw)
        if kw.get("state") == "running":
            self.data["current_step"] = name
        self.save()


# ---------------------------------------------------------------------------
# Subprocess helper that streams stdout/stderr to a log file
# ---------------------------------------------------------------------------
def run(cmd: list[str], log_path: Path, cwd: Path | None = None,
        env: dict[str, str] | None = None) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as log:
        log.write(f"\n$ {' '.join(cmd)}\n")
        log.write(f"  cwd={cwd}\n")
        log.write(f"  started={dt.datetime.utcnow().isoformat()}Z\n")
        log.flush()
        proc = subprocess.Popen(
            cmd, cwd=cwd, env={**os.environ, **(env or {})},
            stdout=log, stderr=subprocess.STDOUT, text=True,
        )
        rc = proc.wait()
        log.write(f"  finished={dt.datetime.utcnow().isoformat()}Z exit={rc}\n")
    return rc


# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------
def load_manifest(job_dir: Path) -> dict[str, Any]:
    mf = job_dir / "manifest.json"
    if not mf.exists():
        raise FileNotFoundError(f"manifest.json not found in {job_dir}")
    return json.loads(mf.read_text())


def patch_input_csv(csv_path: Path, samples: list[dict[str, Any]],
                    default_D: float) -> None:
    """Fill in carrying_capacity (and override D if the sample provides one).
    Matches by basil-stem: 'NBC1.csv' -> 'NBC1_basil.txt'."""
    by_stem: dict[str, dict[str, Any]] = {}
    for s in samples:
        stem = Path(s["file_name"]).stem
        by_stem[f"{stem}_basil.txt"] = s

    rows: list[list[str]] = []
    with csv_path.open() as f:
        reader = csv.reader(f)
        header = next(reader)
        rows.append(header)
        for row in reader:
            if not row or not row[0]:
                continue
            file_name = row[0]
            entry = by_stem.get(file_name)
            if entry is None:
                rows.append(row)
                continue
            # row = [file_name, barcodes, D, carrying_capacity]
            if "dilution_factor" in entry and entry["dilution_factor"] is not None:
                row[2] = str(entry["dilution_factor"])
            else:
                row[2] = str(default_D)
            cc = entry.get("carrying_capacity")
            if cc is not None and cc != "":
                row[3] = str(int(float(cc))) if float(cc).is_integer() else str(cc)
            rows.append(row)

    with csv_path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows)


# ---------------------------------------------------------------------------
# Step implementations
# ---------------------------------------------------------------------------
def step_preprocess(job_dir: Path, manifest: dict[str, Any],
                    status: Status) -> Path:
    status.step("preprocess", state="running",
                started_at=dt.datetime.utcnow().isoformat() + "Z")

    raw_dir = job_dir / "raw_counts"
    basil_input_dir = job_dir / "basil_input"
    basil_input_dir.mkdir(exist_ok=True)
    log = job_dir / "logs" / "preprocess.log"

    cmd = [
        "Rscript", str(PIPELINE_DIR / "bar2basil.R"),
        "-i", str(raw_dir),
        "-o", str(basil_input_dir),
        "-D", str(manifest.get("dilution_factor", 7.5)),
        "-y", manifest.get("input_type", "bartender"),
    ]
    if manifest.get("first_timepoint_to_keep"):
        cmd += ["-t", str(int(manifest["first_timepoint_to_keep"]))]

    rc = run(cmd, log)
    if rc != 0:
        status.step("preprocess", state="failed", exit_code=rc,
                    finished_at=dt.datetime.utcnow().isoformat() + "Z")
        raise RuntimeError(f"bar2basil.R failed (exit={rc}). See {log}")

    csv_path = basil_input_dir / "input.csv"
    if not csv_path.exists():
        status.step("preprocess", state="failed",
                    finished_at=dt.datetime.utcnow().isoformat() + "Z")
        raise RuntimeError(f"bar2basil.R did not produce {csv_path}")

    patch_input_csv(csv_path, manifest["samples"],
                    float(manifest.get("dilution_factor", 7.5)))
    status.step("preprocess", state="succeeded",
                finished_at=dt.datetime.utcnow().isoformat() + "Z")
    return basil_input_dir


def step_basil(job_dir: Path, manifest: dict[str, Any], basil_input_dir: Path,
               basil_public: Path, status: Status) -> Path:
    status.step("basil_inference", state="running",
                started_at=dt.datetime.utcnow().isoformat() + "Z")
    log = job_dir / "logs" / "basil.log"
    output_dir = basil_input_dir / "output"
    output_dir.mkdir(exist_ok=True)

    # Mark all known samples as queued so the UI can render rows.
    samples_state = status.data["steps"]["basil_inference"]["samples"]
    with (basil_input_dir / "input.csv").open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            fname = row.get("file_name") or ""
            if not fname:
                continue
            case = Path(fname).stem
            if case.endswith("_basil"):
                case = case[: -len("_basil")]
            if row.get("carrying_capacity"):
                samples_state.setdefault(case, {"state": "queued"})
            else:
                samples_state.setdefault(case, {"state": "skipped",
                                                "reason": "empty carrying_capacity"})
    status.save()

    env = {
        "BASIL_THREADS": str(manifest.get("threads_per_sample", 12)),
        "BASIL_PARALLEL_SAMPLES": str(manifest.get("parallel_samples", 1)),
        "BASIL_PYTHON": manifest.get("basil_python", "python"),
        "BASIL_LOG_DIR": str(job_dir / "logs" / "basil_samples"),
    }
    rc = run(
        [str(PIPELINE_DIR / "basil_dispatcher.sh"),
         str(basil_input_dir),
         str(basil_input_dir / "input.csv"),
         str(basil_public)],
        log, env=env,
    )

    # Reconcile per-sample state from log files written by the dispatcher.
    sample_log_dir = job_dir / "logs" / "basil_samples"
    if sample_log_dir.exists():
        for log_file in sample_log_dir.glob("*.log"):
            case = log_file.stem
            text = log_file.read_text()
            if "exit_code   : 0" in text:
                samples_state[case] = {"state": "succeeded", "log": log_file.name}
            elif "exit_code" in text:
                samples_state[case] = {"state": "failed", "log": log_file.name}
            else:
                samples_state[case] = {"state": "running", "log": log_file.name}
    status.save()

    if rc != 0:
        status.step("basil_inference", state="failed", exit_code=rc,
                    finished_at=dt.datetime.utcnow().isoformat() + "Z")
        raise RuntimeError(f"basil_dispatcher.sh failed (exit={rc}). See {log}")

    status.step("basil_inference", state="succeeded",
                finished_at=dt.datetime.utcnow().isoformat() + "Z")
    return output_dir


def step_visualize(job_dir: Path, basil_input_dir: Path, output_dir: Path,
                   status: Status) -> Path:
    status.step("visualization", state="running",
                started_at=dt.datetime.utcnow().isoformat() + "Z")
    plots_dir = job_dir / "basil_plots"
    plots_dir.mkdir(exist_ok=True)
    log = job_dir / "logs" / "visualize.log"
    rc = run(
        ["Rscript", str(PIPELINE_DIR / "basilHelper.v2.R"),
         "-f", str(basil_input_dir),
         "-c", str(basil_input_dir),
         "-b", str(output_dir),
         "-o", str(plots_dir)],
        log,
    )
    if rc != 0:
        status.step("visualization", state="failed", exit_code=rc,
                    finished_at=dt.datetime.utcnow().isoformat() + "Z")
        raise RuntimeError(f"basilHelper.v2.R failed (exit={rc}). See {log}")
    status.step("visualization", state="succeeded",
                finished_at=dt.datetime.utcnow().isoformat() + "Z")
    return plots_dir


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--job-dir", required=True,
                    help="Per-job working directory (contains manifest.json + raw_counts/)")
    ap.add_argument("--basil-public", default=os.environ.get("BASIL_PUBLIC_DIR"),
                    help="Path to cloned BASIL-public directory")
    args = ap.parse_args(argv)

    job_dir = Path(args.job_dir).resolve()
    if not job_dir.exists():
        print(f"job-dir does not exist: {job_dir}", file=sys.stderr)
        return 2
    (job_dir / "logs").mkdir(exist_ok=True)

    status = Status(job_dir)
    status.set(state="running",
               started_at=dt.datetime.utcnow().isoformat() + "Z",
               error=None)

    try:
        manifest = load_manifest(job_dir)
        # basil_public = Path(args.basil_public or manifest.get("basil_public_dir")
        #                     or "/opt/BASIL-public").resolve()

        # basil_public = '/home/ark/MAB/bin/BASIL-public'
        # if not basil_public.exists():
        #     raise RuntimeError(f"basil_public directory does not exist: {basil_public}")

        basil_public = Path(
            args.basil_public
            or manifest.get("basil_public_dir")
            or "/home/ark/MAB/bin/BASIL-public"
        ).resolve()

        if not basil_public.exists():
            raise RuntimeError(f"basil_public directory does not exist: {basil_public}")

        basil_input_dir = step_preprocess(job_dir, manifest, status)
        output_dir = step_basil(job_dir, manifest, basil_input_dir,
                                basil_public, status)
        plots_dir = step_visualize(job_dir, basil_input_dir, output_dir, status)

        # Index produced artifacts so the API can list them without globbing.
        outputs: dict[str, list[str]] = {"tealeaves": [], "interval_plots_CF6": [],
                                          "DFE_plots": [], "tables": []}
        for sub, key in (("tealeaves", "tealeaves"),
                          ("interval_plots_CF6", "interval_plots_CF6"),
                          ("DFE_plots", "DFE_plots")):
            d = plots_dir / sub
            if d.exists():
                outputs[key] = sorted(p.name for p in d.iterdir() if p.is_file())
        for f in plots_dir.glob("*.csv"):
            outputs["tables"].append(f.name)

        status.set(state="succeeded",
                   finished_at=dt.datetime.utcnow().isoformat() + "Z",
                   current_step=None,
                   outputs=outputs)
        return 0

    except Exception as e:
        tb = traceback.format_exc()
        (job_dir / "logs" / "pipeline.error").write_text(tb)
        status.set(state="failed",
                   finished_at=dt.datetime.utcnow().isoformat() + "Z",
                   error=str(e))
        print(tb, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
