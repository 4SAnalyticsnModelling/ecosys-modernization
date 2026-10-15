#!/usr/bin/env python3
"""Compare two ecosys-ng output sets row-by-row and column-by-column, EXACTLY.

Why this exists: `outcompare.py` answers "Zig vs legacy Fortran". It cannot answer the
question a same-toolchain comparison asks — "did this rebuild/repeat/optimisation level move a
number in a real run?" — because near-equality is not what we want to know first: we want to know
whether the bytes are the same, and if not, exactly where the first difference is and how big.

Rules this tool never breaks:
  * It reports; it never decides. No tolerance turns a difference into a pass: `--atol/--rtol`
    only *classify* how large the differences are, and the run is only "identical" when the parsed
    decimal strings are equal for every compared cell.
  * Rows are aligned on the calendar key the model writes (year, day_of_year, hour), never on row
    order, so a stream that skips or reorders a row still lines up (and the missing rows are
    reported as `rows_only_in_a/b`).
  * Files present on one side only, or headers that differ, are reported as failures.

Usage (from the project root):

    uv run ecosys-audit/scripts/zig_run_diff.py \
        --a evidence/runs/<run-a>/deck/runottawa_output_files \
        --b evidence/runs/<run-b>/deck/runottawa_output_files \
        [--only water] [--max-diffs 5] [--json audit/runs/<id>/zigdiff.json]

`--a`/`--b` may be the `runottawa_output_files` root (walked recursively) or any directory of
tab-separated model output files; only files whose names match on both sides are compared.
Exit code: 0 identical, 1 differences found, 2 usage/setup error.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

KEY_COLUMNS = ("year", "day_of_year", "hour")


def find_streams(root: Path) -> dict[str, Path]:
    out: dict[str, Path] = {}
    for p in sorted(root.rglob("*.txt")):
        if not p.is_file() or p.name.startswith("write_output_options"):
            continue
        try:
            with p.open("r", encoding="utf-8", errors="strict") as fh:
                first = fh.readline()
        except OSError:
            continue
        if "\tyear\ton" in f"\t{first}" or first.startswith("year\t"):
            rel = str(p.relative_to(root))
            out[rel] = p
    return out


def read_stream(p: Path) -> tuple[list[str], dict[tuple, list[str]], int]:
    """Return (header, {key: cells}, malformed_row_count) reading decimal text as text."""
    with p.open("r", encoding="utf-8", errors="replace") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        idx = {name: i for i, name in enumerate(header)}
        key_idx = [idx[c] for c in KEY_COLUMNS if c in idx]
        if not key_idx:
            raise ValueError(f"{p}: header has none of {KEY_COLUMNS}: {header[:6]}")
        rows: dict[tuple, list[str]] = {}
        malformed = 0
        for line in fh:
            if not line.strip():
                continue
            cells = line.rstrip("\n").split("\t")
            if len(cells) != len(header):
                malformed += 1
                continue
            key = tuple(cells[i] for i in key_idx)
            rows[key] = cells
    return header, rows, malformed


def numeric(a: str, b: str) -> tuple[bool, float, float]:
    """(equal_text, abs_diff, rel_diff) for one cell; rel is inf-safe (0 when both zero)."""
    if a == b:
        return True, 0.0, 0.0
    try:
        x, y = float(a), float(b)
    except ValueError:
        return False, math.inf, math.inf
    if x == y:
        # Same value, different spelling (e.g. `-0e0` vs `0e0`): not a numeric difference,
        # but still reported through `text_only` so nothing is hidden.
        return False, 0.0, 0.0
    diff = abs(x - y)
    base = max(abs(x), abs(y))
    return False, diff, (diff / base if base else math.inf)


def compare_file(pa: Path, pb: Path, max_diffs: int, allow_extra_rows: bool = False) -> dict:
    ha, ra, bad_a = read_stream(pa)
    hb, rb, bad_b = read_stream(pb)
    res: dict = {
        "file": pa.name,
        "rows_a": len(ra),
        "rows_b": len(rb),
        "malformed_rows_a": bad_a,
        "malformed_rows_b": bad_b,
        "header_identical": ha == hb,
        "keys_only_in_a": 0,
        "keys_only_in_b": 0,
        "cells_compared": 0,
        "cells_differing": 0,
        "cells_text_only": 0,
        "max_abs": 0.0,
        "max_rel": 0.0,
        "worst": None,
        "first_diff": None,
        "diffs_sample": [],
    }
    if ha != hb:
        res["header_diff"] = {"a_only": [c for c in ha if c not in hb][:5],
                              "b_only": [c for c in hb if c not in ha][:5]}
    keys_a, keys_b = set(ra), set(rb)
    res["keys_only_in_a"] = len(keys_a - keys_b)
    res["keys_only_in_b"] = len(keys_b - keys_a)
    for key in sorted(keys_a & keys_b):
        ca, cb = ra[key], rb[key]
        for i, name in enumerate(ha[: min(len(ca), len(cb))]):
            if i < len(ha) and name in ("year", "day_of_year", "month", "day", "hour", "longitude", "latitude"):
                continue
            a, b = ca[i], cb[i]
            res["cells_compared"] += 1
            equal, ad, rd = numeric(a, b)
            if equal:
                continue
            res["cells_differing"] += 1
            if ad == 0.0:
                res["cells_text_only"] += 1
            entry = {"key": list(key), "column": name, "a": a, "b": b, "abs": ad, "rel": rd}
            if res["first_diff"] is None:
                res["first_diff"] = entry
            if ad > res["max_abs"] or (ad == res["max_abs"] and rd > res["max_rel"]):
                res["max_abs"], res["max_rel"], res["worst"] = ad, rd, entry
            if len(res["diffs_sample"]) < max_diffs:
                res["diffs_sample"].append(entry)
    one_sided_ok = allow_extra_rows or (not res["keys_only_in_a"] and not res["keys_only_in_b"])
    res["extra_rows_allowed"] = allow_extra_rows
    res["identical"] = (res["header_identical"] and one_sided_ok and res["cells_differing"] == 0
                        and not bad_a and not bad_b)
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", type=Path, required=True, help="first output root (the baseline side)")
    ap.add_argument("--b", type=Path, required=True, help="second output root (the candidate side)")
    ap.add_argument("--only", action="append", default=[],
                    help="limit to streams whose path contains this substring (repeatable), e.g. --only water")
    ap.add_argument("--max-diffs", type=int, default=5, help="sample differences kept per file")
    ap.add_argument("--allow-extra-rows", action="store_true",
                    help="a run that stopped earlier/later is not a difference: rows keyed only on one side are "
                         "counted and reported, but only the common keys decide identity")
    ap.add_argument("--json", type=Path, default=None, help="write the full report here")
    a = ap.parse_args()
    for p in (a.a, a.b):
        if not p.is_dir():
            print(json.dumps({"status": "ERROR", "error": f"not a directory: {p}"}), file=sys.stderr)
            return 2
    sa, sb = find_streams(a.a), find_streams(a.b)
    if a.only:
        sa = {k: v for k, v in sa.items() if any(s in k for s in a.only)}
        sb = {k: v for k, v in sb.items() if any(s in k for s in a.only)}
    common = sorted(set(sa) & set(sb))
    report = {
        "a": str(a.a), "b": str(a.b),
        "files_a": len(sa), "files_b": len(sb), "files_compared": len(common),
        "files_only_in_a": sorted(set(sa) - set(sb))[:10],
        "files_only_in_b": sorted(set(sb) - set(sa))[:10],
        "streams": [],
    }
    bad = 0
    for rel in common:
        try:
            r = compare_file(sa[rel], sb[rel], a.max_diffs, a.allow_extra_rows)
        except ValueError as e:
            r = {"file": rel, "error": str(e), "identical": False}
        r["stream_path"] = rel
        report["streams"].append(r)
        if not r.get("identical"):
            bad += 1
    report["streams_identical"] = len(common) - bad
    report["streams_differing"] = bad
    report["allow_extra_rows"] = a.allow_extra_rows
    report["status"] = "IDENTICAL" if bad == 0 and not report["files_only_in_a"] and not report["files_only_in_b"] else "DIFFERENT"
    if a.json:
        a.json.parent.mkdir(parents=True, exist_ok=True)
        a.json.write_text(json.dumps(report, indent=1, sort_keys=False) + "\n", encoding="utf-8")
    top = {k: report[k] for k in ("status", "files_a", "files_b", "files_compared", "streams_identical",
                                  "streams_differing", "allow_extra_rows", "files_only_in_a", "files_only_in_b")}
    top["one_sided_rows"] = sum(s["keys_only_in_a"] + s["keys_only_in_b"] for s in report["streams"]
                                if "keys_only_in_a" in s)
    top["worst_overall"] = max((s.get("worst") or {"abs": 0.0, "rel": 0.0, "file": None, "column": None, "key": None}
                                for s in report["streams"]), key=lambda w: w["abs"], default=None)
    top["first_difference"] = next(({"file": s["file"], **s["first_diff"]} for s in report["streams"]
                                    if s.get("first_diff")), None)
    print(json.dumps(top, indent=1))
    if a.json:
        print(f"full report: {a.json}", file=sys.stderr)
    return 0 if report["status"] == "IDENTICAL" else 1


if __name__ == "__main__":
    sys.exit(main())
