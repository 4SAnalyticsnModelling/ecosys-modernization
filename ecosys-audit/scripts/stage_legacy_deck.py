# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stage the Ottawa legacy deck from f77example/ leaving the original untouched.

Applies the two authorized record removals per T-00140 / T-00141 condition 2:
1. f25sol98: line 4 removed (van_genuchten_inflection_pressure_head_m...)
2. f25y98..f25y03: line 12 removed (weather_phase...)
Excludes Zig checkpoint binaries (*.bin) and previous output files.
Generates an SHA-256 manifest of all staged input files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

OUTPUT_PREFIXES = (
    "0101", "1010", "Cf", "Mf", "Nf", "Pf", "Qf", "Rf", "Wf",
    "logfile", "log98"
)

YEAR_FILES = ["f25y98", "f25y99", "f25y00", "f25y01", "f25y02", "f25y03"]


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().upper()


def stage_deck(src_dir: Path, dest_dir: Path) -> dict:
    src_dir = src_dir.resolve(strict=True)
    dest_dir = dest_dir.resolve()
    dest_dir.mkdir(parents=True, exist_ok=True)

    staged_manifest = {}
    skipped_bins = 0
    skipped_outputs = 0

    for item in sorted(src_dir.iterdir()):
        if not item.is_file():
            continue
        name = item.name

        # Skip Zig checkpoints
        if name.endswith(".bin"):
            skipped_bins += 1
            continue

        # Skip previous output files
        if any(name.startswith(pfx) for pfx in OUTPUT_PREFIXES):
            skipped_outputs += 1
            continue

        dest_file = dest_dir / name

        if name == "f25sol98":
            # Documented removal 1: line 4 (0-indexed line 3)
            # Preserve byte endings of the source file
            raw_lines = item.read_bytes().splitlines(keepends=True)
            if b"van_genuchten" not in raw_lines[3]:
                raise RuntimeError(f"Expected van_genuchten on line 4 of {name}, found: {raw_lines[3]}")
            modified_bytes = b"".join(raw_lines[:3] + raw_lines[4:])
            dest_file.write_bytes(modified_bytes)
        elif name in YEAR_FILES:
            # Documented removal 2: line 12 (0-indexed line 11)
            raw_lines = item.read_bytes().splitlines(keepends=True)
            if len(raw_lines) >= 12 and b"weather_phase" in raw_lines[11]:
                modified_bytes = b"".join(raw_lines[:11] + raw_lines[12:])
            elif len(raw_lines) == 11:
                # Already 11 lines
                modified_bytes = b"".join(raw_lines)
            else:
                raise RuntimeError(f"Unexpected line 12 content in {name}: {raw_lines[11] if len(raw_lines)>11 else 'short'}")
            dest_file.write_bytes(modified_bytes)
        else:
            shutil.copy2(item, dest_file)

        staged_manifest[name] = sha256_file(dest_file)

    report = {
        "status": "DECK_STAGED",
        "source_directory": str(src_dir),
        "staged_directory": str(dest_dir),
        "total_staged_files": len(staged_manifest),
        "skipped_checkpoints": skipped_bins,
        "skipped_outputs": skipped_outputs,
        "f25sol98_sha256": staged_manifest.get("f25sol98"),
        "year_files_sha256": {yf: staged_manifest.get(yf) for yf in YEAR_FILES},
        "manifest": staged_manifest
    }
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", type=Path, default=Path("f77example/Cool Temperate Maize-Soybean ON"))
    ap.add_argument("--dest", type=Path, required=True)
    ap.add_argument("--out-manifest", type=Path)
    a = ap.parse_args()

    report = stage_deck(a.src, a.dest)
    if a.out_manifest:
        a.out_manifest.parent.mkdir(parents=True, exist_ok=True)
        a.out_manifest.write_text(json.dumps(report, indent=2))

    print(json.dumps({
        "status": report["status"],
        "staged_directory": report["staged_directory"],
        "total_staged_files": report["total_staged_files"],
        "skipped_checkpoints": report["skipped_checkpoints"],
        "skipped_outputs": report["skipped_outputs"],
        "f25sol98_sha256": report["f25sol98_sha256"],
        "year_files": report["year_files_sha256"]
    }, indent=2))


if __name__ == "__main__":
    main()
