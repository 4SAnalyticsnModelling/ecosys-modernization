# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Prepare an isolated legacy Fortran 77 build staging directory from f77src/.

Complies with T-00140/T-00141 condition 1 and T-00155 (issue-023):
- Exactly the 40 Fortran compilation units listed in f77src/makefile (SRCS),
  excluding redist_utf8.f (stray duplicate).
- All header files (*.h) from f77src/.
- C helpers splits.c and splitp.c from f77src/.
- Two documented scratch modifications:
  1. Insertion of '      EXTERNAL SPLIT\n' in soil.f prior to '      SAVE NF,NX,NTZ,NTZX'.
  2. Restoration of missing IYRC argument in grosub.f:12766 CASNC0 debug WRITE
     to match shared FORMAT 8821 (issue-023 / issue-084).
- All other files byte-for-byte identical to f77src/ reference.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

# 40 Fortran sources from f77src/makefile SRCS
F77_SRCS = [
    "BLOCKDATA001.f", "day.f", "erosion.f", "exec.f", "extract.f",
    "foutp.f", "fouts.f", "grosub.f", "hfunc.f", "hour1.f",
    "main.f", "nitro.f", "outpd.f", "outph.f", "outsd.f",
    "outsh.f", "readi.f", "readq.f", "reads.f", "redist.f",
    "routp.f", "routq.f", "routs.f", "soil.f", "solute.f",
    "split.f", "splitc.f", "starte.f", "startq.f", "starts.f",
    "stomate.f", "trnsfr.f", "trnsfrs.f", "uptake.f", "visual.f",
    "watsub.f", "woutp.f", "woutq.f", "wouts.f", "wthr.f"
]

C_SRCS = ["splits.c", "splitp.c"]


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--f77src", type=Path, default=Path("f77src"))
    ap.add_argument("--dest", type=Path, required=True)
    a = ap.parse_args()

    f77src = a.f77src.resolve(strict=True)
    dest = a.dest.resolve()
    dest.mkdir(parents=True, exist_ok=True)

    # 1. Copy headers
    headers = sorted(p.name for p in f77src.glob("*.h"))
    for h in headers:
        shutil.copy2(f77src / h, dest / h)

    # 2. Copy C sources
    for c in C_SRCS:
        shutil.copy2(f77src / c, dest / c)

    # 3. Copy Fortran sources (except soil.f and grosub.f which get patched)
    for f in F77_SRCS:
        if f in ("soil.f", "grosub.f"):
            continue
        shutil.copy2(f77src / f, dest / f)

    # 4. Patch soil.f with EXTERNAL SPLIT
    soil_lines = (f77src / "soil.f").read_text(encoding="latin-1").splitlines(keepends=True)
    out_lines = []
    inserted = False
    for line in soil_lines:
        if not inserted and "SAVE NF,NX,NTZ,NTZX" in line:
            out_lines.append("      EXTERNAL SPLIT\n")
            inserted = True
        out_lines.append(line)

    if not inserted:
        raise RuntimeError("Failed to locate insertion point in soil.f")

    (dest / "soil.f").write_text("".join(out_lines), encoding="latin-1")

    # 5. Patch grosub.f with issue-023 IYRC restore in CASNC0 debug print
    grosub_lines = (f77src / "grosub.f").read_text(encoding="latin-1").splitlines(keepends=True)
    out_grosub = []
    grosub_patched = False
    for line in grosub_lines:
        if not grosub_patched and "WRITE(*,8821)'CASNC0',I,J,NFZ,NX,NY,NZ,NB" in line:
            out_grosub.append(line.replace(
                "WRITE(*,8821)'CASNC0',I,J,NFZ,NX,NY,NZ,NB",
                "WRITE(*,8821)'CASNC0',IYRC,I,J,NFZ,NX,NY,NZ,NB"
            ))
            grosub_patched = True
        else:
            out_grosub.append(line)

    if not grosub_patched:
        raise RuntimeError("Failed to locate insertion point in grosub.f")

    (dest / "grosub.f").write_text("".join(out_grosub), encoding="latin-1")

    # 6. Verify and hash everything in dest
    manifest = {}
    for p in sorted(dest.iterdir()):
        if p.is_file():
            manifest[p.name] = sha256_file(p)

    print(json.dumps({
        "status": "STAGED",
        "staged_dir": str(dest),
        "total_files": len(manifest),
        "f_count": len(F77_SRCS),
        "c_count": len(C_SRCS),
        "h_count": len(headers),
        "soil_f_sha256": manifest["soil.f"],
        "grosub_f_sha256": manifest["grosub.f"],
        "manifest": manifest
    }, indent=2))


if __name__ == "__main__":
    main()
