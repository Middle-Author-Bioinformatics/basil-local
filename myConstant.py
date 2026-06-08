# myConstant.py — pipeline-compatible config for BASIL
#
# Reads all per-sample parameters from environment variables set by the
# orchestrator (run_pipeline.py / basil_dispatcher.sh), instead of hard-coding
# them. This is the same contract used by the original SLURM dispatcher, so
# BASIL's main_scripts/main.py picks up DATA / CASE / OUT / D / N / THREADS
# transparently.
#
# Required environment variables (set per-sample by the dispatcher):
#   BASIL_DATA     Full path to the *_basil.txt input file
#   BASIL_CASE     Sample case name (used for output naming)
#   BASIL_OUT      Per-sample output directory
#   BASIL_D        Dilution factor (float)
#   BASIL_N        Carrying capacity / effective population size (float)
#
# Optional:
#   BASIL_THREADS  Number of parallel processes (default: 12)

import os
import sys


def _require(name: str) -> str:
    val = os.environ.get(name)
    if val is None or val == "":
        sys.stderr.write(
            f"[myConstant.py] ERROR: required environment variable {name} "
            "is not set. This file is driven by the BASIL web-app dispatcher; "
            "do not run main.py directly.\n"
        )
        sys.exit(2)
    return val


# --- per-sample inputs (env-driven) -----------------------------------------
DATA = _require("BASIL_DATA")
CASE = _require("BASIL_CASE")
OUT = _require("BASIL_OUT")
DILUTION = float(_require("BASIL_D"))
POPULATION_SIZE = float(_require("BASIL_N"))

# Ensure output directory exists
os.makedirs(OUT, exist_ok=True)

# --- fixed computational parameters -----------------------------------------
# Multiprocessing workers. Suggested 12–40. Override with BASIL_THREADS.
NUMBER_OF_PROCESSES = int(os.environ.get("BASIL_THREADS", "12"))

# Number of randomly selected reference lineages used to infer mean fitness.
NUMBER_LINEAGE_MLE = 3000

# --- back-compat aliases ----------------------------------------------------
# Some BASIL versions reference different attribute names. Keep these in sync
# with whatever upstream main.py imports.
input_file = DATA
case_name = CASE
output_dir = OUT
D = DILUTION
N = POPULATION_SIZE
n_processes = NUMBER_OF_PROCESSES
n_lineage_mle = NUMBER_LINEAGE_MLE
