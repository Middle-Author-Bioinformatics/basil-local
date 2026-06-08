#!/usr/bin/env bash
# scraper.sh — tower-side worker for the BASIL Web Server.
#
# Polls the BASIL S3 input bucket for new slug prefixes, runs the BASIL
# pipeline on each, and uploads results to the S3 results bucket.
#
# Hard-coded for Middle Author Bioinformatics' tower (`BIOD2014` / Ark's box).
# Just run it:
#
#     bash /home/ark/MAB/bin/basil_webapp/pipeline/scraper_example.sh
#
# Or drop it into cron (every 5 minutes):
#
#     */5 * * * *  /usr/bin/bash /home/ark/MAB/bin/basil_webapp/pipeline/scraper_example.sh \
#                     >> /var/log/basil-scraper.log 2>&1
#
# Prerequisites on the tower:
#   * `aws` CLI installed and `aws s3 ls s3://midauthorbio-basil-input/` works
#     under the user that runs this script (configure via `aws configure`).
#   * The `basil-webapp` mamba env is activated (or `BASIL_PYTHON` below is set
#     to the env's python). The script tries to activate it itself.
#   * BASIL-public is at the path in BASIL_PUBLIC_DIR below, with the
#     env-driven myConstant.py already copied into main_scripts/.

set -euo pipefail

# ─── Hard-coded configuration ────────────────────────────────────────────────
BASIL_INPUT_BUCKET="midauthorbio-basil-input"
BASIL_RESULTS_BUCKET="midauthorbio-basil-results"
AWS_REGION="us-east-2"

BASIL_PUBLIC_DIR="/home/ark/MAB/bin/BASIL-public"

# Where this script + run_pipeline.py + manifest_txt_to_json.py live.
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local scratch space for in-flight jobs (output dirs, logs, etc.).
BASIL_WORK_ROOT="/home/ark/MAB/basil_work"

# Conda env name. The script will try to activate it before running BASIL.
# This env has the BASIL deps (Python 3.9, pystan, R packages, awscli, etc.).
CONDA_ENV="py_3_9"
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$BASIL_WORK_ROOT"
DONE_DIR="$BASIL_WORK_ROOT/.done"
mkdir -p "$DONE_DIR"

# Activate the conda env so `Rscript`, `python`, and BASIL's deps are on PATH.
# We use the conda shell hook so this works from cron too (where ~/.bashrc
# isn't sourced).
if command -v conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook)"
    conda activate "$CONDA_ENV" 2>/dev/null || \
        echo "[scraper] WARNING: could not conda-activate $CONDA_ENV; proceeding with current PATH"
elif command -v mamba >/dev/null 2>&1; then
    eval "$(mamba shell hook --shell bash)"
    mamba activate "$CONDA_ENV" 2>/dev/null || \
        echo "[scraper] WARNING: could not mamba-activate $CONDA_ENV; proceeding with current PATH"
else
    echo "[scraper] WARNING: neither conda nor mamba on PATH; assuming env is already active"
fi

export AWS_DEFAULT_REGION="$AWS_REGION"

ts() { date -u +%FT%TZ; }

# Look for new slug prefixes by listing the bucket at depth 1.
mapfile -t slugs < <(
    aws s3api list-objects-v2 \
        --bucket "$BASIL_INPUT_BUCKET" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null \
        | tr '\t' '\n' \
        | sed 's:/$::' \
        | sort
)

if [[ ${#slugs[@]} -eq 0 || -z "${slugs[0]:-}" ]]; then
    echo "[scraper] $(ts) — no slugs in s3://$BASIL_INPUT_BUCKET/"
    exit 0
fi

for slug in "${slugs[@]}"; do
    [[ -z "$slug" || "$slug" == "None" ]] && continue
    if [[ -e "$DONE_DIR/$slug" ]]; then
        continue          # already processed in a previous run
    fi

    # Require manifest.txt before we claim the slug, so we don't race against
    # an in-flight upload from the SPA.
    if ! aws s3api head-object \
            --bucket "$BASIL_INPUT_BUCKET" \
            --key "$slug/manifest.txt" >/dev/null 2>&1; then
        echo "[scraper] $slug — manifest.txt not yet uploaded, skipping"
        continue
    fi

    echo "[scraper] $(ts) — processing $slug"
    workdir="$BASIL_WORK_ROOT/$slug"
    raw_counts="$workdir/raw_counts"
    mkdir -p "$raw_counts"

    # 1. Download everything for this slug into raw_counts/.
    aws s3 sync "s3://$BASIL_INPUT_BUCKET/$slug/" "$raw_counts/" --quiet

    # 2. Convert manifest.txt -> manifest.json for run_pipeline.py.
    python3 "$PIPELINE_DIR/manifest_txt_to_json.py" \
        --in  "$raw_counts/manifest.txt" \
        --out "$workdir/manifest.json"

    # 3. Publish an immediate "running" status.json so the SPA stops showing
    #    the "waiting for tower" message.
    cat > "$workdir/status.json" <<JSON
{"slug":"$slug","state":"running","current_step":"preprocess",
 "started_at":"$(ts)",
 "steps":{"preprocess":{"state":"running","started_at":"$(ts)"},
          "basil_inference":{"state":"pending"},
          "visualization":{"state":"pending"}}}
JSON
    aws s3 cp "$workdir/status.json" \
        "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" \
        --content-type application/json --quiet

    # 4. Run the pipeline (this writes its own status.json updates).
    pipeline_ok=0
    if python3 "$PIPELINE_DIR/run_pipeline.py" \
            --job-dir "$workdir" \
            --basil-public "$BASIL_PUBLIC_DIR"; then
        echo "[scraper] $slug — pipeline succeeded"
        pipeline_ok=1
    else
        echo "[scraper] $slug — pipeline FAILED (uploading any partial artifacts)"
    fi

    # 5. Upload everything the SPA needs to render results.
    if [[ -f "$workdir/status.json" ]]; then
        aws s3 cp "$workdir/status.json" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" \
            --content-type application/json --quiet || true
    fi
    if [[ -d "$workdir/basil_plots" ]]; then
        aws s3 sync "$workdir/basil_plots/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/basil_plots/" --quiet
    fi
    if [[ -d "$workdir/logs" ]]; then
        aws s3 sync "$workdir/logs/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/logs/" \
            --content-type text/plain --quiet
    fi

    # 6. Mark this slug done so we don't reprocess it.
    if [[ $pipeline_ok -eq 1 ]]; then
        touch "$DONE_DIR/$slug"
    else
        # Even on failure, mark done so we don't spin forever. Delete the
        # marker manually (rm "$DONE_DIR/$slug") to re-attempt the slug.
        touch "$DONE_DIR/$slug"
    fi

    # Optional cleanup once you've confirmed the results landed in S3:
    # aws s3 rm "s3://$BASIL_INPUT_BUCKET/$slug/" --recursive
done

echo "[scraper] $(ts) — done."