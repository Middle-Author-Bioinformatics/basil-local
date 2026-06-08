#!/usr/bin/env bash
# scraper_example.sh — tower-side cron worker for the BASIL Web Server.
#
# Run on your tower (cron every 5 min, systemd timer, while-true loop, …).
# Polls the S3 input bucket for new slug prefixes, runs run_pipeline.py on
# each, and uploads results to the S3 results bucket.
#
# Required env vars:
#   AWS_PROFILE / AWS_*       AWS credentials for the tower
#   BASIL_INPUT_BUCKET        S3 bucket the SPA uploads into
#   BASIL_RESULTS_BUCKET      S3 bucket the SPA reads results from
#   BASIL_PUBLIC_DIR          path to your BASIL-public clone
#   BASIL_WORK_ROOT           local working dir for in-flight jobs
#   PIPELINE_DIR              path to this scripts dir
#
# Example crontab:
#   */5 * * * *  AWS_PROFILE=basil BASIL_INPUT_BUCKET=basil-input \
#                BASIL_RESULTS_BUCKET=basil-results \
#                BASIL_PUBLIC_DIR=/opt/BASIL-public \
#                BASIL_WORK_ROOT=/srv/basil/work \
#                PIPELINE_DIR=/opt/basil_webapp/pipeline \
#                bash /opt/basil_webapp/pipeline/scraper_example.sh \
#                  >> /var/log/basil-scraper.log 2>&1

set -euo pipefail

: "${BASIL_INPUT_BUCKET:?required}"
: "${BASIL_RESULTS_BUCKET:?required}"
: "${BASIL_PUBLIC_DIR:?required}"
: "${BASIL_WORK_ROOT:?required}"
: "${PIPELINE_DIR:?required}"

mkdir -p "$BASIL_WORK_ROOT"

# Cache of already-processed slugs (one file per slug under .done/).
DONE_DIR="$BASIL_WORK_ROOT/.done"
mkdir -p "$DONE_DIR"

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
    echo "[scraper] $(date -u +%FT%TZ) — no slugs in s3://$BASIL_INPUT_BUCKET/"
    exit 0
fi

for slug in "${slugs[@]}"; do
    [[ -z "$slug" || "$slug" == "None" ]] && continue
    if [[ -e "$DONE_DIR/$slug" ]]; then
        continue                          # already processed
    fi
    # Optional: require manifest.txt to be present before claiming the slug,
    # so we don't race against an in-flight upload from the SPA.
    if ! aws s3api head-object \
            --bucket "$BASIL_INPUT_BUCKET" \
            --key "$slug/manifest.txt" >/dev/null 2>&1; then
        echo "[scraper] $slug — manifest.txt not yet uploaded, skipping"
        continue
    fi

    echo "[scraper] $(date -u +%FT%TZ) — processing $slug"
    workdir="$BASIL_WORK_ROOT/$slug"
    raw_counts="$workdir/raw_counts"
    mkdir -p "$raw_counts"

    # 1. Download everything for this slug into raw_counts/.
    aws s3 sync "s3://$BASIL_INPUT_BUCKET/$slug/" "$raw_counts/" --quiet

    # 2. Convert manifest.txt -> manifest.json for run_pipeline.py.
    python3 "$PIPELINE_DIR/manifest_txt_to_json.py" \
        --in  "$raw_counts/manifest.txt" \
        --out "$workdir/manifest.json"
    # The pipeline expects the raw inputs under raw_counts/ (the manifest.txt
    # is harmless extra there).

    # 3. Publish an immediate "running" status.json so the SPA stops showing
    #    the "waiting for tower" message.
    cat > "$workdir/status.json" <<JSON
{"slug":"$slug","state":"running","current_step":"preprocess",
 "started_at":"$(date -u +%FT%TZ)",
 "steps":{"preprocess":{"state":"running"}}}
JSON
    aws s3 cp "$workdir/status.json" \
        "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" --quiet

    # 4. Run the pipeline (this writes its own status.json updates).
    if python3 "$PIPELINE_DIR/run_pipeline.py" \
            --job-dir "$workdir" \
            --basil-public "$BASIL_PUBLIC_DIR"; then
        echo "[scraper] $slug — pipeline succeeded"
    else
        echo "[scraper] $slug — pipeline FAILED (continuing to upload artifacts anyway)"
    fi

    # 5. Upload everything the SPA needs to render results.
    aws s3 cp "$workdir/status.json" \
        "s3://$BASIL_RESULTS_BUCKET/$slug/status.json" --quiet || true
    if [[ -d "$workdir/basil_plots" ]]; then
        aws s3 sync "$workdir/basil_plots/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/basil_plots/" --quiet
    fi
    if [[ -d "$workdir/logs" ]]; then
        aws s3 sync "$workdir/logs/" \
            "s3://$BASIL_RESULTS_BUCKET/$slug/logs/" --quiet
    fi

    # 6. Mark this slug done so we don't reprocess it.
    touch "$DONE_DIR/$slug"

    # Optional: delete the input prefix once you've confirmed results exist.
    # aws s3 rm "s3://$BASIL_INPUT_BUCKET/$slug/" --recursive
done
