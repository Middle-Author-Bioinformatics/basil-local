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
      - bartender time_point_X input: keeps columns where X >= first_timepoint_to_keep
      - BASIL-style CSV input: keeps columns by position after numeric cycle sorting
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
        - also accepts BASIL-style CSV: Barcode Index,T=1 cycle,T=2 cycle,...

      Output BASIL columns are renamed as:
        time_point_1 -> T=0 cycle
        time_point_2 -> T=1 cycle
        etc.

      Existing T=N cycle headers retain their cycle numbers. Both header
      formats are sorted numerically before output. They cannot be mixed
      in the same file. For BASIL-style CSV, -t 1 keeps all cycles, including
      T=0 if present; -t 3 drops the first two chronologically sorted columns.

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

# Preprocessing uses base R only; plotting dependencies belong to basilHelper.v2.R.

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
    if (is.na(first_timepoint_to_keep) || first_timepoint_to_keep < 1 ||
        as.numeric(args[i + 1]) != first_timepoint_to_keep) {
      stop("first_timepoint_to_keep must be a positive integer")
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

imported_names <- character(0)
conversion_names <- character(0)
skipped_details <- character(0)

for (f in files) {
  fname <- tools::file_path_sans_ext(basename(f))
  df_name <- fname
  
  if (input_type == "bartender") {
    df <- read.csv(f, check.names = FALSE, colClasses = "character")
    if (ncol(df) < 2) {
      warning("Skipping ", fname, ": bartender file has fewer than 2 columns.")
      next
    }
    # Only the ID column is positional. A count column may be column 2.
    colnames(df)[1] <- "barcode"

  } else if (input_type == "barcodeCounter") {
    df <- read.delim(f, header = TRUE, sep = "\t", check.names = FALSE,
                     colClasses = "character")
    if (ncol(df) < 2) {
      warning("Skipping ", fname, ": barcodeCounter file has fewer than 2 columns.")
      next
    }
    colnames(df)[1] <- "barcode"
  }
  
  imported_names <- c(imported_names, df_name)
  assign(df_name, df, envir = .GlobalEnv)
  rm(df)
}

##############################################################
# Get files ready for BASIL
# Optionally remove early timepoints, but always write one BASIL file
##############################################################

# Track only tables that were actually imported.
imported_names <- unique(imported_names)

for (nm in imported_names) {
  if (!exists(nm, envir = .GlobalEnv)) {
    warning("Imported object ", nm, " not found; skipping.")
    next
  }
  
  df <- get(nm, envir = .GlobalEnv)
  
  if (input_type == "bartender") {
    # first column for BASIL
    colnames(df)[1] <- "Barcode Index"

    # Detect explicit time labels; never infer cycles from arbitrary headers.
    legacy_cols <- grep("^time_point_[0-9]+$", colnames(df), value = TRUE)
    basil_cols <- grep("^T=[0-9]+ cycle$", colnames(df), value = TRUE)
    if (length(legacy_cols) > 0 && length(basil_cols) > 0) {
      stop("Mixed time_point_X and T=N cycle headers in ", nm,
           "; use one format per file.", call. = FALSE)
    }
    native_basil <- length(basil_cols) > 0
    tp_cols <- if (native_basil) basil_cols else legacy_cols

    if (length(tp_cols) == 0) {
      detail <- paste0(
        nm, ": no recognized timepoint columns found. Expected names such as ",
        "time_point_1, time_point_2 or T=1 cycle, T=2 cycle. Actual headers: ",
        paste(colnames(df), collapse = " | "),
        ". Input: ", files[match(nm, tools::file_path_sans_ext(basename(files)))],
        ". Check the delimiter and input_type; timepoint order will not be guessed."
      )
      skipped_details <- c(skipped_details, detail)
      warning(detail, "; skipping.", call. = FALSE)
      next
    }

    nums <- if (native_basil) {
      as.integer(sub("^T=([0-9]+) cycle$", "\\1", tp_cols))
    } else {
      as.integer(sub("^time_point_", "", tp_cols))
    }
    minimum <- if (native_basil) 0 else 1
    if (anyNA(nums) || anyDuplicated(nums) || any(nums < minimum)) {
      stop("Invalid or duplicate timepoint numbers in ", nm, call. = FALSE)
    }
    tp_cols <- tp_cols[order(nums)]
    nums <- sort(nums)
    # Native labels are actual cycle values, including a possible T=0.
    # -t selects the first measurement to retain after numeric sorting.
    keep <- if (native_basil) {
      seq_along(nums) >= first_timepoint_to_keep
    } else {
      nums >= first_timepoint_to_keep
    }
    keep_cols <- tp_cols[keep]

    if (length(keep_cols) == 0) {
      warning("No timepoints retained in ", nm,
              " after first_timepoint_to_keep=", first_timepoint_to_keep, "; skipping.")
      next
    }

    df <- df[, c("Barcode Index", keep_cols), drop = FALSE]
    cycles <- if (native_basil) nums[keep] else nums[keep] - 1
    colnames(df)[-1] <- paste0("T=", cycles, " cycle")

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
  
  # Reject invalid counts instead of silently turning them into missing values.
  df[-1] <- lapply(df[-1], function(x) {
    counts <- suppressWarnings(as.numeric(x))
    if (any(!is.finite(counts) | counts < 0 | counts != floor(counts))) {
      stop("Invalid counts in ", nm,
           ": retained count columns must contain nonnegative whole numbers.",
           call. = FALSE)
    }
    counts
  })
  if (nrow(df) == 0) stop("No barcode rows found in ", nm, call. = FALSE)

  new_name <- paste0(nm, "_basil")
  assign(new_name, df, envir = .GlobalEnv)
  
  out_file <- file.path(output_dir, paste0(new_name, ".txt"))
  write.table(df, file = out_file, sep = "\t", row.names = FALSE, quote = FALSE)
  conversion_names <- c(conversion_names, nm)
}

if (length(conversion_names) == 0) {
  stop("No BASIL tables were created from ", input_dir, ". ",
       paste(skipped_details, collapse = "\n"),
       " Check the input headers, input_type, and first_timepoint_to_keep.",
       call. = FALSE)
}

##############################################################
# Calculate frequencies
##############################################################
# ---- Parameters ----
First_Data_Column <- 2
# ---- Find candidate data.frames in global env ----

df_names <- paste0(conversion_names, "_basil")

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
freq_tables <- paste0(conversion_names, "_basil_freq")

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

for (nm in conversion_names) {
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


