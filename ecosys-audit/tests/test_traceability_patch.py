# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit and integration tests for the bounded traceability patch tool."""
from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ecosys-audit" / "scripts"))

from traceability_patch import (
    compute_file_sha256,
    generate_traceability_patch,
    parse_disposition_table,
)


class TraceabilityPatchTestCase(unittest.TestCase):
    def setUp(self):
        self.root = ROOT
        self.csv_path = self.root / "audit" / "traceability" / "traceability.csv"
        self.disposition_path = (
            self.root / "audit" / "analysis" / "tracecov-stale-row-disposition-2026-09-26.md"
        )
        self.canonical_sha = "9dee3fbb29d8ae182021f2ac07f1cb728cc669473674223c3e18bc035bdfd24a"
        self.expected_unchanged_uids = {
            "TRC-028", "TRC-029", "TRC-055", "TRC-056", "TRC-075", "TRC-109", "TRC-189"
        }

    def test_canonical_csv_unmodified(self):
        """Canonical ledger must remain read-only and match recorded hash."""
        current_sha = hashlib.sha256(self.csv_path.read_bytes()).hexdigest().lower()
        self.assertEqual(current_sha, self.canonical_sha)

    def test_disposition_counts(self):
        """Disposition table must categorize exactly 7 UNCHANGED-RANGE, 62 CHANGED-RANGE, 64 NO-MATCHING-BLOB."""
        groups = parse_disposition_table(self.disposition_path)
        self.assertEqual(len(groups["UNCHANGED-RANGE"]), 7)
        self.assertEqual(len(groups["CHANGED-RANGE"]), 62)
        self.assertEqual(len(groups["NO-MATCHING-BLOB"]), 64)

    def test_strict_disjointness(self):
        """Disposition sets must be strictly mutually exclusive and match expected unit IDs."""
        groups = parse_disposition_table(self.disposition_path)
        unchanged = set(e["unit_id"] for e in groups["UNCHANGED-RANGE"])
        changed = set(e["unit_id"] for e in groups["CHANGED-RANGE"])
        quarantine = set(e["unit_id"] for e in groups["NO-MATCHING-BLOB"])

        self.assertEqual(unchanged, self.expected_unchanged_uids)
        self.assertEqual(len(unchanged), 7)
        self.assertEqual(len(changed), 62)
        self.assertEqual(len(quarantine), 44)  # 64 entries across 44 distinct unit_ids

        self.assertEqual(unchanged & changed, set())
        self.assertEqual(unchanged & quarantine, set())
        self.assertEqual(changed & quarantine, set())

    def test_patch_generation_and_constraints(self):
        """Generated patch must strictly alter only the 7 UNCHANGED-RANGE rows and only column index 8."""
        result = generate_traceability_patch(self.root, self.csv_path, self.disposition_path)

        orig_lines = result["original_content"].splitlines(keepends=True)
        patched_lines = result["patched_content"].splitlines(keepends=True)
        self.assertEqual(len(orig_lines), len(patched_lines))
        self.assertEqual(len(orig_lines), 374)  # 1 header + 373 data rows

        groups = parse_disposition_table(self.disposition_path)
        changed_range_uids = set(e["unit_id"] for e in groups["CHANGED-RANGE"])
        quarantine_uids = set(e["unit_id"] for e in groups["NO-MATCHING-BLOB"])

        modified_uids = set()
        for orig, patched in zip(orig_lines, patched_lines):
            orig_parsed = list(csv.reader([orig]))[0]
            patched_parsed = list(csv.reader([patched]))[0]
            uid = orig_parsed[0].strip()

            if orig != patched:
                modified_uids.add(uid)
                self.assertIn(uid, self.expected_unchanged_uids, f"Row {uid} was modified but is not in UNCHANGED-RANGE")
                self.assertNotIn(uid, quarantine_uids, f"Quarantine row {uid} was modified!")
                self.assertNotIn(uid, changed_range_uids, f"Changed-range row {uid} was modified!")

                # Verify only column 8 (zig_sha256) is modified
                self.assertEqual(orig_parsed[:8], patched_parsed[:8])
                self.assertEqual(orig_parsed[9:], patched_parsed[9:])
                self.assertNotEqual(orig_parsed[8], patched_parsed[8])

                # Verify new hash matches disk
                zig_path = orig_parsed[5].strip()
                expected_sha = compute_file_sha256(self.root / zig_path)
                self.assertEqual(patched_parsed[8].strip(), expected_sha)
            else:
                self.assertNotIn(uid, self.expected_unchanged_uids, f"Refresh row {uid} was not modified!")

        self.assertEqual(len(modified_uids), 7)
        self.assertEqual(modified_uids, self.expected_unchanged_uids)

        # Verify CRLF line endings throughout
        for line in patched_lines:
            self.assertTrue(line.endswith("\r\n"), f"Line did not end with CRLF: {line[:50]}")

        # Verify diff stats
        report = result["audit_report"]
        self.assertEqual(report["summary"]["diff_removals"], 7)
        self.assertEqual(report["summary"]["diff_additions"], 7)
        self.assertEqual(report["summary"]["patched_rows_count"], 7)
        self.assertEqual(report["summary"]["unmodified_rows_count"], 366)
        self.assertEqual(report["exclusions"]["quarantine_rows_excluded"], 64)
        self.assertEqual(report["exclusions"]["changed_range_rows_excluded"], 62)

    def test_git_apply_check_clean(self):
        """Generated unified diff must pass git apply --check cleanly."""
        result = generate_traceability_patch(self.root, self.csv_path, self.disposition_path)
        with tempfile.TemporaryDirectory() as tmpdir:
            patch_file = Path(tmpdir) / "test.patch"
            patch_file.write_text(result["patch_diff"], encoding="utf-8")
            proc = subprocess.run(
                ["git", "apply", "--check", str(patch_file)],
                cwd=str(self.root),
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, f"git apply --check failed: {proc.stderr}")

    def test_tracecov_integration_on_staged_csv(self):
        """Running tracecov collect against the patched CSV must eliminate exactly the 7 refreshed stale problems."""
        from tracecov import collect

        result = generate_traceability_patch(self.root, self.csv_path, self.disposition_path)

        with tempfile.TemporaryDirectory() as tmpdir:
            staged_csv = Path(tmpdir) / "traceability.csv"
            staged_csv.write_text(result["patched_content"], encoding="utf-8", newline="")

            index_path = self.root / "audit" / "manifest" / "f77index.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))

            cov_data = collect(self.root, index, staged_csv, 20)

            stale_problems = [p for p in cov_data.get("problems", []) if p["kind"] == "stale-zig-sha256"]
            # Originally 133 stale problems; 7 refreshed => exactly 126 remain
            self.assertEqual(len(stale_problems), 126)

            remaining_stale_uids = set(p["unit_id"] for p in stale_problems)

            # Assert zero refreshed rows remain stale
            self.assertEqual(remaining_stale_uids & self.expected_unchanged_uids, set())


if __name__ == "__main__":
    unittest.main()
