#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

print_help <- function() {
  cat(
"basil_ingest_from_dirs.R

Ingest BASIL output files and merge them onto the frequency/count tables
produced by bar2basil.R.

USAGE:
  Rscript basil_ingest_from_dirs.R \\
    -f <freq_dir> \\
    -c <count_dir> \\
    -b <basil_dir> \\
    -o <output_dir> [options]

REQUIRED ARGUMENTS:
  -f, --freq_dir
      Directory containing *_basil_freq.csv files from bar2basil.R

  -c, --count_dir
      Directory containing *_basil.txt files from bar2basil.R

  -b, --basil_dir
      Directory containing BASIL adapted-lineage output files
      (can be nested in sample subdirectories)

  -o, --output_dir
      Directory where outputs will be written

OPTIONAL ARGUMENTS:
  -p, --prefix
      Prefix for combined output files
      Default: basil_merge

  -h, --help
      Print this help message and exit

INPUT FILE EXPECTATIONS:
  bar2basil.R outputs:
    <sample>_basil.txt
    <sample>_basil_freq.csv

  BASIL outputs:
    BASIL_Selection_Coefficient_for_called_Adapted_<SAMPLE>_ConfidenceFactorBeta=<BETA>.txt

OUTPUTS:
  Per-sample:
    <sample>.merged.csv
    <sample>_long.csv

  Combined:
    <prefix>.all_merged.csv
    <prefix>.all_long.csv
    <prefix>.basil_file_index.csv
", sep = "")
}

if (length(args) == 0 || any(args %in% c("-h", "--help"))) {
  print_help()
  quit(save = "no", status = 0)
}

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(tidyr)
})

freq_dir <- NULL
count_dir <- NULL
basil_dir <- NULL
output_dir <- NULL
prefix <- "basil_merge"

i <- 1
while (i <= length(args)) {
  arg <- args[i]

  if (arg %in% c("-f", "--freq_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    freq_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-c", "--count_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    count_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-b", "--basil_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    basil_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-o", "--output_dir")) {
    if (i == length(args)) stop("Missing value for ", arg)
    output_dir <- args[i + 1]
    i <- i + 2

  } else if (arg %in% c("-p", "--prefix")) {
    if (i == length(args)) stop("Missing value for ", arg)
    prefix <- args[i + 1]
    i <- i + 2

  } else {
    stop("Unknown argument: ", arg, "\nUse -h or --help for usage.")
  }
}

if (is.null(freq_dir)) stop("Missing required argument: -f / --freq_dir")
if (is.null(count_dir)) stop("Missing required argument: -c / --count_dir")
if (is.null(basil_dir)) stop("Missing required argument: -b / --basil_dir")
if (is.null(output_dir)) stop("Missing required argument: -o / --output_dir")

freq_dir <- normalizePath(freq_dir, mustWork = TRUE)
count_dir <- normalizePath(count_dir, mustWork = TRUE)
basil_dir <- normalizePath(basil_dir, mustWork = TRUE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)

tealeaves_out_dir <- file.path(output_dir, "tealeaves")
dir.create(tealeaves_out_dir, recursive = TRUE, showWarnings = FALSE)

# --------------------------------------------------
# Discover input files
# --------------------------------------------------
freq_files <- list.files(freq_dir, pattern = "_basil_freq\\.csv$", full.names = TRUE)
count_files <- list.files(count_dir, pattern = "_basil\\.txt$", full.names = TRUE)

if (length(freq_files) == 0) stop("No *_basil_freq.csv files found in ", freq_dir)
if (length(count_files) == 0) stop("No *_basil.txt files found in ", count_dir)

sample_from_freq <- function(x) sub("_basil_freq\\.csv$", "", basename(x))
sample_from_count <- function(x) sub("_basil\\.txt$", "", basename(x))

freq_map <- setNames(freq_files, sample_from_freq(freq_files))
count_map <- setNames(count_files, sample_from_count(count_files))

samples <- intersect(names(freq_map), names(count_map))
if (length(samples) == 0) {
  stop("No matching sample names found between freq_dir and count_dir")
}

message("Found ", length(samples), " matched sample(s): ", paste(samples, collapse = ", "))

# --------------------------------------------------
# Read BASIL files
# --------------------------------------------------
basil_files <- list.files(
  basil_dir,
  pattern = "^BASIL_Selection_Coefficient_for_called_Adapted_.*_ConfidenceFactorBeta=[0-9]+(\\.[0-9]+)?\\.txt$",
  recursive = TRUE,
  full.names = TRUE
)

if (length(basil_files) == 0) {
  stop("No BASIL files found under: ", basil_dir)
}

parse_basil_filename <- function(path) {
  bn <- basename(path)

  m <- regexec(
    "^BASIL_Selection_Coefficient_for_called_Adapted_(.+)_ConfidenceFactorBeta=([0-9]+(?:\\.[0-9]+)?)\\.txt$",
    bn
  )
  mm <- regmatches(bn, m)[[1]]

  if (length(mm) != 3) {
    stop("Filename does not match expected BASIL pattern: ", bn)
  }

  sample_raw <- mm[2]
  sample <- sub("_basil$", "", sample_raw)
  beta <- mm[3]

  data.frame(
    file = path,
    file_name = bn,
    Sample = sample,
    BasilSample = sample_raw,
    CF = as.numeric(beta),
    stringsAsFactors = FALSE
  )
}

basil_index <- bind_rows(lapply(basil_files, parse_basil_filename))

read_one_basil <- function(file, sample_name, cf_value) {
  df <- fread(file)

  if (ncol(df) < 4) {
    stop("BASIL file has fewer than 4 columns: ", file)
  }

  data.frame(
    basil_barcode_id = df[[1]],
    s_mean = suppressWarnings(as.numeric(df[[2]])),
    s_std = suppressWarnings(as.numeric(df[[3]])),
    called_time = suppressWarnings(as.numeric(df[[4]])),
    Sample = sample_name,
    CF = cf_value,
    stringsAsFactors = FALSE
  )
}

basil_tables <- lapply(seq_len(nrow(basil_index)), function(i) {
  read_one_basil(
    file = basil_index$file[i],
    sample_name = basil_index$Sample[i],
    cf_value = basil_index$CF[i]
  )
})

names(basil_tables) <- paste0(
  basil_index$Sample,
  "_CF_",
  gsub("\\.", "_", sprintf("%.2f", basil_index$CF))
)

# --------------------------------------------------
# Build sample table from *_basil_freq.csv + *_basil.txt
# Mirrors the upstream structure used by your first script:
# one row per barcode per timepoint with Frequency + Reads
# --------------------------------------------------
build_sample_long <- function(sample_name, freq_file, count_file) {
  freq_df <- fread(freq_file)
  count_df <- fread(count_file)

  # ----------------------------
  # Standardize frequency table
  # Accept either:
  #   1) BASIL-style freq table:
  #      Barcode Index, T=3 cycle, T=4 cycle, ...
  #   2) Original-style freq table:
  #      barcode, seq, Cluster.Score, time_point_1, ...
  # ----------------------------
  if ("Barcode Index" %in% names(freq_df)) {
    freq_id_col <- "Barcode Index"
    freq_time_cols <- grep("^T=[0-9]+ cycle$", names(freq_df), value = TRUE)

    if (length(freq_time_cols) == 0) {
      stop("No BASIL-style time columns found in ", freq_file)
    }

    freq_long <- melt(
      freq_df,
      id.vars = freq_id_col,
      measure.vars = freq_time_cols,
      variable.name = "TimeLabel",
      value.name = "Frequency"
    )

    freq_long$barcode <- as.character(freq_long[["Barcode Index"]])
    freq_long$Time <- as.numeric(sub("^T=([0-9]+) cycle$", "\\1", freq_long$TimeLabel))

  } else if ("barcode" %in% names(freq_df)) {
    freq_id_col <- "barcode"
    freq_time_cols <- grep("^time_point_[0-9]+$", names(freq_df), value = TRUE)

    if (length(freq_time_cols) == 0) {
      stop("No time_point_X columns found in ", freq_file)
    }

    freq_long <- melt(
      freq_df,
      id.vars = freq_id_col,
      measure.vars = freq_time_cols,
      variable.name = "TimeLabel",
      value.name = "Frequency"
    )

    freq_long$barcode <- as.character(freq_long[["barcode"]])

    # Match original script behavior:
    # time_point_1 -> Time 1, time_point_2 -> Time 2, ...
    freq_long$Time <- as.numeric(sub("^time_point_([0-9]+)$", "\\1", freq_long$TimeLabel))
  } else {
    stop("Could not find barcode column in frequency file: ", freq_file)
  }

  # ----------------------------
  # Standardize count table
  # Expect BASIL-style:
  #   Barcode Index, T=3 cycle, T=4 cycle, ...
  # ----------------------------
  if (!"Barcode Index" %in% names(count_df)) {
    stop("Missing 'Barcode Index' in ", count_file)
  }

  count_time_cols <- grep("^T=[0-9]+ cycle$", names(count_df), value = TRUE)
  if (length(count_time_cols) == 0) {
    stop("No BASIL-style time columns found in ", count_file)
  }

  count_long <- melt(
    count_df,
    id.vars = "Barcode Index",
    measure.vars = count_time_cols,
    variable.name = "TimeLabel",
    value.name = "Reads"
  )

  count_long$barcode <- as.character(count_long[["Barcode Index"]])
  count_long$Time <- as.numeric(sub("^T=([0-9]+) cycle$", "\\1", count_long$TimeLabel))

  # ----------------------------
  # Merge frequency + counts by barcode and Time
  # ----------------------------
  merged <- merge(
    freq_long[, c("barcode", "Time", "Frequency")],
    count_long[, c("barcode", "Time", "Reads")],
    by = c("barcode", "Time"),
    all = TRUE
  )

  merged$Sample <- sample_name
  merged <- merged[, c("barcode", "Sample", "Time", "Frequency", "Reads")]
  merged <- merged[order(suppressWarnings(as.numeric(merged$barcode)), merged$Time), ]

  merged
}

# --------------------------------------------------
# Merge BASIL calls onto one sample
# Preserves the same logic from your original script:
# direct barcode match first, otherwise positional mapping
# --------------------------------------------------
merge_sample_with_basil <- function(sample_df, basil_list_for_sample) {
  sample_df <- as.data.frame(sample_df)
  sample_df$barcode <- as.character(sample_df$barcode)

  uniq_bcs <- unique(sample_df$barcode)

  for (nm in names(basil_list_for_sample)) {
    post <- basil_list_for_sample[[nm]]
    cf_value <- unique(post$CF)

    bc_col <- post$basil_barcode_id
    idx <- match(sample_df$barcode, bc_col)
    n_direct <- sum(!is.na(idx))

    if (n_direct == 0) {
      pos <- match(sample_df$barcode, uniq_bcs)
      idx <- match(pos, bc_col)
      message("  ", nm, ": direct=0 -> used positional mapping, matched ",
              sum(!is.na(idx)), " rows")
    } else {
      message("  ", nm, ": direct matched ", n_direct, " rows")
    }

    cf_label <- gsub("\\.", "_", sprintf("%.2f", cf_value))
    col_mean <- paste0("s_mean_CF_", cf_label)
    col_std  <- paste0("s_std_CF_", cf_label)
    col_time <- paste0("called_time_CF_", cf_label)

    if (!col_mean %in% names(sample_df)) sample_df[[col_mean]] <- NA_real_
    if (!col_std  %in% names(sample_df)) sample_df[[col_std ]] <- NA_real_
    if (!col_time %in% names(sample_df)) sample_df[[col_time]] <- NA_real_

    non_na <- which(!is.na(idx))
    if (length(non_na) > 0) {
      sample_df[[col_mean]][non_na] <- post$s_mean[idx[non_na]]
      sample_df[[col_std ]][non_na] <- post$s_std[idx[non_na]]
      sample_df[[col_time]][non_na] <- post$called_time[idx[non_na]]
    }
  }

  sample_df
}

all_merged <- list()
all_long <- list()

for (s in samples) {
  message("Processing sample: ", s)

  sample_df <- build_sample_long(
    sample_name = s,
    freq_file = freq_map[[s]],
    count_file = count_map[[s]]
  )

  idx <- which(basil_index$Sample == s)

  if (length(idx) == 0) {
    message("  No BASIL files found for sample ", s)
    merged_df <- sample_df
  } else {
    basil_list_for_sample <- basil_tables[idx]
    names(basil_list_for_sample) <- names(basil_tables)[idx]
    merged_df <- merge_sample_with_basil(sample_df, basil_list_for_sample)
  }

  cf_cols_present <- grep("^(s_mean|s_std|called_time)_CF_", names(merged_df), value = TRUE)

  if (length(cf_cols_present) > 0) {
    long_df <- merged_df %>%
      pivot_longer(
        cols = all_of(cf_cols_present),
        names_to = c(".value", "CF"),
        names_pattern = "^(s_mean|s_std|called_time)_CF_(.*)$"
      ) %>%
      mutate(CF = as.numeric(gsub("_", ".", CF))) %>%
      filter(!(is.na(s_mean) & is.na(s_std) & is.na(called_time))) %>%
      arrange(barcode, CF, Time)
  } else {
    long_df <- data.frame()
  }

  fwrite(as.data.table(long_df),
       file.path(tealeaves_out_dir, paste0(s, "_long.csv")))

  all_merged[[s]] <- merged_df
  all_long[[s]] <- long_df
}

all_merged_df <- bind_rows(all_merged)
all_long_df <- bind_rows(all_long)

fwrite(as.data.table(all_merged_df),
       file.path(output_dir, paste0(prefix, ".all_merged.csv")))

fwrite(as.data.table(all_long_df),
       file.path(output_dir, paste0(prefix, ".all_long.csv")))

fwrite(as.data.table(basil_index),
       file.path(output_dir, paste0(prefix, ".basil_file_index.csv")))


message("Done.")
message("Output directory: ", output_dir)


##############################################################
# Plotting downstream of BASIL merge
# Adapted from Levin_lab_bartender_freq_BASIL_inputs_graphs.R
##############################################################

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(RColorBrewer)
  library(ggridges)
  library(viridis)
})

# ----------------------------
# Rebuild named sample objects in the global env so the plotting
# code behaves more like the original script
# ----------------------------
for (s in names(all_merged)) {
  assign(s, all_merged[[s]], envir = .GlobalEnv)
}
for (s in names(all_long)) {
  assign(paste0(s, "_long"), all_long[[s]], envir = .GlobalEnv)
}

imported_names <- names(all_merged)

# ----------------------------
# Global min/max for CF=6.00 selection coefficients
# ----------------------------
s_vals <- unlist(lapply(imported_names, function(nm) {
  df <- get(nm, envir = .GlobalEnv)
  if (!is.data.frame(df) || !"s_mean_CF_6_00" %in% names(df)) return(NULL)
  as.numeric(df$s_mean_CF_6_00)
}), use.names = FALSE)

s_vals <- s_vals[is.finite(s_vals)]

if (length(s_vals) == 0) {
  warning("No finite s_mean_CF_6_00 values found; skipping plot generation that depends on CF 6.00.")
} else {

  s_min <- min(s_vals, na.rm = TRUE)
  s_max <- max(s_vals, na.rm = TRUE)

  cat("Global s_mean_CF_6_00 range:", s_min, "to", s_max, "\n")

  # ----------------------------
  # Interval labels
  # ----------------------------
  interval_levels <- paste(1:9, 2:10, sep = "-")

  # ----------------------------
  # Helper: compute biggest increase interval
  # ----------------------------
  add_max_increase_interval <- function(df) {
    req <- c("barcode", "Time", "Frequency", "s_mean_CF_6_00")
    if (!all(req %in% names(df))) return(df)

    df <- df %>%
      mutate(
        Time = as.integer(as.character(Time)),
        Frequency = as.numeric(Frequency)
      ) %>%
      group_by(barcode) %>%
      arrange(Time, .by_group = TRUE) %>%
      mutate(
        dFreq = if_else(Time - lag(Time) == 1, Frequency - lag(Frequency), NA_real_),
        interval_2tp = if_else(
          Time - lag(Time) == 1,
          paste(lag(Time), Time, sep = "-"),
          NA_character_
        ),
        max_increase_value = if (all(is.na(dFreq))) NA_real_ else max(dFreq, na.rm = TRUE),
        max_increase_interval = if (all(is.na(dFreq))) NA_character_ else interval_2tp[which.max(dFreq)]
      ) %>%
      ungroup() %>%
      mutate(
        max_increase_interval = if_else(
          is.na(s_mean_CF_6_00),
          NA_character_,
          max_increase_interval
        )
      )

    df
  }

  # apply and overwrite
  for (nm in imported_names) {
    if (!exists(nm, envir = .GlobalEnv)) next
    df <- get(nm, envir = .GlobalEnv)
    if (!is.data.frame(df)) next

    df <- add_max_increase_interval(df)
    assign(nm, df, envir = .GlobalEnv)
  }

  sample_background_barcodes <- function(df, max_background = 3000, seed = 1) {
      req <- c("barcode", "s_mean_CF_6_00")
      if (!all(req %in% names(df))) return(df)

      bg_barcodes <- unique(df$barcode[is.na(df$s_mean_CF_6_00)])
      adaptive_barcodes <- unique(df$barcode[!is.na(df$s_mean_CF_6_00)])

      if (length(bg_barcodes) > max_background) {
        set.seed(seed)
        bg_barcodes <- sample(bg_barcodes, max_background)
      }

      keep_barcodes <- c(adaptive_barcodes, bg_barcodes)
      df[df$barcode %in% keep_barcodes, , drop = FALSE]
    }

  # ----------------------------
  # Tea leaves plots with interval-colored top lineages
  # ----------------------------
  for (nm in imported_names) {
    if (!exists(nm, envir = .GlobalEnv)) next
    df <- get(nm, envir = .GlobalEnv)

    if (!is.data.frame(df)) next
    if (!all(c("Time", "Frequency", "barcode", "max_increase_interval") %in% names(df))) next

    df$Time <- as.numeric(as.character(df$Time))
    df$Frequency <- as.numeric(df$Frequency)
    df$max_increase_interval <- factor(df$max_increase_interval, levels = interval_levels)

    df_plot <- sample_background_barcodes(df, max_background = 3000, seed = 1)

    p <- ggplot(df_plot, aes(x = Time, y = Frequency)) +
      geom_line(
        data = subset(df_plot, is.na(max_increase_interval)),
        aes(group = barcode),
        color = "grey90",
        alpha = 0.15,
        linewidth = 0.25
      ) +
      geom_line(
        data = subset(df_plot, !is.na(max_increase_interval) & !is.na(s_mean_CF_6_00)),
        aes(group = barcode, color = s_mean_CF_6_00),
        alpha = 0.95,
        linewidth = 0.45
      ) +
      scale_color_gradientn(
        colors = c("blue", "cyan", "green", "yellow", "orange", "red"),
        limits = c(s_min, s_max),
        oob = scales::squish,
        na.value = "grey90"
      ) +
      scale_y_log10() +
      xlab("Time") +
      ylab("Barcode frequency") +
      ggtitle(nm) +
      theme_bw()

    ggsave(
      filename = file.path(tealeaves_out_dir, paste0(nm, "_tealeaves.png")),
      plot = p,
      dpi = 300,
      width = 12,
      height = 8
    )
  }

  # ----------------------------
  # Per-interval plots
  # ----------------------------
  interval_out_dir <- file.path(output_dir, "interval_plots_CF6")
  dir.create(interval_out_dir, showWarnings = FALSE, recursive = TRUE)

  for (nm in imported_names) {
    if (!exists(nm, envir = .GlobalEnv)) next
    df <- get(nm, envir = .GlobalEnv)

    sample_interval_out_dir <- file.path(interval_out_dir, nm)
    dir.create(sample_interval_out_dir, showWarnings = FALSE, recursive = TRUE)

    if (!is.data.frame(df)) next
    if (!all(c("Time", "Frequency", "barcode", "max_increase_interval") %in% names(df))) next

    df$Time <- as.numeric(as.character(df$Time))
    df$Frequency <- as.numeric(df$Frequency)
    df$max_increase_interval <- factor(df$max_increase_interval, levels = interval_levels)

    df_plot <- sample_background_barcodes(df, max_background = 3000, seed = 1)

    for (intv in interval_levels) {
      df_intv <- subset(df_plot, max_increase_interval == intv)

      # write list of colored lineages for this interval plot
        if (nrow(df_intv) > 0) {
          lineage_tbl <- df_intv %>%
            filter(!is.na(s_mean_CF_6_00)) %>%
            distinct(barcode, max_increase_interval, s_mean_CF_6_00) %>%
            arrange(desc(s_mean_CF_6_00), barcode)

          write.table(
              lineage_tbl,
              file = file.path(sample_interval_out_dir, paste0(nm, "_interval_", intv, "_lineages.txt")),
              sep = "\t",
              row.names = FALSE,
              quote = FALSE
            )
        }
      if (nrow(df_intv) == 0) next

      p <- ggplot(df_plot, aes(x = Time, y = Frequency)) +
          geom_line(
            data = subset(df_plot, is.na(max_increase_interval) | max_increase_interval != intv),
            aes(group = barcode),
            color = "grey92",
            alpha = 0.12,
            linewidth = 0.25
          ) +
          geom_line(
            data = subset(df_plot, max_increase_interval == intv & !is.na(s_mean_CF_6_00)),
            aes(group = barcode, color = s_mean_CF_6_00),
            alpha = 0.9,
            linewidth = 0.5
          ) +
          scale_color_gradientn(
            colors = c("blue", "cyan", "green", "yellow", "orange", "red"),
            limits = c(s_min, s_max),
            oob = scales::squish
          ) +
          scale_y_log10() +
          labs(
            title = paste(nm, "-", intv),
            x = "Time",
            y = "Barcode frequency",
            color = "s_mean_CF_6_00"
          ) +
          theme_bw() +
          theme(
            legend.position = "right",
            axis.text = element_text(size = 10),
            axis.title = element_text(size = 10),
            plot.title = element_text(size = 14, face = "bold", hjust = 0.5)
          )

      ggsave(
          filename = file.path(sample_interval_out_dir, paste0(nm, "_interval_", intv, ".png")),
          plot = p,
          dpi = 300,
          width = 12,
          height = 8
        )
    }
  }

  # ----------------------------
  # DFE plots
  # ----------------------------
  dfe_out_dir <- file.path(output_dir, "DFE_plots")
  dir.create(dfe_out_dir, showWarnings = FALSE, recursive = TRUE)

  sample_colors <- c(
    NBC1 = "#FC8B62",
    NBC4 = "#F56B5C",
    NBC5 = "#E44F64",
    NDM1 = "#B6E4B3",
    NDM2 = "#86D0B9",
    NDM3 = "#54BDC2",
    XBC1 = "#DCBDC9",
    XBC3 = "#D19FC0",
    XBC5 = "#AC7299",
    XDM1 = "#82A0D2",
    XDM3 = "#356CAC",
    XDM4 = "#183456"
  )

  long_samples <- ls(pattern = "_long$", envir = .GlobalEnv)

  for (nm in long_samples) {
    df <- get(nm, envir = .GlobalEnv)
    sample_name <- sub("_long$", "", nm)
    message("Plotting ", sample_name)

    if (!is.data.frame(df) || nrow(df) == 0) next

    df <- df %>% mutate(CF = factor(CF, levels = sort(unique(CF))))

    # barcode counts per CF
    count_df <- df %>%
      distinct(barcode, CF) %>%
      count(CF, name = "n_barcodes")

    samp_col <- if (sample_name %in% names(sample_colors)) sample_colors[sample_name] else "#4C72B0"

    p_count <- ggplot(count_df, aes(x = factor(CF), y = n_barcodes)) +
      geom_col(fill = samp_col) +
      theme_bw() +
      xlab("Confidence Factor (CF)") +
      ylab("Number of adaptive barcodes") +
      ggtitle(paste0(sample_name, " – Adaptive barcodes per CF"))

    ggsave(
      file.path(dfe_out_dir, paste0(sample_name, "_barcode_counts.png")),
      p_count,
      dpi = 600,
      width = 6,
      height = 4,
      units = "in"
    )

    dfe <- df %>% filter(!is.na(s_mean))
    if (nrow(dfe) == 0) {
      message("  no s_mean data for ", sample_name, " -> skipping DFE")
      next
    }

    p_dfe_ridge <- ggplot(dfe, aes(x = s_mean, y = factor(CF))) +
      ggridges::geom_density_ridges_gradient(
        aes(fill = after_stat(x)),
        scale = 0.8,
        rel_min_height = 0,
        alpha = 0.95,
        bandwidth = 0.03
      ) +
      scale_fill_viridis_c(option = "viridis", begin = 0.1, end = 0.9) +
      geom_vline(xintercept = 0, linetype = "dashed", color = "grey40") +
      theme_bw() +
      xlab("Selection coefficient (s_mean)") +
      ylab("Confidence Factor (CF)") +
      ggtitle(paste0(sample_name, " – DFE")) +
      theme(legend.position = "right")

    ggsave(
      file.path(dfe_out_dir, paste0(sample_name, "_DFE_ridge.png")),
      p_dfe_ridge,
      dpi = 600,
      width = 8,
      height = 6,
      units = "in"
    )

    p_dfe <- ggplot(dfe, aes(x = s_mean, color = CF)) +
      geom_density(linewidth = 1, bw = 0.03) +
      scale_color_viridis_d(option = "viridis", begin = 0.1, end = 0.9) +
      theme_bw() +
      xlab("Selection coefficient (s_mean)") +
      ylab("Density") +
      ggtitle(paste0(sample_name, " – DFE by CF")) +
      theme(legend.position = "right")

    ggsave(
      file.path(dfe_out_dir, paste0(sample_name, "_DFE.png")),
      p_dfe,
      dpi = 600,
      width = 8,
      height = 6,
      units = "in"
    )
  }
}