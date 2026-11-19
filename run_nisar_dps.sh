#!/usr/bin/env bash
# MAAP DPS Run Command: NISAR_GCOV_TIFF_MAAP/run_nisar_dps.sh
# Five positional inputs (S3 URL, W, S, E, N) match legacy MAAP jobs.
set -euo pipefail
if [[ "$#" -eq 0 ]]; then
  echo "Usage: run_nisar_dps.sh S3_URL W S E N" >&2
  echo "   or: run_nisar_dps.sh --s3_url s3://... --bbox W S E N" >&2
  exit 2
fi
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p output input
# No nohup: the MAAP worker must wait until all products are fully written.
DEFAULTS=(
  --output_dir output
  --grid_mode "${NISAR_GRID_MODE:-EASE2}"
  --target_epsg "${NISAR_TARGET_EPSG:-auto}"
  --frequency "${NISAR_FREQUENCY:-all}"
  --pol_pair "${NISAR_POL_PAIR:-all}"
  --normalization "${NISAR_NORMALIZATION:-gamma0}"
  --filter "${NISAR_FILTER:-enhanced_lee}"
  --filter_window "${NISAR_FILTER_WINDOW:-7}"
  --lia "${NISAR_LIA:-yes}"
  --min_coverage "${NISAR_MIN_COVERAGE:-0.90}"
  --use_exception_mask "${NISAR_USE_EXCEPTION_MASK:-yes}"
  --tile_workers "${NISAR_TILE_WORKERS:-4}"
)
if [[ "$#" -eq 5 && "$1" != --* ]]; then
  # Legacy positional MAAP job registration.
  exec python -u "${BASEDIR}/nisar_dps_wrapper.py" "${DEFAULTS[@]}" \
    --s3_url "$1" --bbox "$2" "$3" "$4" "$5"
else
  # Modern named-input invocation; explicit flags override environment defaults.
  exec python -u "${BASEDIR}/nisar_dps_wrapper.py" "${DEFAULTS[@]}" "$@"
fi
