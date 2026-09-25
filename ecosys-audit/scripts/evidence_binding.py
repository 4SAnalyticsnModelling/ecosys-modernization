# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compute the evidence binding every run/checkpoint/report is tied to (plan section 4).

binding = (source commit + dirty-diff hash, deck hash, build mode + options,
checkpoint schema version). `binding_id` is the sha256 of the canonical JSON.
Evidence produced under another binding is provisional. This records identity only;
it proves nothing about correctness.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from workflow import ROOT, ProtocolError, digest, encoded, file_digest

SOURCE_SCOPE = ("ecosys-ng/src", "ecosys-ng/build.zig", "ecosys-ng/build.zig.zon")
MANIFEST_ZIG = "ecosys-ng/src/io/checkpoint/manifest.zig"
LIMITATIONS = "Identity bookkeeping only; equal bindings do not prove equal behaviour on another machine or toolchain."


def git(root: Path, *args: str) -> bytes:
    p = subprocess.run(["git", *args], cwd=root, capture_output=True, timeout=300)
    if p.returncode:
        raise ProtocolError(f"git {' '.join(args)} failed: {p.stderr.decode(errors='replace')[:400]}")
    return p.stdout


def dirty_source_digest(root: Path, scope=SOURCE_SCOPE) -> dict:
    """Hash of tracked diff vs HEAD plus untracked file contents, restricted to source scope."""
    present = [s for s in scope if (root / s).exists()]
    if not present:
        return {"sha256": digest(b""), "dirty": False, "untracked": 0}
    diff = git(root, "diff", "--binary", "HEAD", "--", *present)
    untracked = [p for p in git(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *present).split(b"\0") if p]
    h = hashlib.sha256(diff)
    for rel in sorted(untracked):
        h.update(b"\0untracked\0" + rel + b"\0" + bytes.fromhex(file_digest(root / rel.decode())))
    return {"sha256": h.hexdigest(), "dirty": bool(diff or untracked), "untracked": len(untracked)}


def tree_digest(path: Path, exclude=re.compile(r"(^|/)(runottawa_output_files|\.zig-cache|zig-out)(/|$)")) -> dict:
    """Content hash of a deck directory (relative names + file hashes), outputs excluded."""
    if not path.is_dir():
        raise ProtocolError(f"Deck directory not found: {path}")
    h, count = hashlib.sha256(), 0
    for f in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = f.relative_to(path).as_posix()
        if exclude.search(rel):
            continue
        h.update(rel.encode() + b"\0" + bytes.fromhex(file_digest(f)) + b"\n")
        count += 1
    return {"sha256": h.hexdigest(), "files": count}


def checkpoint_schema(root: Path):
    p = root / MANIFEST_ZIG
    if not p.exists():
        return None
    m = re.search(r"const\s+version\s*:\s*u32\s*=\s*(\d+)\s*;", p.read_text(encoding="utf-8", errors="replace"))
    return int(m.group(1)) if m else None


def compute(root: Path, deck: str | None, build_mode: str | None, options: list[str]) -> dict:
    root = root.resolve()
    head = git(root, "rev-parse", "HEAD").decode().strip()
    binding = {
        "schema_version": 1,
        "source_commit": head,
        "source_dirty": dirty_source_digest(root),
        "deck": None if deck is None else {"path": deck, **tree_digest(root / deck)},
        "build": {"mode": build_mode, "options": sorted(options)},
        "checkpoint_schema_version": checkpoint_schema(root),
    }
    binding["binding_id"] = digest(json.dumps(binding, sort_keys=True, separators=(",", ":")).encode())
    return binding


def same(a: dict | None, b: dict | None) -> bool:
    return bool(a and b and a.get("binding_id") and a.get("binding_id") == b.get("binding_id"))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--deck", help="Project-relative deck directory, e.g. 'ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON'")
    ap.add_argument("--build-mode", choices=["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall", "gfortran-O2", "gfortran-O0-coverage"])
    ap.add_argument("--option", action="append", default=[], help="Build option, repeatable (e.g. -Dstate-dump=true)")
    ap.add_argument("--out", type=Path, help="Write binding JSON here (else stdout)")
    a = ap.parse_args()
    try:
        b = compute(a.root, a.deck, a.build_mode, a.option)
        b["limitations"] = LIMITATIONS
        data = encoded(b)
        if a.out:
            a.out.parent.mkdir(parents=True, exist_ok=True)
            a.out.write_bytes(data)
        sys.stdout.write(data.decode())
        return 0
    except (OSError, ProtocolError, subprocess.SubprocessError) as e:
        print(json.dumps({"error": str(e), "status": "BLOCKED"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
