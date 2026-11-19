#!/usr/bin/env python3
"""MAAP DPS adapter for the 2026-11-18 NISAR_GCOV_TO_TIFF.py processor.

One NISAR GCOV granule per DPS job. The input AOI is used only to decide whether
this granule intersects the requested area; it NEVER clips the original frame.
Invoke the scientific processor directly and synchronously (not the nohup shell
launcher) so DPS sees real success/failure and collects finished output files.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse


DEM_VRT_DEFAULT = (
    "/vsis3/sds-n-cumulus-prod-nisar-products/DEM/v1.2/EPSG4326/EPSG4326.vrt"
)
S3_CREDENTIAL_URL = "https://nisar.asf.earthdatacloud.nasa.gov/s3credentials"
PAIR_DATASETS = {
    "HH_HV": ("HHHH", "HVHV"),
    "VV_VH": ("VVVV", "VHVH"),
    "RH_RV": ("RHRH", "RVRV"),
}


def get_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--s3_url", help="NISAR s3://...GCOV...h5 granule")
    source.add_argument("--local_h5", help="Local GCOV granule, for offline testing")
    parser.add_argument("--bbox", type=float, nargs=4, required=True,
                        metavar=("WEST", "SOUTH", "EAST", "NORTH"),
                        help="AOI intersection test only; never clips full-frame output")
    parser.add_argument("--grid_mode", choices=("EASE2", "UTM"), default="EASE2")
    parser.add_argument("--target_epsg", default="auto")
    parser.add_argument("--frequency", choices=("all", "frequencyA", "frequencyB"),
                        default="all")
    parser.add_argument("--pol_pair", choices=("all", *PAIR_DATASETS), default="all")
    parser.add_argument("--normalization", choices=("gamma0", "sigma0"), default="gamma0")
    parser.add_argument("--filter", choices=("none", "enhanced_lee", "gamma_map"),
                        default="enhanced_lee")
    parser.add_argument("--filter_window", type=int, default=7)
    parser.add_argument("--lia", choices=("yes", "no"), default="yes")
    parser.add_argument("--nisar_dem_vrt", default=DEM_VRT_DEFAULT)
    parser.add_argument("--dem_dir", help="Optional pre-staged local DEM tile folder")
    parser.add_argument("--lia_dem_scale", type=float, default=30)
    parser.add_argument("--min_coverage", type=float, default=0.90)
    parser.add_argument("--use_exception_mask", choices=("yes", "no"), default="yes")
    parser.add_argument("--noise_floor", type=float, default=0)
    parser.add_argument("--tile_workers", type=int, default=4)
    parser.add_argument("--native_block_px", type=int, default=1024)
    parser.add_argument("--keep_intermediate", choices=("yes", "no"), default="no")
    parser.add_argument("--output_dir", default="output")
    args = parser.parse_args(argv)
    west, south, east, north = args.bbox
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        parser.error("--bbox requires WEST < EAST and SOUTH < NORTH in WGS84")
    if args.filter_window < 3 or args.filter_window % 2 != 1:
        parser.error("--filter_window must be odd and >= 3")
    if args.tile_workers < 1 or args.native_block_px < 16:
        parser.error("--tile_workers must be >= 1 and --native_block_px >= 16")
    if not 0 < args.min_coverage <= 1:
        parser.error("--min_coverage must be in (0,1]")
    if args.grid_mode == "EASE2" and args.target_epsg not in ("auto", "6933"):
        parser.error("EASE2 always uses EPSG:6933")
    if args.s3_url:
        parsed = urlparse(args.s3_url)
        if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lower().endswith((".h5", ".hdf5")):
            parser.error("--s3_url must be an s3://bucket/...h5 or .hdf5 URL")
    return args


def download_granule(s3_url: str, destination: Path) -> dict[str, str]:
    # Defer MAAP/S3 imports so local synthetic tests do not require a MAAP login.
    import s3fs
    from maap.maap import MAAP

    creds = MAAP().aws.earthdata_s3_credentials(S3_CREDENTIAL_URL)
    required = ("accessKeyId", "secretAccessKey", "sessionToken")
    if not isinstance(creds, dict) or any(not creds.get(k) for k in required):
        raise RuntimeError("MAAP did not return usable temporary Earthdata S3 credentials")
    fs = s3fs.S3FileSystem(
        anon=False, key=creds["accessKeyId"], secret=creds["secretAccessKey"],
        token=creds["sessionToken"], requester_pays=True,
        client_kwargs={"region_name": "us-west-2"},
    )
    print(f"Downloading {s3_url} -> {destination}", flush=True)
    fs.get(s3_url, str(destination))
    if not destination.is_file() or destination.stat().st_size == 0:
        raise RuntimeError("NISAR download is empty or missing")
    print(f"Downloaded {destination.stat().st_size / 1024**3:.2f} GiB", flush=True)
    # This mapping is used only in process environment; never written to logs.
    return {
        "AWS_ACCESS_KEY_ID": creds["accessKeyId"],
        "AWS_SECRET_ACCESS_KEY": creds["secretAccessKey"],
        "AWS_SESSION_TOKEN": creds["sessionToken"],
        "AWS_REGION": "us-west-2", "AWS_DEFAULT_REGION": "us-west-2",
        "AWS_REQUEST_PAYER": "requester",
    }


def inspect_tasks(h5_path: Path, args):
    """Return (frequency, pair, names) for pairs that intersect the AOI."""
    import h5py
    from rasterio.warp import transform_bounds
    from NISAR_GCOV_TO_TIFF import inspect_frame, intersects, parse_filename

    info = parse_filename(str(h5_path))
    if info is None:
        raise RuntimeError(f"Unsupported GCOV filename: {h5_path.name}")
    root = "LSAR" if info["instrument"] == "L" else "SSAR"
    aoi_ease2 = transform_bounds("EPSG:4326", "EPSG:6933", *args.bbox, densify_pts=41)
    frequencies = ("frequencyA", "frequencyB") if args.frequency == "all" else (args.frequency,)
    pairs = PAIR_DATASETS if args.pol_pair == "all" else {args.pol_pair: PAIR_DATASETS[args.pol_pair]}
    tasks = []
    seen_any_pair = False
    with h5py.File(h5_path, "r") as h5:
        for freq in frequencies:
            prefix = f"/science/{root}/GCOV/grids/{freq}"
            if prefix not in h5:
                print(f"Skipping absent {freq}", flush=True)
                continue
            group = h5[prefix]
            present = {name for names in PAIR_DATASETS.values() for name in names if name in group}
            for pair, terms in pairs.items():
                if not all(term in present for term in terms):
                    continue
                seen_any_pair = True
                meta = inspect_frame(str(h5_path), freq, pair, 6933)
                if not intersects(meta.target_bounds, aoi_ease2):
                    print(f"Skipping {freq}/{pair}: granule outside AOI", flush=True)
                    continue
                tasks.append((freq, pair, terms))
            unpaired = sorted(present - {t for names in PAIR_DATASETS.values() if all(v in present for v in names) for t in names})
            if unpaired:
                print(f"Note {freq}: current processor does not implement single-pol channels {unpaired}; skipped", flush=True)

    if not tasks:
        reason = ("No available supported polarization pair intersects AOI" if seen_any_pair
                  else "No supported co-pol/cross-pol pair exists in this granule")
        raise RuntimeError(reason)
    return tasks


def assert_outputs(folder: Path, terms: tuple[str, str], args):
    """Fail DPS if successful exit hides a skipped/partial/invalid output set."""
    import rasterio

    for term in terms:
        matches = list(folder.glob(f"*_{term}.tif"))
        if len(matches) != 1:
            raise RuntimeError(f"Expected exactly one {term} TIFF in {folder}, found {len(matches)}")
        with rasterio.open(matches[0]) as src:
            if not src.width or not src.height or not src.crs or src.count != 1:
                raise RuntimeError(f"Invalid SAR output {matches[0]}")
            if src.tags().get("input_data_exception_mask_applied") != args.use_exception_mask:
                raise RuntimeError(f"Unexpected exception mask metadata in {matches[0]}")
            if args.grid_mode == "EASE2" and src.crs.to_epsg() != 6933:
                raise RuntimeError(f"Expected EASE2 EPSG:6933 in {matches[0]}")
    suffixes = ["_frame_count.tif"]
    if args.lia == "yes":
        suffixes += ["_incidence_angle_deg.tif", "_local_incidence_angle_deg.tif"]
    if args.grid_mode == "EASE2":
        suffixes.append("_EASE2_grid.mat")
    for suffix in suffixes:
        # "*_incidence_angle_deg.tif" also matches "*_local_incidence_angle_deg.tif";
        # exclude it so each product is counted exactly once.
        matches = [p for p in folder.glob(f"*{suffix}")
                   if not (suffix == "_incidence_angle_deg.tif"
                           and p.name.endswith("_local_incidence_angle_deg.tif"))]
        if len(matches) != 1 or matches[0].stat().st_size == 0:
            raise RuntimeError(f"Missing/incomplete {suffix} output in {folder}")


def run(args):
    from proj_setup import configure_projection_environment
    from NISAR_GCOV_TO_TIFF import product_maturity, parse_filename

    basedir = Path(__file__).resolve().parent
    processor = basedir / "NISAR_GCOV_TO_TIFF.py"
    if not processor.is_file():
        raise FileNotFoundError(processor)
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    env = configure_projection_environment()
    env.update({key: "1" for key in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "NUMEXPR_NUM_THREADS")})
    env.setdefault("GDAL_DISABLE_READDIR_ON_OPEN", "TRUE")
    input_root = Path.cwd() / "input"
    input_root.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="gcov_", dir=input_root) as temp_dir:
        temp_dir = Path(temp_dir)
        if args.s3_url:
            basename = Path(urlparse(args.s3_url).path).name
            h5_path = temp_dir / basename
            env.update(download_granule(args.s3_url, h5_path))
        else:
            original = Path(args.local_h5).expanduser().resolve()
            if not original.is_file():
                raise FileNotFoundError(original)
            h5_path = temp_dir / original.name
            shutil.copyfile(original, h5_path)

        metadata = parse_filename(str(h5_path))
        if metadata is None:
            raise RuntimeError("Unrecognized NISAR GCOV filename")
        print(f"CRID {metadata['crid']} -> {product_maturity(metadata['crid'])}; exception mask={args.use_exception_mask}", flush=True)
        tasks = inspect_tasks(h5_path, args)
        print(f"AOI {args.bbox}: intersection ONLY. No --bbox is passed to processor; FULL frame retained.", flush=True)

        for frequency, pair, terms in tasks:
            destination = output_dir / frequency / pair
            destination.mkdir(parents=True, exist_ok=True)
            command = [
                sys.executable, "-u", str(processor),
                "--input_dir", str(temp_dir),
                "--output_dir", str(destination),
                "--frequency", frequency, "--pol_pair", pair,
                "--grid_mode", args.grid_mode, "--target_epsg", args.target_epsg,
                "--normalization", args.normalization, "--filter", args.filter,
                "--filter_window", str(args.filter_window),
                "--min_coverage", str(args.min_coverage),
                "--use_exception_mask", args.use_exception_mask,
                "--noise_floor", str(args.noise_floor),
                "--lia", args.lia, "--lia_dem_scale", str(args.lia_dem_scale),
                "--dem_cache_dir", str(temp_dir / "DEM_Cache"),
                "--mosaic", "no", "--workers", "1",
                "--tile_workers", str(args.tile_workers),
                "--native_block_px", str(args.native_block_px),
                "--keep_intermediate", args.keep_intermediate,
            ]
            if args.dem_dir:
                command += ["--dem_dir", str(Path(args.dem_dir).resolve())]
            elif args.lia == "yes":
                command += ["--nisar_dem_vrt", args.nisar_dem_vrt]
            print("Running (synchronously):", " ".join(command), flush=True)
            subprocess.run(command, check=True, env=env)
            assert_outputs(destination, terms, args)
            results.append({"frequency": frequency, "pair": pair, "outputs": str(destination.relative_to(output_dir))})
            print(f"VERIFIED {frequency}/{pair}", flush=True)

    summary = {
        "granule": metadata["stem"],
        "crid": metadata["crid"],
        "product_maturity": product_maturity(metadata["crid"]),
        "aoi_selection_bbox": args.bbox,
        "aoi_does_not_clip_full_frame": True,
        "grid_mode": args.grid_mode,
        "filter": args.filter,
        "exception_mask_applied": args.use_exception_mask,
        "tasks": results,
    }
    (output_dir / "maap_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("MAAP DPS granule processing completed; output:", output_dir, flush=True)


def main(argv=None):
    run(get_args(argv))


if __name__ == "__main__":
    main()
