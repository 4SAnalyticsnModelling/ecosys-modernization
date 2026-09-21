#!/usr/bin/env python3
"""restartalign.py -- check that legacy ECOSYS restart writes and reads align.

Legacy restart I/O is SEQUENTIAL UNFORMATTED Fortran: records are consumed
positionally, so one extra or missing record misaligns every subsequent read
and silently corrupts all downstream restored state. This tool pairs each
`WRITE(u)` in a writer routine with the correspondingly-positioned `READ(u)`
in its reader routine and compares the number of top-level I/O-list items.

Run from the project root:

    uv run ecosys-audit/scripts/restartalign.py
    uv run ecosys-audit/scripts/restartalign.py --unit 21
    uv run ecosys-audit/scripts/restartalign.py --json

WHAT THIS DOES NOT PROVE -- quote these alongside any number from this tool,
per CLAUDE.md:

  * It compares ITEM COUNTS per statement, not identities. It does not verify
    that item k of a write is the same variable as item k of its read.
  * Identifiers legitimately differ between writer and reader, so names cannot
    be the invariant: the first unit-21 record writes `I,IDATA(3)` and reads
    back `IDATE,IYR`. Both are 26 items.
  * It does not evaluate implied-DO bounds, so a pair whose loop EXTENT differs
    while its item count matches is not caught. JZ/JS/JP dimension agreement is
    assumed, not proven.
  * It does not execute anything. No checkpoint is written or read back, in
    either the Fortran or the Zig implementation. A real round-trip test is a
    separate, still-missing piece of evidence (see
    audit/features/feature-026-restart-checkpoint-io.md).
  * Alignment being clean says nothing about whether ecosys-ng's checkpoint
    subsystem covers the same state.

Do NOT count these statements with a line-prefix grep. `^\\s{6,}WRITE\\(21`
versus `READ\\(21` reports 275 versus 274 and looks like a real one-record
asymmetry; it is a regex artifact, because fixed-form continuation lines and
leading statement labels are not handled. Parsing continuations gives 275 on
both sides.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LIMITATIONS = [
    "compares top-level I/O-list item counts per logical statement, not variable identities",
    "identifiers legitimately differ between writer and reader, so names are not the invariant",
    "implied-DO bounds are not evaluated; equal item counts with unequal loop extent are not caught",
    "no execution: no checkpoint is written or read back in either implementation",
    "says nothing about whether ecosys-ng's checkpoint subsystem covers the same state",
]

# (writer, reader, unit) -- the six restart streams in the in-build legacy scope.
PAIRS = [
    ("f77src/wouts.f", "f77src/routs.f", "21"),
    ("f77src/wouts.f", "f77src/routs.f", "22"),
    ("f77src/woutp.f", "f77src/routp.f", "26"),
    ("f77src/woutp.f", "f77src/routp.f", "27"),
    ("f77src/woutp.f", "f77src/routp.f", "28"),
    ("f77src/woutp.f", "f77src/routp.f", "29"),
]


def logical_statements(path: Path, keyword: str, unit: str):
    """Yield (first_line_number, io_list_payload) for each `keyword(unit)`.

    Fixed-form rules applied: a line continues the previous statement when
    column 6 (index 5) holds anything other than a blank or '0'; a line is a
    comment when column 1 is C, c, * or !. Columns 1-5 (labels) are dropped.
    """
    raw = path.read_text(encoding="utf-8", errors="replace").splitlines()
    joined: list[list] = []
    for lineno, line in enumerate(raw, start=1):
        if not line.strip() or line[0] in "Cc*!":
            continue
        is_continuation = len(line) > 5 and line[5] not in (" ", "0")
        body = line[6:] if len(line) > 6 else ""
        if is_continuation and joined:
            joined[-1][1] += body.strip()
        else:
            joined.append([lineno, body.strip()])

    head = re.compile(rf"^{keyword}\s*\(\s*{unit}\b")
    for lineno, text in joined:
        compact = text.replace(" ", "")
        if not head.match(compact):
            continue
        depth = 0
        for i, ch in enumerate(compact):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    yield lineno, compact[i + 1 :]
                    break


def item_count(payload: str) -> int:
    """Number of top-level comma-separated I/O-list items."""
    if not payload:
        return 0
    depth = 0
    items = 1
    for ch in payload:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            items += 1
    return items


def compare(root: Path, writer: str, reader: str, unit: str, verbose: bool) -> dict:
    writes = list(logical_statements(root / writer, "WRITE", unit))
    reads = list(logical_statements(root / reader, "READ", unit))
    divergences = []
    for index, (w, r) in enumerate(zip(writes, reads)):
        if item_count(w[1]) != item_count(r[1]):
            divergences.append(
                {
                    "pair_index": index,
                    "write": f"{writer}:{w[0]}",
                    "write_items": item_count(w[1]),
                    "read": f"{reader}:{r[0]}",
                    "read_items": item_count(r[1]),
                }
            )
            if verbose:
                print(f"  DIVERGENCE at pair {index}:")
                print(f"    {writer}:{w[0]} ({item_count(w[1])} items) {w[1][:160]}")
                print(f"    {reader}:{r[0]} ({item_count(r[1])} items) {r[1][:160]}")
    return {
        "unit": unit,
        "writer": writer,
        "reader": reader,
        "write_statements": len(writes),
        "read_statements": len(reads),
        "count_matches": len(writes) == len(reads),
        "item_count_divergences": divergences,
        "aligned": len(writes) == len(reads) and not divergences,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="project root (use a relative path)")
    parser.add_argument("--unit", help="check only this logical unit")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    args = parser.parse_args()

    root = Path(args.root)
    pairs = [p for p in PAIRS if args.unit is None or p[2] == args.unit]
    if not pairs:
        print(f"no known restart stream on unit {args.unit}; known units: "
              f"{', '.join(sorted({p[2] for p in PAIRS}))}", file=sys.stderr)
        return 2

    results = []
    for writer, reader, unit in pairs:
        for name in (writer, reader):
            if not (root / name).is_file():
                print(f"missing source file: {root / name}", file=sys.stderr)
                return 2
        if not args.json:
            print(f"unit {unit}: {writer} -> {reader}")
        results.append(compare(root, writer, reader, unit, verbose=not args.json))

    total_pairs = sum(min(r["write_statements"], r["read_statements"]) for r in results)
    total_div = sum(len(r["item_count_divergences"]) for r in results)
    aligned = all(r["aligned"] for r in results)

    if args.json:
        print(json.dumps({
            "streams": results,
            "total_statement_pairs": total_pairs,
            "total_divergences": total_div,
            "all_aligned": aligned,
            "limitations": LIMITATIONS,
        }, indent=2))
    else:
        for r in results:
            print(f"  unit {r['unit']}: WRITE={r['write_statements']} READ={r['read_statements']} "
                  f"divergences={len(r['item_count_divergences'])} "
                  f"{'ALIGNED' if r['aligned'] else 'NOT ALIGNED'}")
        print(f"\ntotal statement pairs: {total_pairs}; divergences: {total_div}; "
              f"all aligned: {aligned}")
        print("\nlimitations (report these with the number above):")
        for item in LIMITATIONS:
            print(f"  - {item}")

    return 0 if aligned else 1


if __name__ == "__main__":
    raise SystemExit(main())
