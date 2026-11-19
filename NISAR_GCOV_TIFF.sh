#!/usr/bin/env bash
# NISAR_GCOV_TIFF.sh -- launcher for NISAR_GCOV_TO_TIFF.py
# Last updated: 2026-11-18
#
# Change log
#   2026-11-18  Help text for provisional/validated support in the Python
#               processor: CRID threshold (5030), exception-mask rules,
#               frequencyB 8x8 fold, CRID in output names, duplicate
#               handling, LIA grid-north correction and DEM-version note.
#               Launcher prints the script version date and processor path.
#               New --mosaic_across_modes yes|no (default no).
set -euo pipefail

SCRIPT_VERSION="2026-11-18"

usage() {
cat <<'USAGE'
NISAR_GCOV_TIFF.sh  (last updated 2026-11-18)

Usage:
  bash NISAR_GCOV_TIFF.sh \
    --input_dir INPUT \
    --output_dir OUTPUT \
    [options]

Purpose:
  Convert NISAR L2 GCOV HDF5 files to fixed-grid GeoTIFFs/mosaics with
  optional incidence-angle and terrain-local-incidence-angle outputs.

  SAR GeoTIFF values remain LINEAR power. Quicklook SAR panels are displayed
  in dB using 10*log10(power). With --lia yes, the quicklook becomes 2x2:
      co-pol dB | cross-pol dB
      LIA (deg) | incidence angle (deg)

Automatic EPSG selection (default):
  --target_epsg auto

  The Python processor reads and prints the native EPSG code from every
  compatible NISAR HDF5 file, then:
    1. uses the EPSG occurring most often;
    2. if the highest counts are tied, uses the EPSG from the first readable
       tied file in sorted filename order.

  Files incompatible with --pol_pair are not included in the EPSG vote.
  For example, SHSH files do not affect an HH_HV run.

Product maturity by CRID:
  The composite release ID in the filename (e.g. ..._P05036_N_F_J_001.h5)
  decides how each file's inputDataExceptionMask is read:

    CRID <  5030  provisional (as P05023)
                  uint8; a pixel is valid only where the value is 0.
                  frequencyB: the layer is stored on the 10 m frequencyA
                  grid; each 8x8 block is folded onto one 80 m frequencyB
                  pixel, which is rejected if ANY sub-pixel is flagged.

    CRID >= 5030  validated (as P05036)
                  uint16, sized per frequency; a pixel is valid only where
                  the value is not fill (65535), has no anomaly bit
                  (low byte = 0), and has the validity bit set for both
                  selected polarizations (HH=256, HV=512, VH=1024,
                  VV=2048, ...; a good HH/HV pixel is 768).

  If the stored mask type contradicts the CRID, the processor warns and
  uses the rule matching the data. The threshold is CRID_VALIDATED_MIN in
  NISAR_GCOV_TO_TIFF.py.

  Output filenames include the CRID (e.g. ..._20261110_P05036_100m_...),
  so provisional and validated products of one acquisition never collide.
  Files whose names match in every field except CRID and product counter
  are duplicates; only the highest CRID is kept. Files that also differ in
  another field (e.g. orbit accuracy _F_ vs _N_) are all processed, each
  to its own CRID-named output.

Required:
  --input_dir PATH         Folder containing NISAR GCOV .h5/.hdf5 files
  --output_dir PATH         Output folder

EPSG/grid options:
  --grid_mode MODE          UTM (default) | EASE2 (M0p1; EPSG:6933)
  --ease2_mat PATH          Optional EASE2 reference MAT validation
  --target_epsg VALUE       auto or an explicit projected EPSG code
                            Default: auto
  --scale M                 Output pixel size in metres (default 100)
  --grid_origin_x X         Fixed grid origin easting (default 0)
  --grid_origin_y Y         Fixed grid origin northing (default 0)
  --bbox "W S E N"          Optional clip box in EPSG:4326

Data options:
  --frequency NAME          frequencyA | frequencyB (default frequencyA)
  --pol_pair PAIR           auto | HH_HV | VV_VH | RH_RV (default auto)
  --normalization TYPE      gamma0 | sigma0 (default gamma0)
  --mode MODE               nofilt | enhanced_lee | gamma_map | all
                            Default: nofilt
  --window N                Speckle-filter window, odd >=3 (default 7)
  --noise_floor VALUE       Linear-power threshold; 0 disables (default 0)
  --min_coverage F          Minimum valid native area per output pixel
                            Default: 0.90
  --use_exception_mask VAL  yes|no. Default: yes
                            yes: exclude pixels flagged by
                                 inputDataExceptionMask (e.g. NISAR sample
                                 slip/shift). The rule follows the CRID
                                 (see "Product maturity by CRID" below).
                            no:  keep those pixels instead of masking them,
                                 provided they pass every other check
  --lia yes|no              Generate incidence-angle + local-incidence-angle
                            GeoTIFFs on the same final grid and SAR-valid mask
                            (default no). LIA = acos(LOS . terrain normal);
                            the NISAR ENU line of sight is rotated into the
                            projected grid frame (meridian convergence)
                            before use. Works for frequencyA and frequencyB.
  --lia_dem_scale M         Internal terrain scale used for LIA before final
                            aggregation (default 30 m)
  --dem_dir PATH            Folder of already-downloaded local NISAR DEM
                            GeoTIFF tiles (e.g. from NASA Earthdata Search).
                            Used only with --lia yes. All .tif/.tiff tiles in
                            this folder are mosaicked into a VRT and used
                            instead of downloading -- no network access or
                            Earthdata credentials needed. Takes precedence
                            over --nisar_dem_vrt.
  --nisar_dem_vrt PATH      Optional local/VSI/URL override for NISAR DEM VRT.
                            Ignored when --dem_dir is supplied.
                            Default: NISAR DEM v1.2 (EPSG:4326 VRT on ASF).
                            Validated products may report DEM v1.3 in their
                            metadata; the log then prints a NOTE. v1.3 is
                            not publicly available yet.
  --dem_cache_dir PATH      Persistent DEM cache. Existing matching DEMs are
                            reused instead of downloaded/reprojected again.
                            Default: <input_dir>/DEM_Cache

Mosaic/performance options:
  --mosaic yes|no           Mosaic adjacent compatible frames (default yes)
  --mosaic_across_modes yes|no
                            Default: no. Frames acquired in different
                            bandwidth modes (4-digit code in the filename,
                            e.g. 2005 = 20 MHz, 4005 = 40 MHz frequencyA)
                            are normally never mosaicked together. With yes,
                            adjacent frames of the same track/date/pol/CRID
                            merge even when their modes differ, including
                            the source flag after the polarization
                            (A = single mode, M = mixed-mode frame at a
                            mode change, e.g. t165 f100/f102); the output
                            name lists all modes (e.g. f100-102_2005-4005)
                            and the log warns that a faint seam is possible
                            at mode boundaries.
  --gap_threshold KM        Maximum inter-frame gap (default 50)
  --workers N               Parallel acquisition groups (default 1)
  --tile_workers N          GDAL warp threads per group (default 4)
  --tile_size_km KM         Output processing window size (default 50)
  --native_block_px N       Native HDF5 block size (default 1024)
  --keep_intermediate yes|no
                            Keep temporary native rasters (default no)

Execution options:
  --script PATH             Python processor path
  --python_exec PATH        Python executable (default python3)
  --extra_args "ARGS"       Additional whitespace-separated Python arguments
  -h, --help

Examples:

  # Automatic EPSG from the NISAR HDF5 files
  bash NISAR_GCOV_TIFF.sh \
    --input_dir /path/to/gcov \
    --output_dir /path/to/output \
    --target_epsg auto \
    --scale 100 --mode nofilt --mosaic yes --lia yes

  # Explicit national/regional grid override
  bash NISAR_GCOV_TIFF.sh \
    --input_dir /path/to/gcov \
    --output_dir /path/to/output \
    --target_epsg 3577 \
    --scale 100 --mode nofilt --mosaic yes

  # Use already-downloaded local DEM tiles instead of downloading
  bash NISAR_GCOV_TIFF.sh \
    --input_dir /path/to/gcov \
    --output_dir /path/to/output \
    --lia yes \
    --dem_dir /gpfs/data1/vclgp/lalp/NISAR_Data/DEM \
    --scale 100 --mode nofilt --mosaic yes
USAGE
}

INPUT_DIR=""
OUTPUT_DIR=""
TARGET_EPSG="auto"
GRID_MODE="UTM"
EASE2_MAT=""
MODE="nofilt"
MOSAIC="yes"
MOSAIC_ACROSS_MODES="no"
WORKERS="1"
TILE_WORKERS="4"
TILE_SIZE_KM="50"
NATIVE_BLOCK_PX="1024"
SCALE="100"
GRID_ORIGIN_X="0"
GRID_ORIGIN_Y="0"
FREQUENCY="frequencyA"
POL_PAIR="auto"
NORMALIZATION="gamma0"
WINDOW="7"
NOISE_FLOOR="0"
MIN_COVERAGE="0.90"
USE_EXCEPTION_MASK="yes"
LIA="no"
LIA_DEM_SCALE="30"
DEM_DIR=""
NISAR_DEM_VRT=""
DEM_CACHE_DIR=""
EARTHDATA_COOKIE="/tmp/gdal_cookies.txt"
GAP_THRESHOLD="50"
BBOX=""
KEEP_INTERMEDIATE="no"
EXTRA_ARGS=""
PYTHON_EXEC="python3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/NISAR_GCOV_TO_TIFF.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input_dir) INPUT_DIR="$2"; shift 2 ;;
    --output_dir) OUTPUT_DIR="$2"; shift 2 ;;
    --target_epsg) TARGET_EPSG="$2"; shift 2 ;;
    --grid_mode|--grid) GRID_MODE="${2^^}"; shift 2 ;;
    --ease2_mat) EASE2_MAT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --mosaic) MOSAIC="$2"; shift 2 ;;
    --mosaic_across_modes) MOSAIC_ACROSS_MODES="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --tile_workers) TILE_WORKERS="$2"; shift 2 ;;
    --tile_size_km) TILE_SIZE_KM="$2"; shift 2 ;;
    --native_block_px) NATIVE_BLOCK_PX="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --grid_origin_x) GRID_ORIGIN_X="$2"; shift 2 ;;
    --grid_origin_y) GRID_ORIGIN_Y="$2"; shift 2 ;;
    --frequency) FREQUENCY="$2"; shift 2 ;;
    --pol_pair) POL_PAIR="$2"; shift 2 ;;
    --normalization) NORMALIZATION="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --noise_floor) NOISE_FLOOR="$2"; shift 2 ;;
    --min_coverage) MIN_COVERAGE="$2"; shift 2 ;;
    --use_exception_mask) USE_EXCEPTION_MASK="$2"; shift 2 ;;
    --lia) LIA="$2"; shift 2 ;;
    --lia_dem_scale) LIA_DEM_SCALE="$2"; shift 2 ;;
    --dem_dir) DEM_DIR="$2"; shift 2 ;;
    --nisar_dem_vrt) NISAR_DEM_VRT="$2"; shift 2 ;;
    --dem_cache_dir) DEM_CACHE_DIR="$2"; shift 2 ;;
    --earthdata_cookie) EARTHDATA_COOKIE="$2"; shift 2 ;;
    --gap_threshold) GAP_THRESHOLD="$2"; shift 2 ;;
    --bbox) BBOX="$2"; shift 2 ;;
    --keep_intermediate) KEEP_INTERMEDIATE="$2"; shift 2 ;;
    --script) SCRIPT_PATH="$2"; shift 2 ;;
    --python_exec) PYTHON_EXEC="$2"; shift 2 ;;
    --extra_args) EXTRA_ARGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$INPUT_DIR" ]] || { echo "--input_dir is required" >&2; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { echo "--output_dir is required" >&2; exit 1; }
[[ -d "$INPUT_DIR" ]] || { echo "Input directory not found: $INPUT_DIR" >&2; exit 1; }
[[ -f "$SCRIPT_PATH" ]] || { echo "Python script not found: $SCRIPT_PATH" >&2; exit 1; }
command -v "$PYTHON_EXEC" >/dev/null 2>&1 || { echo "Python executable not found: $PYTHON_EXEC" >&2; exit 1; }

if [[ -n "$DEM_DIR" ]]; then
  [[ -d "$DEM_DIR" ]] || { echo "DEM directory not found: $DEM_DIR" >&2; exit 1; }
fi

if [[ -z "$DEM_CACHE_DIR" ]]; then
  DEM_CACHE_DIR="${INPUT_DIR}/DEM_Cache"
fi

case "$GRID_MODE" in UTM|EASE2) ;; *) echo "Invalid --grid_mode: $GRID_MODE" >&2; exit 1 ;; esac
[[ -z "$EASE2_MAT" || -f "$EASE2_MAT" ]] || { echo "EASE2 MAT not found: $EASE2_MAT" >&2; exit 1; }
case "$MODE" in nofilt|enhanced_lee|gamma_map|all) ;; *) echo "Invalid --mode: $MODE" >&2; exit 1 ;; esac
case "$MOSAIC" in yes|no) ;; *) echo "Invalid --mosaic: $MOSAIC" >&2; exit 1 ;; esac
case "$MOSAIC_ACROSS_MODES" in yes|no) ;; *) echo "Invalid --mosaic_across_modes: $MOSAIC_ACROSS_MODES" >&2; exit 1 ;; esac
case "$FREQUENCY" in frequencyA|frequencyB) ;; *) echo "Invalid --frequency: $FREQUENCY" >&2; exit 1 ;; esac
case "$POL_PAIR" in auto|HH_HV|VV_VH|RH_RV) ;; *) echo "Invalid --pol_pair: $POL_PAIR" >&2; exit 1 ;; esac
case "$NORMALIZATION" in gamma0|sigma0) ;; *) echo "Invalid --normalization: $NORMALIZATION" >&2; exit 1 ;; esac
case "$KEEP_INTERMEDIATE" in yes|no) ;; *) echo "Invalid --keep_intermediate: $KEEP_INTERMEDIATE" >&2; exit 1 ;; esac
case "$USE_EXCEPTION_MASK" in yes|no) ;; *) echo "Invalid --use_exception_mask: $USE_EXCEPTION_MASK" >&2; exit 1 ;; esac
case "$LIA" in yes|no) ;; *) echo "Invalid --lia: $LIA" >&2; exit 1 ;; esac
if [[ "$TARGET_EPSG" != "auto" && "$TARGET_EPSG" != "AUTO" ]]; then
  [[ "$TARGET_EPSG" =~ ^[0-9]+$ ]] || {
    echo "--target_epsg must be 'auto' or a numeric EPSG code" >&2
    exit 1
  }
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

launch_job() {
  local label="$1"
  local filter_name="$2"
  local destination="$3"
  mkdir -p "$destination"
  local log_file="${destination}/launcher_${label}_${TIMESTAMP}.log"

  local cmd=(
    "$PYTHON_EXEC" "$SCRIPT_PATH"
    --input_dir "$INPUT_DIR"
    --output_dir "$destination"
    --target_epsg "$TARGET_EPSG"
    --grid_mode "$GRID_MODE"
    --scale "$SCALE"
    --grid_origin_x "$GRID_ORIGIN_X"
    --grid_origin_y "$GRID_ORIGIN_Y"
    --frequency "$FREQUENCY"
    --pol_pair "$POL_PAIR"
    --normalization "$NORMALIZATION"
    --filter "$filter_name"
    --filter_window "$WINDOW"
    --noise_floor "$NOISE_FLOOR"
    --min_coverage "$MIN_COVERAGE"
    --use_exception_mask "$USE_EXCEPTION_MASK"
    --lia "$LIA"
    --lia_dem_scale "$LIA_DEM_SCALE"
    --dem_cache_dir "$DEM_CACHE_DIR"
    --earthdata_cookie "$EARTHDATA_COOKIE"
    --mosaic "$MOSAIC"
    --mosaic_across_modes "$MOSAIC_ACROSS_MODES"
    --gap_threshold "$GAP_THRESHOLD"
    --workers "$WORKERS"
    --tile_workers "$TILE_WORKERS"
    --tile_size_km "$TILE_SIZE_KM"
    --native_block_px "$NATIVE_BLOCK_PX"
    --keep_intermediate "$KEEP_INTERMEDIATE"
  )

  if [[ -n "$EASE2_MAT" ]]; then
    cmd+=(--ease2_mat "$EASE2_MAT")
  fi

  if [[ -n "$DEM_DIR" ]]; then
    cmd+=(--dem_dir "$DEM_DIR")
  elif [[ -n "$NISAR_DEM_VRT" ]]; then
    cmd+=(--nisar_dem_vrt "$NISAR_DEM_VRT")
  fi

  if [[ -n "$BBOX" ]]; then
    read -r -a bbox_values <<< "$BBOX"
    [[ ${#bbox_values[@]} -eq 4 ]] || {
      echo "--bbox requires four values: W S E N" >&2
      exit 1
    }
    cmd+=(--bbox "${bbox_values[@]}")
  fi

  if [[ -n "$EXTRA_ARGS" ]]; then
    read -r -a extra_values <<< "$EXTRA_ARGS"
    cmd+=("${extra_values[@]}")
  fi

  nohup "${cmd[@]}" >"$log_file" 2>&1 &
  local pid=$!

  echo "Launched $label"
  echo "  Launcher version: $SCRIPT_VERSION"
  echo "  Processor       : $SCRIPT_PATH"
  echo "  CRID rule       : < 5030 provisional, >= 5030 validated"
  echo "  PID             : $pid"
  echo "  Grid mode       : $GRID_MODE"
  echo "  EPSG selection  : $TARGET_EPSG"
  echo "  Pixel/grid      : ${SCALE} m, origin (${GRID_ORIGIN_X}, ${GRID_ORIGIN_Y})"
  echo "  Mosaic          : $MOSAIC (across modes: $MOSAIC_ACROSS_MODES)"
  echo "  Exception mask  : $USE_EXCEPTION_MASK"
  echo "  Earthdata cookie: $EARTHDATA_COOKIE"
  echo "  LIA/incidence   : $LIA"
  if [[ "$LIA" == "yes" ]]; then
    echo "  LIA DEM scale   : ${LIA_DEM_SCALE} m"
    if [[ -n "$DEM_DIR" ]]; then
      echo "  DEM source      : local folder ($DEM_DIR)"
    else
      echo "  DEM source      : ${NISAR_DEM_VRT:-default NISAR DEM VRT}"
    fi
    echo "  DEM cache       : $DEM_CACHE_DIR"
  fi
  echo "  Output          : $destination"
  echo "  Launcher log    : $log_file"
  echo "  EPSG/result log : tail -f '$log_file'"
  echo
}

if [[ "$MODE" == "all" ]]; then
  echo "WARNING: --mode all starts three independent processors."
  echo "For a scientific baseline, run --mode nofilt first."
  launch_job nofilt none "${OUTPUT_DIR}/nofilt"
  launch_job enhanced_lee enhanced_lee "${OUTPUT_DIR}/enhanced_lee"
  launch_job gamma_map gamma_map "${OUTPUT_DIR}/gamma_map"
else
  case "$MODE" in
    nofilt) FILTER_NAME="none" ;;
    enhanced_lee) FILTER_NAME="enhanced_lee" ;;
    gamma_map) FILTER_NAME="gamma_map" ;;
  esac
  launch_job "$MODE" "$FILTER_NAME" "$OUTPUT_DIR"
fi