args <- commandArgs(trailingOnly = TRUE)

if (any(args %in% c("-h", "--help"))) {
  cat(
"bar2basil.R

Convert barcode count tables into BASIL input tables, frequency tables, and input.csv.

USAGE:
  Rscript bar2basil.R -i <input_dir> -o <output_dir> -D <dilution_factor> [options]

REQUIRED ARGUMENTS:
  -i, --input_dir
      Directory containing input files.

  -o, --output_dir
      Directory where output files will be written.

  -D, --dilution
      Dilution factor to place into input.csv for BASIL.

OPTIONAL ARGUMENTS:
  -t, --first_timepoint_to_keep
      Integer indicating the first timepoint to retain.
      Default: 1

      Behavior:
      - bartender input: keeps time_point_X columns where X >= first_timepoint_to_keep
      - barcodeCounter input: keeps count columns by position, starting at first_timepoint_to_keep

  -y, --input_type
      Type of input files to process.
      Options:
        bartender
        barcodeCounter
      Default: bartender

  -h, --help
      Print this help page and exit.

INPUT TYPES:
  bartender
      Expects .csv files.
      Expected structure:
        - first columns include barcode/seq/optional metadata
        - count columns named like: time_point_1, time_point_2, ...

      Output BASIL columns are renamed as:
        time_point_1 -> T=0 cycle
        time_point_2 -> T=1 cycle
        etc.

  barcodeCounter
      Expects .tab or .tsv files.
      Expected structure:
        - first column = barcode ID
        - all remaining columns = count columns/timepoints

      Timepoints are assigned strictly by column order:
        first count column  -> T=0 cycle
        second count column -> T=1 cycle
        etc.

OUTPUTS:
  For each input file, the script writes:
    <sample>_basil.txt
        BASIL-ready count table

    <sample>_basil_freq.csv
        Frequency table calculated from the BASIL-ready table

  Also writes:
    input.csv
        BASIL wrapper input sheet with:
          file_name, barcodes, D, carrying_capacity

EXAMPLES:
  bartender input:
    Rscript bar2basil.R -i bartender_dir -o outdir -D 7.5

  bartender input, trimming first 2 timepoints away:
    Rscript bar2basil.R -i bartender_dir -o outdir -D 7.5 -t 3 -y bartender

  barcodeCounter input:
    Rscript bar2basil.R -i barcodecounter_dir -o outdir -D 7.5 -y barcodeCounter

  barcodeCounter input, keeping only from the 4th count column onward:
    Rscript bar2basil.R -i barcodecounter_dir -o outdir -D 7.5 -t 4 -y barcodeCounter

NOTES:
  - Frequencies are calculated from the BASIL-ready tables.
  - The first column in BASIL tables is 'Barcode Index'.
  - Frequency columns begin at column 2.
  - If no valid files are found, the script stops with an error.
  - If no timepoints remain after filtering, that file is skipped.

",
    sep = ""
  )
  quit(save = "no", status = 0)
}

suppressPackageStartupMessages({
  library(reshape2)
  library(ggplot2)
  library(ggrepel)
  library(dplyr)
  library(data.table)
  library(stringi)
  library(ggridges)
  library(tidyr)
  library(viridis)
})

input_dir <- NULL
output_dir <- NULL
D_value <- NULL
first_timepoint_to_keep <- 1
input_type <- "bartender"

i <- 1
while (i <= length(args)) {
  arg <- args[i]

  if (arg %in% c("-i", "--input_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    input_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-o", "--output_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    output_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-D", "--dilution")) {
    if (i == length(args)) stop("Missing value for ", arg)
    D_value <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-t", "--first_timepoint_to_keep")) {
    if (i == length(args)) stop("Missing value for ", arg)
    first_timepoint_to_keep <- as.integer(args[i + 1])
    if (is.na(first_timepoint_to_keep)) {
      stop("first_timepoint_to_keep must be an integer")
    }
    i <- i + 2

  } else if (arg %in% c("-y", "--input_type")) {
    if (i == length(args)) stop("Missing value for ", arg)
    input_type <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-h", "--help")) {
    i <- i + 1

  } else {
    stop("Unknown argument: ", arg, "\nUse -h or --help for usage.")
  }
}

if (is.null(input_dir)) {
  stop("Missing required argument: -i / --input_dir")
}
if (is.null(output_dir)) {
  stop("Missing required argument: -o / --output_dir")
}
if (is.null(D_value)) {
  stop("Missing required argument: -D / --dilution")
}

input_dir <- normalizePath(input_dir, mustWork = TRUE)

if (!input_type %in% c("bartender", "barcodeCounter")) {
  stop("input_type must be either 'bartender' or 'barcodeCounter'")
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)

# folder containing the input files
folder <- input_dir

if (input_type == "bartender") {
  files <- list.files(folder, pattern = "\\.csv$", full.names = TRUE)
} else if (input_type == "barcodeCounter") {
  files <- list.files(folder, pattern = "\\.(tab|tsv)$", full.names = TRUE, ignore.case = TRUE)
}

if (length(files) == 0) {
  stop("No input files found in ", folder, " for input_type = ", input_type)
}

for (f in files) {
  fname <- tools::file_path_sans_ext(basename(f))
  df_name <- fname
  
  if (input_type == "bartender") {
    df <- read.csv(f, check.names = FALSE)
    if (ncol(df) < 2) {
      warning("Skipping ", fname, ": bartender file has fewer than 2 columns.")
      next
    }
    colnames(df)[1:2] <- c("barcode", "seq")

  } else if (input_type == "barcodeCounter") {
    df <- read.delim(f, header = TRUE, sep = "\t", check.names = FALSE)
    if (ncol(df) < 2) {
      warning("Skipping ", fname, ": barcodeCounter file has fewer than 2 columns.")
      next
    }
    colnames(df)[1] <- "barcode"
  }
  
  assign(df_name, df, envir = .GlobalEnv)
  rm(df)
}

##############################################################
# Get files ready for BASIL
# Optionally remove early timepoints, but always write one BASIL file
##############################################################

# reconstruct the list of imported base names from the file list
imported_names <- unique(tools::file_path_sans_ext(basename(files)))

for (nm in imported_names) {
  if (!exists(nm, envir = .GlobalEnv)) {
    warning("Imported object ", nm, " not found; skipping.")
    next
  }
  
  df <- get(nm, envir = .GlobalEnv)
  
  if (input_type == "bartender") {
    # first column for BASIL
    colnames(df)[1] <- "Barcode Index"

    # identify timepoint columns before removing metadata columns
    tp_cols <- grep("^time_point_[0-9]+$", colnames(df), value = TRUE)

    if (length(tp_cols) == 0) {
      warning("No time_point_X columns found in ", nm, "; skipping.")
      next
    }

    nums <- as.integer(sub("^time_point_", "", tp_cols))
    keep_cols <- tp_cols[nums >= first_timepoint_to_keep]

    if (length(keep_cols) == 0) {
      warning("No timepoints retained in ", nm,
              " after first_timepoint_to_keep=", first_timepoint_to_keep, "; skipping.")
      next
    }

    # keep barcode + retained timepoints only
    df <- df[, c("Barcode Index", keep_cols), drop = FALSE]

    # rename retained timepoint columns to BASIL format
    nums_keep <- as.integer(sub("^time_point_", "", keep_cols))
    colnames(df)[-1] <- paste0("T=", nums_keep - 1, " cycle")

  } else if (input_type == "barcodeCounter") {
    # first column for BASIL
    colnames(df)[1] <- "Barcode Index"

    if (ncol(df) < 2) {
      warning("No count columns found in ", nm, "; skipping.")
      next
    }

    # all columns after the first are timepoints, in order
    count_cols <- colnames(df)[-1]
    count_idx <- seq_along(count_cols)
    keep_idx <- count_idx[count_idx >= first_timepoint_to_keep]

    if (length(keep_idx) == 0) {
      warning("No timepoints retained in ", nm, " after first_timepoint_to_keep=", first_timepoint_to_keep, "; skipping.")
      next
    }

    keep_cols <- count_cols[keep_idx]

    # keep barcode + retained count columns only
    df <- df[, c("Barcode Index", keep_cols), drop = FALSE]

    # rename retained columns by order: first retained column becomes T=(original index-1)
    colnames(df)[-1] <- paste0("T=", keep_idx - 1, " cycle")
  }
  
  new_name <- paste0(nm, "_basil")
  assign(new_name, df, envir = .GlobalEnv)
  
  out_file <- file.path(output_dir, paste0(new_name, ".txt"))
  write.table(df, file = out_file, sep = "\t", row.names = FALSE, quote = FALSE)
}

##############################################################
# Calculate frequencies
##############################################################
# ---- Parameters ----
First_Data_Column <- 2
# ---- Find candidate data.frames in global env ----

df_names <- paste0(imported_names, "_basil")

# ---- Loop over data.frames ----
for (nm in df_names) {
  
  message("Processing: ", nm)
  
  df <- get(nm, envir = .GlobalEnv)
  
  # Skip if dataframe does not have expected columns
  if (First_Data_Column > ncol(df)) {
    message("Skipping ", nm, " (not enough columns)")
    next
  }
  
  data_cols <- First_Data_Column:ncol(df)
  
  # Convert to numeric safely
  df[, data_cols] <- lapply(df[, data_cols, drop = FALSE], function(x) {
    suppressWarnings(as.numeric(as.character(x)))
  })
  
  # Column sums
  col_sums <- colSums(df[, data_cols, drop = FALSE], na.rm = TRUE)
  
  # Avoid divide-by-zero
  col_sums[col_sums == 0] <- NA
  
  # Calculate frequencies
  df[, data_cols] <- sweep(
    df[, data_cols, drop = FALSE],
    2,
    col_sums,
    FUN = "/"
  )
  
  assign(paste0(nm, "_freq"), df, envir = .GlobalEnv)
  
  print(head(df[, seq_len(min(ncol(df), First_Data_Column + 3))]))
}
message("Done. Created ", length(df_names), " BASIL frequency data.frame(s).")

# export freq tables to CSV file
freq_tables <- paste0(imported_names, "_basil_freq")

for (nm in freq_tables) {
  write.csv(
    get(nm, envir = .GlobalEnv),
    file = file.path(output_dir, paste0(nm, ".csv")),
    row.names = FALSE
  )
}

##############################################################
# Create input.csv for BASIL sbatch wrapper
##############################################################
input_csv <- data.frame(
  file_name = character(0),
  barcodes = integer(0),
  D = character(0),
  carrying_capacity = character(0),
  stringsAsFactors = FALSE
)

for (nm in imported_names) {
  basil_name <- paste0(nm, "_basil")
  
  if (!exists(basil_name, envir = .GlobalEnv)) {
    warning("Object ", basil_name, " not found; skipping.")
    next
  }
  
  df <- get(basil_name, envir = .GlobalEnv)
  
  input_csv <- rbind(
    input_csv,
    data.frame(
      file_name = paste0(basil_name, ".txt"),
      barcodes = nrow(df),
      D = D_value,
      carrying_capacity = "",
      stringsAsFactors = FALSE
    )
  )
}

write.csv(
  input_csv,
  file = file.path(output_dir, "input.csv"),
  row.names = FALSE,
  quote = FALSE
)


