#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Generate and verify a bounded patch for audit/traceability/traceability.csv.

Refreshes ONLY rows classified as REFRESH-LEDGER in the stale-row revalidation
(audit/analysis/tracecov-stale-row-disposition-2026-09-26.md).
Explicitly excludes all QUARANTINE rows (64 entries, 44 unique unit_ids) and
all NO-ACTION rows (7 entries).
Leaves the canonical ledger untouched while producing auditable patch artifacts
for SAGE review.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import sys


def parse_disposition_table(disposition_path: Path) -> dict[str, list[dict]]:
    """Parse the authoritative disposition markdown table.

    Returns dict mapping disposition name ('REFRESH-LEDGER', 'NO-ACTION', 'QUARANTINE')
    to list of row dictionaries.
    """
    if not disposition_path.is_file():
        raise FileNotFoundError(f"Disposition file not found: {disposition_path}")

    groups: dict[str, list[dict]] = {
        "REFRESH-LEDGER": [],
        "NO-ACTION": [],
        "QUARANTINE": [],
    }

    with disposition_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("| TRC-"):
                continue
            parts = [p.strip() for p in line.split("|")[1:-1]]
            if len(parts) < 6:
                continue
            unit_id, zig_path, cited_hash, reval_class, disposition, reason = parts[:6]
            entry = {
                "unit_id": unit_id,
                "zig_path": zig_path,
                "cited_hash": cited_hash,
                "revalidation_class": reval_class,
                "disposition": disposition,
                "reason": reason,
            }
            if disposition in groups:
                groups[disposition].append(entry)
            else:
                raise ValueError(f"Unknown disposition in {disposition_path}: {disposition}")

    return groups


def compute_file_sha256(path: Path) -> str:
    """Compute uppercase SHA256 hex digest of a file."""
    if not path.is_file():
        raise FileNotFoundError(f"Target Zig file does not exist: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def generate_traceability_patch(
    root: Path,
    csv_path: Path,
    disposition_path: Path,
) -> dict:
    """Build the bounded ledger patch and audit evidence without modifying the input CSV.

    Returns a dictionary containing:
    - original_content: str
    - patched_content: str
    - patch_diff: str (unified diff)
    - audit_report: dict (structured audit metadata)
    """
    groups = parse_disposition_table(disposition_path)

    refresh_entries = groups["REFRESH-LEDGER"]
    no_action_entries = groups["NO-ACTION"]
    quarantine_entries = groups["QUARANTINE"]

    # Enforce expected counts from T-00086 / T-00087 revalidation
    if len(refresh_entries) != 62:
        raise ValueError(f"Expected 62 REFRESH-LEDGER rows, found {len(refresh_entries)}")
    if len(no_action_entries) != 7:
        raise ValueError(f"Expected 7 NO-ACTION rows, found {len(no_action_entries)}")
    if len(quarantine_entries) != 64:
        raise ValueError(f"Expected 64 QUARANTINE rows, found {len(quarantine_entries)}")

    refresh_map: dict[str, dict] = {e["unit_id"]: e for e in refresh_entries}
    quarantine_uids = sorted(set(e["unit_id"] for e in quarantine_entries))
    no_action_uids = sorted(set(e["unit_id"] for e in no_action_entries))

    # Strict disjointness assertions
    overlap_rq = set(refresh_map.keys()) & set(quarantine_uids)
    if overlap_rq:
        raise ValueError(f"Fatal overlap between REFRESH-LEDGER and QUARANTINE: {overlap_rq}")
    overlap_rn = set(refresh_map.keys()) & set(no_action_uids)
    if overlap_rn:
        raise ValueError(f"Fatal overlap between REFRESH-LEDGER and NO-ACTION: {overlap_rn}")
    overlap_qn = set(quarantine_uids) & set(no_action_uids)
    if overlap_qn:
        raise ValueError(f"Fatal overlap between QUARANTINE and NO-ACTION: {overlap_qn}")

    with csv_path.open("r", encoding="utf-8", newline="") as f:
        original_lines = f.readlines()

    refreshed_details = []
    patched_lines = []
    modified_indices = []

    for idx, line in enumerate(original_lines):
        # Parse row using csv reader to identify unit_id and column indices accurately
        parsed_row = list(csv.reader([line]))[0]
        if not parsed_row:
            patched_lines.append(line)
            continue

        unit_id = parsed_row[0].strip()

        # Guard: Quarantine and No-Action rows MUST NOT be altered
        if unit_id in quarantine_uids:
            patched_lines.append(line)
            continue
        if unit_id in no_action_uids:
            patched_lines.append(line)
            continue

        if unit_id in refresh_map:
            entry = refresh_map[unit_id]
            zig_rel = entry["zig_path"]
            zig_abs = root / zig_rel
            cur_sha = compute_file_sha256(zig_abs)

            old_sha = parsed_row[8].strip()
            if old_sha.upper() == cur_sha.upper():
                raise ValueError(f"Row {unit_id} is not stale; already matches current hash {cur_sha}")

            # Verify that old_sha appears exactly once in the raw line to ensure safe substitution
            occurrences = line.upper().count(old_sha.upper())
            if occurrences != 1:
                raise ValueError(
                    f"Row {unit_id} line contains {occurrences} occurrences of hash {old_sha}; "
                    "cannot safely do single replacement"
                )

            # Perform exact string replacement to preserve formatting, quoting, and CRLF line ending
            new_line = line.replace(old_sha, cur_sha)
            if new_line == line:
                # In case case differed, try case-insensitive replacement
                idx_pos = line.upper().find(old_sha.upper())
                new_line = line[:idx_pos] + cur_sha + line[idx_pos + len(old_sha):]

            # Verify that the parsed fields after replacement match exactly on columns 0..7 and 9..17
            new_parsed = list(csv.reader([new_line]))[0]
            if len(new_parsed) != len(parsed_row):
                raise ValueError(f"Row {unit_id} field count changed after replacement")
            if new_parsed[:8] != parsed_row[:8] or new_parsed[9:] != parsed_row[9:]:
                raise ValueError(f"Row {unit_id} altered columns outside zig_sha256!")
            if new_parsed[8].strip() != cur_sha:
                raise ValueError(f"Row {unit_id} zig_sha256 was not correctly updated to {cur_sha}")

            patched_lines.append(new_line)
            modified_indices.append(idx)
            refreshed_details.append({
                "line_number": idx + 1,
                "unit_id": unit_id,
                "zig_path": zig_rel,
                "old_sha256": old_sha,
                "new_sha256": cur_sha,
            })
        else:
            patched_lines.append(line)

    if len(modified_indices) != 62:
        raise ValueError(f"Expected exactly 62 modified lines, got {len(modified_indices)}")

    original_text = "".join(original_lines)
    patched_text = "".join(patched_lines)

    rel_path = csv_path.resolve().relative_to(root.resolve()).as_posix()
    orig_stripped = [l.rstrip("\r\n") for l in original_lines]
    patched_stripped = [l.rstrip("\r\n") for l in patched_lines]

    diff_lines = list(difflib.unified_diff(
        orig_stripped,
        patched_stripped,
        fromfile=f"a/{rel_path}",
        tofile=f"b/{rel_path}",
        lineterm="",
    ))
    patch_diff = "\n".join(diff_lines) + "\n"

    # Compute checksums
    orig_sha = hashlib.sha256(original_text.encode("utf-8")).hexdigest()
    patched_sha = hashlib.sha256(patched_text.encode("utf-8")).hexdigest()
    disp_sha = hashlib.sha256(disposition_path.read_bytes()).hexdigest()

    audit_report = {
        "schema_version": 1,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "input_traceability_csv": {
            "path": str(csv_path.as_posix()),
            "sha256": orig_sha,
            "total_rows": len(original_lines) - 1,
        },
        "input_disposition": {
            "path": str(disposition_path.as_posix()),
            "sha256": disp_sha,
            "total_stale_rows": len(refresh_entries) + len(no_action_entries) + len(quarantine_entries),
        },
        "summary": {
            "refresh_ledger_count": len(refresh_entries),
            "no_action_count": len(no_action_entries),
            "quarantine_count": len(quarantine_entries),
            "patched_rows_count": len(refreshed_details),
            "unmodified_rows_count": len(original_lines) - 1 - len(refreshed_details),
            "diff_removals": len([l for l in diff_lines if l.startswith("-") and not l.startswith("---")]),
            "diff_additions": len([l for l in diff_lines if l.startswith("+") and not l.startswith("+++")]),
        },
        "exclusions": {
            "quarantine_rows_excluded": len(quarantine_entries),
            "quarantine_unique_unit_ids": quarantine_uids,
            "no_action_rows_excluded": len(no_action_entries),
            "no_action_unique_unit_ids": no_action_uids,
        },
        "patched_traceability_csv": {
            "sha256": patched_sha,
            "refreshed_rows": refreshed_details,
        },
    }

    return {
        "original_content": original_text,
        "patched_content": patched_text,
        "patch_diff": patch_diff,
        "audit_report": audit_report,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_root = Path(__file__).resolve().parents[2]
    parser.add_argument("--root", type=Path, default=default_root,
                        help="Root repository directory")
    parser.add_argument("--csv", type=Path, default=None,
                        help="Path to traceability.csv")
    parser.add_argument("--disposition", type=Path, default=None,
                        help="Path to disposition markdown")
    parser.add_argument("--out-patch", type=Path, default=None,
                        help="Path to write unified diff patch")
    parser.add_argument("--out-csv", type=Path, default=None,
                        help="Path to write staged patched CSV")
    parser.add_argument("--out-report", type=Path, default=None,
                        help="Path to write audit JSON report")
    parser.add_argument("--check", action="store_true",
                        help="Perform verification without writing output files")

    args = parser.parse_args()
    root = args.root.resolve()
    csv_path = args.csv or (root / "audit" / "traceability" / "traceability.csv")
    disposition_path = args.disposition or (
        root / "audit" / "analysis" / "tracecov-stale-row-disposition-2026-09-26.md"
    )

    try:
        result = generate_traceability_patch(root, csv_path, disposition_path)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    summary = result["audit_report"]["summary"]
    print("Traceability patch generated and verified successfully:")
    print(f"  Total stale rows classified: {result['audit_report']['input_disposition']['total_stale_rows']}")
    print(f"  Rows refreshed (REFRESH-LEDGER): {summary['refresh_ledger_count']}")
    print(f"  Rows excluded (NO-ACTION): {summary['no_action_count']}")
    print(f"  Rows excluded (QUARANTINE): {summary['quarantine_count']}")
    print(f"  Diff lines: -{summary['diff_removals']} / +{summary['diff_additions']}")
    print(f"  Patched CSV SHA-256: {result['audit_report']['patched_traceability_csv']['sha256']}")

    if args.out_patch:
        args.out_patch.parent.mkdir(parents=True, exist_ok=True)
        args.out_patch.write_text(result["patch_diff"], encoding="utf-8")
        print(f"  Wrote patch diff: {args.out_patch}")

    if args.out_csv:
        args.out_csv.parent.mkdir(parents=True, exist_ok=True)
        # Preserve exact binary encoding / CRLF
        args.out_csv.write_text(result["patched_content"], encoding="utf-8", newline="")
        print(f"  Wrote staged CSV: {args.out_csv}")

    if args.out_report:
        args.out_report.parent.mkdir(parents=True, exist_ok=True)
        args.out_report.write_text(json.dumps(result["audit_report"], indent=2), encoding="utf-8")
        print(f"  Wrote audit report: {args.out_report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
