#!/usr/bin/env bash
# MAAP DPS Build Command: NISAR_GCOV_TIFF_MAAP/build_env.sh
set -euo pipefail
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${BASEDIR}${PYTHONPATH:+:${PYTHONPATH}}"
python --version

# Install required command-line GDAL tools in a base image with conda available.
if ! command -v gdalwarp >/dev/null 2>&1 || ! command -v gdalbuildvrt >/dev/null 2>&1; then
  if command -v conda >/dev/null 2>&1; then
    conda install -y -c conda-forge gdal
  else
    echo 'ERROR: gdalwarp/gdalbuildvrt missing, and base image has no conda.' >&2
    echo 'Choose a MAAP Pangeo/conda base image with GDAL or install GDAL in that image.' >&2
    exit 1
  fi
fi
command -v gdalwarp
command -v gdalbuildvrt
gdalwarp --version

python - <<'PY'
import importlib, importlib.util, subprocess, sys
modules = {
  'maap': 'maap-py', 's3fs': 's3fs', 'h5py': 'h5py',
  'numpy': 'numpy', 'rasterio': 'rasterio', 'scipy': 'scipy',
  'matplotlib': 'matplotlib'
}
missing = [package for module, package in modules.items() if importlib.util.find_spec(module) is None]
if missing:
    print('Installing Python packages:', missing, flush=True)
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', *missing])
for module in modules:
    importlib.import_module(module)
from maap.maap import MAAP
print('Python dependencies available', flush=True)
PY
python "${BASEDIR}/proj_setup.py"
python -m py_compile "${BASEDIR}/NISAR_GCOV_TO_TIFF.py" "${BASEDIR}/nisar_dps_wrapper.py"
# GDAL CLI and Rasterio can be backed by different GDAL binaries; validate both.
python - <<'PY'
import subprocess
from proj_setup import configure_projection_environment
env = configure_projection_environment(verbose=False)
subprocess.run(['gdalsrsinfo', 'EPSG:6933'], check=True, env=env,
               capture_output=True, text=True)
print('GDAL CLI EPSG:6933 verified', flush=True)
PY
