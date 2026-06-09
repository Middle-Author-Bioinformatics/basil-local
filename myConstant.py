# -*- coding: utf-8 -*-
"""
myConstant.py — BASIL web-app compatible config.

This keeps the original BASIL variable names expected by the upstream code,
but replaces hard-coded sample-specific values with environment variables set
by basil_dispatcher.sh / run_pipeline.py.
"""

import os
import sys

def _with_trailing_slash(path: str) -> str:
    """BASIL internally concatenates OutputFileDir + filename, so keep /."""
    return path if path.endswith("/") else path + "/"

def _require(name: str) -> str:
    """Return a required environment variable or exit with a clear error."""
    val = os.environ.get(name)
    if val is None or val == "":
        sys.stderr.write(
            f"[myConstant.py] ERROR: required environment variable {name} is not set.\n"
            "This file is driven by the BASIL web-app dispatcher; do not run "
            "main.py directly unless these variables are exported.\n"
        )
        sys.exit(2)
    return val


# ----- File I/O -------------------------------------------------------------
# Original BASIL variable names. These names are used by BASIL internals.
data = _require("BASIL_DATA")                 # barcode read count data
case_name = _require("BASIL_CASE")            # naming this BASIL run
# OutputFileDir = _require("BASIL_OUT")         # directory of output files
OutputFileDir = _with_trailing_slash(_require("BASIL_OUT"))

# Make sure the per-sample output directory exists before BASIL writes to it.
os.makedirs(OutputFileDir, exist_ok=True)


# ------ EXPERIMENTAL PARAMETERS in Barcode lineage tracking -----------------
# Original BASIL variable names.
D = float(_require("BASIL_D"))                 # dilution factor
N = float(_require("BASIL_N"))                 # carrying capacity / population size


# ------ COMPUTATIONAL PARAMETERS for BASIL performance ----------------------
# Original BASIL variable names.
NUMBER_OF_PROCESSES = int(os.environ.get("BASIL_THREADS", "12"))
NUMBER_LINEAGE_MLE = 3000


# ------ Use only for reading another posterior file as initialization --------
# Original BASIL variable name.
INITIAL_LINEAGES_FROM_FILE = None


# ------ Model Setting in BASIL algorithm (do not change) --------------------
# Original BASIL variable names.
MODEL_NAME = {
    "N": "NModel",
    "SN": "SModel_N",
    "SS": "SModel_S",
}

LINEAGE_TAG = {
    "UNK": "Unknown",
    "NEU": "Neutral",
    "ADP": "Adaptive",
}


# ------ Compatibility aliases for wrappers / easier inspection --------------
# These are extra names only. BASIL itself mainly expects the original names
# above: data, case_name, OutputFileDir, D, N, NUMBER_OF_PROCESSES,
# NUMBER_LINEAGE_MLE, INITIAL_LINEAGES_FROM_FILE, MODEL_NAME, LINEAGE_TAG.
DATA = data
CASE = case_name
OUT = OutputFileDir
DILUTION = D
POPULATION_SIZE = N

input_file = data
output_dir = OutputFileDir
n_processes = NUMBER_OF_PROCESSES
n_lineage_mle = NUMBER_LINEAGE_MLE

