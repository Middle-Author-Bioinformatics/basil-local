#!/usr/bin/env bash
# scraper.sh — tower-side worker for the BASIL Web Server.
#
# Polls the BASIL S3 input bucket for new slug prefixes, runs the BASIL
# pipeline on each, and uploads results to the S3 results bucket.
#
# Hard-coded for Middle Author Bioinformatics' tower (TheBelly / Ark's box).
# Just run it:
#
#     bash /home/ark/MAB/bin/basil_webapp/pipeline/scraper_example.sh
#
# Or drop it into cron (every 5 minutes):
#
#     */5 * * * *  /usr/bin/bash /home/ark/MAB/bin/basil_webapp/pipeline/scraper_example.sh \
#                     >> /home/ark/MAB/basil_work/scraper.log 2>&1
#
# All paths to the basil env's binaries are hard-coded below — we do NOT use
# `conda activate` because Ark's shell PATH is poisoned (btex-hmm wins
# regardless of which env you "activate"). Bypassing activation is the only
# reliable way.

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

# Absolute paths into the `basil` micromamba env. Edit BASIL_ENV_BIN if your
# env lives elsewhere (find it with: ls ~/micromamba/envs/).
BASIL_ENV_BIN="/home/ark/micromamba/envs/basil/bin"
PYTHON="$BASIL_ENV_BIN/python"
RSCRIPT="$BASIL_ENV_BIN/Rscript"
AWS="$BASIL_ENV_BIN/aws"
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$BASIL_WORK_ROOT"
DONE_DIR="$BASIL_WORK_ROOT/.done"
mkdir -p "$DONE_DIR"

# Put the basil env's bin/ first on PATH so any subprocess (bar2basil.R
# calling system(), run_pipeline.py invoking Rscript, etc.) picks up the
# right tools.
export PATH="$BASIL_ENV_BIN:$PATH"
export AWS_DEFAULT_REGION="$AWS_REGION"

for bin in "$PYTHON" "$RSCRIPT" "$AWS"; do
    if [[ ! -x "$bin" ]]; then
        echo "[scraper] FATAL: missing or non-executable: $bin" >&2
        echo "          Edit BASIL_ENV_BIN at the top of this script." >&2
        exit 2
    fi
done

ts() { date -u +%FT%TZ; }

echo "[scraper] $(ts) — aws=$AWS"
echo "[scraper] $(ts) — python=$PYTHON"
echo "[scraper] $(ts) — Rscript=$RSCRIPT"

# Look for new slug prefixes by listing the bucket at depth 1.
# Do NOT swallow stderr — if creds/perms/region are wrong, we want to see it.
list_out="$("$AWS" s3api list-objects-v2 \
    --bucket "$BASIL_INPUT_BUCKET" \
    --delimiter "/" \
    --query 'CommonPrefixes[].Prefix' \
    --output text 2>&1)" || {
    echo "[scraper] FATAL: list-objects-v2 failed:" >&2
    echo "$list_out" >&2
    exit 2
}

mapfile -t slugs < <(
    printf '%s\n' "$list_out" \
        | tr '\t' '\n' \
        | sed 's:/$::' \
        | sort
)

if [[ ${#slugs[@]} -eq 0 || -z "${slugs[0]:-}" || "${slugs[0]}" == "None" ]]; then
    echo "[scraper] $(ts) — no slug prefixes found under s3://$BASIL_INPUT_BUCKET/"
    echo "[scraper]    aws returned: ${list_out:-(empty)}"
    exit 0
fi

for slug in "${slugs[@]}"; do
    [[ -z "$slug" || "$slug" == "None" ]] && continue
    if [[ -e "$DONE_DIR/$slug" ]]; then
        continue          # already processed in a previous run
    fi

    # Require manifest.txt before claiming the slug, to avoid racing with an
    # in-flight upload from the SPA.
    if ! "$AWS" s3api head-object \
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
    "$AWS" s3 sync "s3://$BASIL_INPUT_BUCKET/$slug/" "$raw_counts/" --quiet

    # 2. Convert manifest.txt -> manifest.json for run_pipeline.py.
    "$PYTHON" "$PIPELINE_DIR/manifest_txt_to_json.py" \
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
    "$AWS" s3 cp "$workdir/status.json" \
        "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" \
        --content-type application/json --quiet

    # 4. Run the pipeline (this writes its own status.json updates).
    pipeline_ok=0
    if "$PYTHON" "$PIPELINE_DIR/run_pipeline.py" \
            --job-dir "$workdir" \
            --basil-public "$BASIL_PUBLIC_DIR"; then
        echo "[scraper] $slug — pipeline succeeded"
        pipeline_ok=1
    else
        echo "[scraper] $slug — pipeline FAILED (uploading any partial artifacts)"
    fi

    # 5. Upload everything the SPA needs to render results.
    if [[ -f "$workdir/status.json" ]]; then
        "$AWS" s3 cp "$workdir/status.json" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" \
            --content-type application/json --quiet || true
    fi
    if [[ -d "$workdir/basil_plots" ]]; then
        "$AWS" s3 sync "$workdir/basil_plots/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/basil_plots/" --quiet
    fi
    if [[ -d "$workdir/logs" ]]; then
        "$AWS" s3 sync "$workdir/logs/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/logs/" \
            --content-type text/plain --quiet
    fi

    # 6. Mark this slug done so we don't reprocess it.
    touch "$DONE_DIR/$slug"

    # Optional cleanup once you've confirmed the results landed in S3:
    # "$AWS" s3 rm "s3://$BASIL_INPUT_BUCKET/$slug/" --recursive
done

echo "[scraper] $(ts) — done."