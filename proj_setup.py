#!/usr/bin/env python3
"""Find and test a compatible PROJ database in MAAP's runtime environment."""
from __future__ import annotations
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

_CHECK = (
    "from rasterio.crs import CRS; from rasterio.warp import transform; "
    "assert CRS.from_epsg(6933).is_projected; "
    "x,y=transform('EPSG:4326','EPSG:6933',[78.0],[22.0]); "
    "assert len(x)==len(y)==1"
)


def _works(env):
    result = subprocess.run([sys.executable, "-c", _CHECK],
                            env=env, capture_output=True, text=True)
    return result.returncode == 0, (result.stderr or result.stdout).strip()


def configure_projection_environment(environ=None, verbose=True):
    base = dict(os.environ if environ is None else environ)
    if base.get("GDAL_DATA") and not Path(base["GDAL_DATA"]).is_dir():
        base.pop("GDAL_DATA", None)
    ok, err = _works(base)
    if ok:
        if verbose:
            print("PROJ/EPSG:6933 verified", flush=True)
        return base
    clean = base.copy()
    clean.pop("PROJ_DATA", None)
    clean.pop("PROJ_LIB", None)
    ok, err = _works(clean)
    if ok:
        if verbose:
            print("PROJ verified after clearing stale overrides", flush=True)
        return clean
    dirs = []
    for package, suffix in (("rasterio", "proj_data"), ("pyproj", "proj_dir/share/proj")):
        spec = importlib.util.find_spec(package)
        if spec and spec.submodule_search_locations:
            dirs.append(Path(next(iter(spec.submodule_search_locations))) / suffix)
    for prefix in (sys.prefix, base.get("CONDA_PREFIX"), "/opt/conda", "/srv/conda", "/usr/local", "/usr"):
        if prefix:
            dirs.append(Path(prefix) / "share/proj")
    for candidate in dirs:
        if not (candidate / "proj.db").is_file():
            continue
        trial = clean.copy()
        trial["PROJ_DATA"] = str(candidate)
        trial["PROJ_LIB"] = str(candidate)
        ok, err = _works(trial)
        if ok:
            if verbose:
                print(f"PROJ verified using {candidate}", flush=True)
            return trial
    raise RuntimeError(f"No compatible proj.db / EPSG:6933 database found: {err[-400:]}")


if __name__ == "__main__":
    configure_projection_environment()
