#!/usr/bin/env python3
"""
Convert the SPA's plain-text manifest.txt into the manifest.json shape
run_pipeline.py expects.

Input format (see frontend/src/lib/basil-config.ts → buildManifest):

    # BASIL run manifest
    slug: hgEhE6fdpk
    submitted_at: 2026-06-07T16:58:23.711Z
    run_name: NDM_BC_replicate_2
    input_type: bartender
    dilution_factor: 7.5
    first_timepoint_to_keep: 1
    basil_public_dir: /opt/BASIL-public
    # samples — file_name,carrying_capacity
    NBC1.csv,50000000
    NDM1.csv,100000000
"""
import argparse
import json
import sys
from pathlib import Path


def parse(text: str) -> dict:
    out = {
        "samples": [],
        "threads_per_sample": 12,
        "parallel_samples": 1,
    }
    in_samples = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("# samples"):
            in_samples = True
            continue
        if line.startswith("#"):
            continue
        if not in_samples and ":" in line:
            k, _, v = line.partition(":")
            k = k.strip().lower()
            v = v.strip()
            if k in ("dilution_factor",):
                out[k] = float(v)
            elif k in ("first_timepoint_to_keep",):
                out[k] = int(v)
            elif k in ("slug", "run_name", "input_type", "basil_public_dir",
                       "submitted_at"):
                out["job_id" if k == "slug" else k] = v
        elif in_samples and "," in line:
            file_name, _, cc = line.partition(",")
            file_name = file_name.strip()
            cc = cc.strip()
            if not file_name or not cc:
                continue
            out["samples"].append({
                "file_name": file_name,
                "carrying_capacity": float(cc),
            })
    if "input_type" not in out:
        out["input_type"] = "bartender"
    if "dilution_factor" not in out:
        out["dilution_factor"] = 7.5
    if "first_timepoint_to_keep" not in out:
        out["first_timepoint_to_keep"] = 1
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in",  dest="src", required=True, type=Path)
    ap.add_argument("--out", dest="dst", required=True, type=Path)
    args = ap.parse_args(argv)
    text = args.src.read_text()
    data = parse(text)
    args.dst.write_text(json.dumps(data, indent=2))
    print(f"wrote {args.dst} with {len(data['samples'])} sample(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
