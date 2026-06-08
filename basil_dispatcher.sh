#!/usr/bin/env bash
# basil_dispatcher.sh — non-SLURM dispatcher for BASIL on a single tower server.
#
# Drop-in replacement for the original SLURM-based dispatcher. Same CLI:
#
#   ./basil_dispatcher.sh <input_dir> <csv_file> <basil_public_dir>
#
# Iterates over input.csv, exports the same env vars BASIL's myConstant.py
# expects, and runs `python main_scripts/main.py` directly (no sbatch).
# Samples are processed sequentially by default; set BASIL_PARALLEL_SAMPLES
# to run several samples concurrently (each sample itself uses BASIL_THREADS
# internal workers, so size accordingly).
#
# Env knobs:
#   BASIL_THREADS           # internal workers per sample        (default 12)
#   BASIL_PARALLEL_SAMPLES  # samples run concurrently           (default 1)
#   BASIL_PYTHON            # python interpreter                 (default: python)
#   BASIL_LOG_DIR           # where to write per-sample logs     (default: <input_dir>/logs)
#
# Exit codes:
#   0  every queued sample finished successfully
#   1  one or more samples failed (see logs)
#   2  bad usage / missing files

set -u
set -o pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <input_dir> <csv_file> <basil_public_dir>

  input_dir         Directory containing the *_basil.txt files (output of bar2basil.R)
  csv_file          Path to the completed input.csv manifest
                    (columns: file_name,barcodes,D,carrying_capacity)
  basil_public_dir  Path to the cloned BASIL-public directory

Environment:
  BASIL_THREADS=12             internal multiprocessing workers per sample
  BASIL_PARALLEL_SAMPLES=1     how many samples to run at the same time
  BASIL_PYTHON=python          python interpreter
  BASIL_LOG_DIR=<input>/logs   per-sample log directory
EOF
}

if [[ $# -ne 3 ]]; then
    usage >&2
    exit 2
fi

INPUT_DIR="$1"
CSV_FILE="$2"
BASDIR="$3"

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "[dispatcher] input_dir does not exist: $INPUT_DIR" >&2; exit 2
fi
if [[ ! -f "$CSV_FILE" ]]; then
    echo "[dispatcher] csv_file does not exist: $CSV_FILE" >&2; exit 2
fi
if [[ ! -d "$BASDIR" ]]; then
    echo "[dispatcher] basil_public_dir does not exist: $BASDIR" >&2; exit 2
fi
if [[ ! -f "$BASDIR/main_scripts/main.py" ]]; then
    echo "[dispatcher] $BASDIR/main_scripts/main.py not found — is this BASIL-public?" >&2
    exit 2
fi

BASIL_PYTHON="${BASIL_PYTHON:-python}"
BASIL_THREADS="${BASIL_THREADS:-12}"
BASIL_PARALLEL_SAMPLES="${BASIL_PARALLEL_SAMPLES:-1}"
LOG_DIR="${BASIL_LOG_DIR:-${INPUT_DIR%/}/logs}"
mkdir -p "$LOG_DIR"

# Resolve to absolute so the `cd $BASDIR` step inside the loop works.
INPUT_DIR_ABS="$(cd "$INPUT_DIR" && pwd)"
BASDIR_ABS="$(cd "$BASDIR" && pwd)"
LOG_DIR_ABS="$(cd "$LOG_DIR" && pwd)"

echo "[dispatcher] input_dir          = $INPUT_DIR_ABS"
echo "[dispatcher] csv_file           = $CSV_FILE"
echo "[dispatcher] basil_public_dir   = $BASDIR_ABS"
echo "[dispatcher] log_dir            = $LOG_DIR_ABS"
echo "[dispatcher] threads/sample     = $BASIL_THREADS"
echo "[dispatcher] parallel samples   = $BASIL_PARALLEL_SAMPLES"
echo

# ---------------------------------------------------------------------------
# run_one_sample <basil_file> <D> <N>
# Runs BASIL for a single sample. Designed to be safe to invoke under xargs -P.
# ---------------------------------------------------------------------------
run_one_sample() {
    local fname="$1"
    local D="$2"
    local N="$3"

    local data_path="$INPUT_DIR_ABS/$fname"
    local case_name="${fname%.*}"           # strip extension
    local out_dir="$INPUT_DIR_ABS/output/$case_name"
    local log_file="$LOG_DIR_ABS/${case_name}.log"

    mkdir -p "$out_dir"

    if [[ ! -f "$data_path" ]]; then
        echo "[dispatcher][$case_name] SKIP — missing input file $data_path" \
            | tee -a "$log_file" >&2
        return 1
    fi

    {
        echo "=== BASIL run: $case_name ==="
        echo "host        : $(hostname)"
        echo "started     : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "BASIL_DATA  : $data_path"
        echo "BASIL_CASE  : $case_name"
        echo "BASIL_OUT   : $out_dir"
        echo "BASIL_D     : $D"
        echo "BASIL_N     : $N"
        echo "BASIL_THREADS: $BASIL_THREADS"
        echo "BASDIR      : $BASDIR_ABS"
        echo "----------------------------------------"
    } >> "$log_file"

    # Export per-sample vars and run BASIL from inside BASIL-public.
    (
        cd "$BASDIR_ABS" || exit 11
        BASIL_DATA="$data_path" \
        BASIL_CASE="$case_name" \
        BASIL_OUT="$out_dir" \
        BASIL_D="$D" \
        BASIL_N="$N" \
        BASIL_THREADS="$BASIL_THREADS" \
        BASDIR="$BASDIR_ABS" \
        "$BASIL_PYTHON" main_scripts/main.py
    ) >> "$log_file" 2>&1
    local rc=$?

    {
        echo "----------------------------------------"
        echo "finished    : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "exit_code   : $rc"
    } >> "$log_file"

    if [[ $rc -ne 0 ]]; then
        echo "[dispatcher][$case_name] FAILED (exit=$rc) — see $log_file" >&2
        return $rc
    fi
    echo "[dispatcher][$case_name] OK"
    return 0
}

export INPUT_DIR_ABS BASDIR_ABS LOG_DIR_ABS BASIL_THREADS BASIL_PYTHON
export -f run_one_sample

# ---------------------------------------------------------------------------
# Build the task list from input.csv. Skips rows with empty carrying_capacity.
# ---------------------------------------------------------------------------
task_file="$(mktemp)"
trap 'rm -f "$task_file"' EXIT

awk -F',' '
    NR == 1 { next }                          # skip header
    NF < 4 { next }
    $1 == "" { next }
    $4 == "" || $4 == " " {
        printf("[dispatcher] SKIP %s — empty carrying_capacity\n", $1) > "/dev/stderr"
        next
    }
    { printf("%s\t%s\t%s\n", $1, $3, $4) }
' "$CSV_FILE" > "$task_file"

n_tasks=$(wc -l < "$task_file" | tr -d ' ')
echo "[dispatcher] queued $n_tasks sample(s)"
if [[ "$n_tasks" -eq 0 ]]; then
    echo "[dispatcher] nothing to do." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Run sequentially or in parallel via xargs -P.
# ---------------------------------------------------------------------------
fail=0
if [[ "$BASIL_PARALLEL_SAMPLES" -le 1 ]]; then
    while IFS=$'\t' read -r fname D N; do
        run_one_sample "$fname" "$D" "$N" || fail=$((fail+1))
    done < "$task_file"
else
    # xargs -P; -I keeps the 3 fields together. Use -n1 with bash -c trickery
    # to pass 3 args cleanly.
    xargs -a "$task_file" -P "$BASIL_PARALLEL_SAMPLES" -L 1 \
        bash -c 'run_one_sample "$1" "$2" "$3"' _ \
        || fail=$?
fi

if [[ $fail -ne 0 ]]; then
    echo "[dispatcher] completed with $fail failure(s)" >&2
    exit 1
fi
echo "[dispatcher] all samples completed successfully."
exit 0
