# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stage the Ottawa production deck with verified f6=100 runottawa blob.

Does three things:
1. Copies the files of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/`
   into DIR, read-only on the source.
2. Overwrites `DIR/runottawa` with the raw bytes of
   `git cat-file blob ecf5e61ab453288b1763f81f841729bee34e8426`.
3. Exits nonzero unless `git hash-object DIR/runottawa` equals that blob.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

TARGET_BLOB = "ecf5e61ab453288b1763f81f841729bee34e8426"
DEFAULT_SOURCE_REL = Path("ecosys-ng-prod-examples") / "Cool Temperate Maize-Soybean ON"


def find_repo_root(start: Path | None = None) -> Path:
    """Find repository root containing .git directory."""
    if start is None:
        start = Path(__file__).resolve().parent
    cur = start.resolve()
    for p in [cur] + list(cur.parents):
        if (p / ".git").is_dir() or (p / ".git").is_file():
            return p
    return Path.cwd().resolve()


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().lower()


def stage_ottawa_deck(
    out_dir: Path,
    src_dir: Path | None = None,
    repo_root: Path | None = None,
    blob_hash: str = TARGET_BLOB,
) -> dict:
    """Stage Ottawa deck into out_dir with verified blob overwrite.

    Parameters:
        out_dir: Destination directory.
        src_dir: Source deck directory (default: repo_root / DEFAULT_SOURCE_REL).
        repo_root: Repository root for git commands.
        blob_hash: Expected git blob sha for runottawa.

    Returns:
        Summary dict containing status and file counts.
    """
    if repo_root is None:
        repo_root = find_repo_root()
    repo_root = repo_root.resolve()

    if src_dir is None:
        src_dir = repo_root / DEFAULT_SOURCE_REL
    else:
        src_dir = Path(src_dir).resolve()

    if not src_dir.is_dir():
        raise FileNotFoundError(f"Source deck directory not found: {src_dir}")

    out_dir = Path(out_dir).resolve()

    # Safety checks: protected paths must not be staged into
    for protected in ("ecosys-ng-prod-examples", "f77src", "f77example"):
        prot_path = (repo_root / protected).resolve()
        if out_dir == prot_path or prot_path in out_dir.parents:
            raise ValueError(f"Refusing to stage deck into protected path: {out_dir}")

    if out_dir == src_dir or src_dir in out_dir.parents:
        raise ValueError(f"Refusing to stage deck onto or inside source directory: {src_dir}")

    git_bin = shutil.which("git") or "git"

    # Step 1: Copy files from source directory into out_dir (read-only on source)
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src_dir, out_dir, dirs_exist_ok=True)

    # Step 2: Overwrite DIR/runottawa with raw bytes of git cat-file blob <blob_hash>
    dest_runottawa = out_dir / "runottawa"
    try:
        raw_bytes = subprocess.check_output(
            [git_bin, "-C", str(repo_root), "cat-file", "blob", blob_hash]
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"Failed to fetch git cat-file blob {blob_hash} from repo {repo_root}: {e}"
        ) from e

    if dest_runottawa.exists():
        try:
            dest_runottawa.chmod(0o666)
        except OSError:
            pass
    dest_runottawa.write_bytes(raw_bytes)

    # Step 3: Verify git hash-object DIR/runottawa equals blob_hash
    try:
        proc = subprocess.run(
            [git_bin, "hash-object", str(dest_runottawa)],
            capture_output=True,
            text=True,
            check=True,
        )
        actual_hash = proc.stdout.strip()
    except (subprocess.CalledProcessError, OSError) as e:
        raise RuntimeError(f"git hash-object {dest_runottawa} failed: {e}") from e

    if actual_hash != blob_hash:
        raise RuntimeError(
            f"git hash-object verification failed for {dest_runottawa}: "
            f"expected {blob_hash}, got {actual_hash}"
        )

    staged_files = [p for p in out_dir.rglob("*") if p.is_file()]

    return {
        "status": "DECK_STAGED",
        "source_directory": str(src_dir),
        "staged_directory": str(out_dir),
        "target_blob": blob_hash,
        "runottawa_hash": actual_hash,
        "total_staged_files": len(staged_files),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Target directory for staged deck (required)",
    )
    parser.add_argument(
        "--src",
        type=Path,
        default=None,
        help=f"Source deck directory (default: {DEFAULT_SOURCE_REL})",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Repository root directory (default: autodetected)",
    )
    parser.add_argument(
        "--blob",
        type=str,
        default=TARGET_BLOB,
        help=f"Target git blob hash for runottawa (default: {TARGET_BLOB})",
    )
    args = parser.parse_args(argv)

    try:
        report = stage_ottawa_deck(
            out_dir=args.out,
            src_dir=args.src,
            repo_root=args.repo,
            blob_hash=args.blob,
        )
        print(json.dumps(report, indent=2))
        return 0
    except Exception as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
