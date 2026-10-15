#!/usr/bin/env python3
"""Zig 0.17 module-membership analysis + shim-import routing for ecosys-ng.

Zig 0.17 requires a source file to belong to exactly one module: a file reached
both from the root module (`src/ecosys_ng.zig` + the `src/stages/*` and
`src/driver/*_fixture.zig` files it imports directly) and from the `ecosys_ng`
library module (rooted at `src/module_index.zig`) is a hard compile error —

    error: file exists in modules 'root' and 'ecosys_ng'

The 0.17 compatibility helpers (`core/typeinfo_compat.zig`,
`core/array_compat.zig`) live in the library module because ~180 library files
use them, so every *root-reachable* file must reach them through the library
export (`ecosys.array_compat`) instead of a second `@import` of the file.

This script computes the two reachable sets from the import graph and either
reports the collision (`--check`) or rewrites the shim import in root-reachable
files to the library-export form (`--fix`).  It changes no semantics and no
science: `ecosys.array_compat` is the same `pub const` namespace.

Usage:
  uv run ecosys-audit/scripts/zig017_module_membership.py --check
  uv run ecosys-audit/scripts/zig017_module_membership.py --fix [--only array_compat]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "ecosys-ng" / "src"
ROOT_ENTRY = SRC / "ecosys_ng.zig"
LIB_ENTRY = SRC / "module_index.zig"

# module names provided by build.zig / the std library, never file imports
EXTERNAL = {"std", "builtin", "testing", "ecosys_ng"}

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
DEP_ALIAS_RE = re.compile(r'^const (\w+) = @import\("ecosys_ng"\);$', re.M)
SHIM_RE = {
    "array_compat": re.compile(
        r'^const (arr_compat) = @import\("[^"]*core/array_compat\.zig"\);$', re.M
    ),
    "typeinfo_compat": re.compile(
        r'^const (ti_compat) = @import\("[^"]*core/typeinfo_compat\.zig"\);$', re.M
    ),
}


def imports_of(path: Path) -> list[Path]:
    """File imports of `path`, resolved relative to it (external names dropped)."""
    out: list[Path] = []
    for raw in IMPORT_RE.findall(path.read_text(encoding="utf-8")):
        if raw in EXTERNAL:
            continue
        target = (path.parent / raw).resolve()
        if target.suffix != ".zig":
            target = target.with_suffix(".zig")
        if target.is_file():
            out.append(target)
    return out


def closure(entry: Path) -> set[Path]:
    """Transitive file-import closure of `entry`, staying inside src/."""
    seen: set[Path] = set()
    stack = [entry]
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        stack.extend(imports_of(cur))
    return seen


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="report duplicate membership only")
    ap.add_argument("--fix", action="store_true", help="route shim imports through the library export")
    ap.add_argument("--only", default="array_compat", help="shim to rewrite (array_compat|typeinfo_compat)")
    args = ap.parse_args(argv)
    if not (args.check or args.fix):
        args.check = True

    root = closure(ROOT_ENTRY)
    lib = closure(LIB_ENTRY)
    shared = sorted(p for p in root & lib if p != ROOT_ENTRY)
    print(f"root-module files : {len(root)}")
    print(f"library files     : {len(lib)}")
    print(f"duplicate files   : {len(shared)}")
    for p in shared:
        print(f"  DUP {p.relative_to(REPO)}")

    if not args.fix:
        return 1 if shared else 0

    shim = SHIM_RE[args.only]
    changed = 0
    for path in sorted(root):
        if path == LIB_ENTRY:
            continue
        text = path.read_text(encoding="utf-8")
        found = shim.findall(text)
        if not found:
            continue
        dep = DEP_ALIAS_RE.search(text)
        if dep is None:
            print(f"  SKIP {path.relative_to(REPO)}: no `const X = @import(\"ecosys_ng\")` alias", file=sys.stderr)
            continue
        text = shim.sub(lambda m: f"const {m.group(1)} = {dep.group(1)}.{args.only};", text)
        path.write_text(text, encoding="utf-8")
        changed += 1
        print(f"  FIX  {path.relative_to(REPO)} -> {dep.group(1)}.array_compat ({len(found)} line)")
    print(f"rewritten files   : {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
