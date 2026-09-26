#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Generate and verify a bounded patch for audit/traceability/traceability.csv.

Refreshes approved stale rows from the stale-row revalidation and disposition
(audit/analysis/tracecov-stale-row-disposition-2026-09-26.md).
Defaults to the approved 62-row CHANGED-RANGE batch (all re-reviewed in T-00091
and confirmed 'mapping holds'), while keeping all 64 NO-MATCHING-BLOB / QUARANTINE
rows strictly quarantined and excluded.
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

    Returns dict mapping revalidation class names:
    - 'UNCHANGED-RANGE': 7 rows
    - 'CHANGED-RANGE': 62 rows
    - 'NO-MATCHING-BLOB': 64 rows
    And backward-compatible/semantic aliases:
    - 'REFRESH-LEDGER': mapped to UNCHANGED-RANGE entries (per SAGE T-00089)
    - 'QUARANTINE': mapped to NO-MATCHING-BLOB entries
    """
    if not disposition_path.is_file():
        raise FileNotFoundError(f"Disposition file not found: {disposition_path}")

    groups: dict[str, list[dict]] = {
        "UNCHANGED-RANGE": [],
        "CHANGED-RANGE": [],
        "NO-MATCHING-BLOB": [],
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
            if reval_class in groups:
                groups[reval_class].append(entry)
            else:
                raise ValueError(f"Unknown revalidation_class in {disposition_path}: {reval_class}")

    # Aliases
    groups["REFRESH-LEDGER"] = groups["UNCHANGED-RANGE"]
    groups["QUARANTINE"] = groups["NO-MATCHING-BLOB"]

    return groups


def compute_file_sha256(path: Path) -> str:
    """Compute uppercase SHA256 hex digest of a file."""
    if not path.is_file():
        raise FileNotFoundError(f"Target Zig file does not exist: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


EXPECTED_UNCHANGED_RANGE_UIDS = {
    "TRC-028", "TRC-029", "TRC-055", "TRC-056", "TRC-075", "TRC-109", "TRC-189"
}

EXPECTED_CHANGED_RANGE_UIDS = {
    "TRC-007", "TRC-008", "TRC-009", "TRC-011", "TRC-013", "TRC-027", "TRC-038",
    "TRC-059", "TRC-060", "TRC-062", "TRC-072", "TRC-073", "TRC-074", "TRC-082",
    "TRC-088", "TRC-089", "TRC-100", "TRC-108", "TRC-116", "TRC-123", "TRC-136",
    "TRC-138", "TRC-153", "TRC-160", "TRC-162", "TRC-172", "TRC-175", "TRC-176",
    "TRC-178", "TRC-183", "TRC-184", "TRC-188", "TRC-196", "TRC-220", "TRC-225",
    "TRC-231", "TRC-237", "TRC-258", "TRC-293", "TRC-313", "TRC-315", "TRC-318",
    "TRC-321", "TRC-326", "TRC-331", "TRC-332", "TRC-333", "TRC-334", "TRC-335",
    "TRC-336", "TRC-337", "TRC-338", "TRC-339", "TRC-340", "TRC-351", "TRC-352",
    "TRC-353", "TRC-354", "TRC-355", "TRC-356", "TRC-357", "TRC-358",
}


def generate_traceability_patch(
    root: Path,
    csv_path: Path,
    disposition_path: Path,
    target: str = "changed-range",
) -> dict:
    """Build the bounded ledger patch and audit evidence without modifying the input CSV.

    When target='changed-range' (default):
      Refreshes the approved 62 CHANGED-RANGE rows re-reviewed in T-00091.
      Explicitly excludes all 64 NO-MATCHING-BLOB / QUARANTINE rows and all
      7 UNCHANGED-RANGE rows.

    When target='unchanged-range':
      Refreshes ONLY the 7 UNCHANGED-RANGE rows per SAGE T-00089 ruling.
      Explicitly excludes all 62 CHANGED-RANGE and all 64 NO-MATCHING-BLOB rows.

    Returns a dictionary containing:
    - original_content: str
    - patched_content: str
    - patch_diff: str (unified diff)
    - audit_report: dict (structured audit metadata)
    """
    groups = parse_disposition_table(disposition_path)

    unchanged_range_entries = groups["UNCHANGED-RANGE"]
    changed_range_entries = groups["CHANGED-RANGE"]
    quarantine_entries = groups["NO-MATCHING-BLOB"]

    # Enforce expected counts from revalidation
    if len(unchanged_range_entries) != 7:
        raise ValueError(f"Expected 7 UNCHANGED-RANGE rows, found {len(unchanged_range_entries)}")
    if len(changed_range_entries) != 62:
        raise ValueError(f"Expected 62 CHANGED-RANGE rows, found {len(changed_range_entries)}")
    if len(quarantine_entries) != 64:
        raise ValueError(f"Expected 64 NO-MATCHING-BLOB rows, found {len(quarantine_entries)}")

    actual_unchanged_uids = set(e["unit_id"] for e in unchanged_range_entries)
    if actual_unchanged_uids != EXPECTED_UNCHANGED_RANGE_UIDS:
        raise ValueError(f"Unexpected UNCHANGED-RANGE unit IDs: {actual_unchanged_uids} vs {EXPECTED_UNCHANGED_RANGE_UIDS}")

    actual_changed_uids = set(e["unit_id"] for e in changed_range_entries)
    if actual_changed_uids != EXPECTED_CHANGED_RANGE_UIDS:
        raise ValueError(f"Unexpected CHANGED-RANGE unit IDs: {actual_changed_uids} vs {EXPECTED_CHANGED_RANGE_UIDS}")

    unchanged_range_uids = sorted(actual_unchanged_uids)
    changed_range_uids = sorted(actual_changed_uids)
    quarantine_uids = sorted(set(e["unit_id"] for e in quarantine_entries))

    # Strict disjointness assertions
    overlap_uc = set(unchanged_range_uids) & set(changed_range_uids)
    if overlap_uc:
        raise ValueError(f"Fatal overlap between UNCHANGED-RANGE and CHANGED-RANGE: {overlap_uc}")
    overlap_uq = set(unchanged_range_uids) & set(quarantine_uids)
    if overlap_uq:
        raise ValueError(f"Fatal overlap between UNCHANGED-RANGE and NO-MATCHING-BLOB: {overlap_uq}")
    overlap_cq = set(changed_range_uids) & set(quarantine_uids)
    if overlap_cq:
        raise ValueError(f"Fatal overlap between CHANGED-RANGE and NO-MATCHING-BLOB: {overlap_cq}")

    if target == "changed-range":
        refresh_entries = changed_range_entries
        excluded_other_uids = set(unchanged_range_uids)
        expected_patch_count = 62
        mapping_classification = (
            "mapping-holds (all 62 rows re-reviewed in T-00091; 0 range-moved, 0 mapping-broken)"
        )
    elif target == "unchanged-range":
        refresh_entries = unchanged_range_entries
        excluded_other_uids = set(changed_range_uids)
        expected_patch_count = 7
        mapping_classification = (
            "byte-identical cited code range (7 rows reviewed in T-00089)"
        )
    else:
        raise ValueError(f"Unsupported target: {target}. Must be 'changed-range' or 'unchanged-range'.")

    refresh_map: dict[str, dict] = {e["unit_id"]: e for e in refresh_entries}

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

        # Guard: Quarantine and other-target rows MUST NOT be altered
        if unit_id in quarantine_uids:
            patched_lines.append(line)
            continue
        if unit_id in excluded_other_uids:
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
                "mapping_classification": "mapping-holds" if target == "changed-range" else "unchanged-range",
            })
        else:
            patched_lines.append(line)

    if len(modified_indices) != expected_patch_count:
        raise ValueError(f"Expected exactly {expected_patch_count} modified lines, got {len(modified_indices)}")

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
        "target_batch": target,
        "mapping_classification": mapping_classification,
        "input_traceability_csv": {
            "path": str(csv_path.as_posix()),
            "sha256": orig_sha,
            "total_rows": len(original_lines) - 1,
        },
        "input_disposition": {
            "path": str(disposition_path.as_posix()),
            "sha256": disp_sha,
            "total_stale_rows": len(unchanged_range_entries) + len(changed_range_entries) + len(quarantine_entries),
        },
        "summary": {
            "target_batch": target,
            "refresh_ledger_count": len(refresh_entries),
            "unchanged_range_count": len(unchanged_range_entries),
            "changed_range_count": len(changed_range_entries),
            "quarantine_count": len(quarantine_entries),
            "patched_rows_count": len(refreshed_details),
            "unmodified_rows_count": len(original_lines) - 1 - len(refreshed_details),
            "diff_removals": len([l for l in diff_lines if l.startswith("-") and not l.startswith("---")]),
            "diff_additions": len([l for l in diff_lines if l.startswith("+") and not l.startswith("+++")]),
        },
        "exclusions": {
            "quarantine_rows_excluded": len(quarantine_entries),
            "quarantine_unique_unit_ids": quarantine_uids,
            "unchanged_range_rows_excluded": len(unchanged_range_entries) if target == "changed-range" else 0,
            "unchanged_range_unique_unit_ids": unchanged_range_uids if target == "changed-range" else [],
            "changed_range_rows_excluded": len(changed_range_entries) if target == "unchanged-range" else 0,
            "changed_range_unique_unit_ids": changed_range_uids if target == "unchanged-range" else [],
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
    parser.add_argument("--target", choices=["changed-range", "unchanged-range"], default="changed-range",
                        help="Target batch to refresh (default: changed-range)")
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
        result = generate_traceability_patch(root, csv_path, disposition_path, target=args.target)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    summary = result["audit_report"]["summary"]
    exclusions = result["audit_report"]["exclusions"]
    print("Traceability patch generated and verified successfully:")
    print(f"  Target batch: {args.target}")
    print(f"  Total stale rows classified: {result['audit_report']['input_disposition']['total_stale_rows']}")
    print(f"  Rows refreshed ({args.target.upper()}): {summary['patched_rows_count']}")
    if args.target == "changed-range":
        print(f"  Rows excluded (UNCHANGED-RANGE): {exclusions['unchanged_range_rows_excluded']}")
    else:
        print(f"  Rows excluded (CHANGED-RANGE): {exclusions['changed_range_rows_excluded']}")
    print(f"  Rows excluded (QUARANTINE / NO-MATCHING-BLOB): {summary['quarantine_count']}")
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
