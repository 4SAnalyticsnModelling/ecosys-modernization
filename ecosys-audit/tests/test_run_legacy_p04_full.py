import json
from pathlib import Path
import tempfile
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from run_legacy_p04_full import (
    RUN_002_EXPECTED_FILES,
    RUN_002_EXPECTED_BYTES_APPROX,
    compare_determinism,
    check_horizon_completion,
    get_process_affinity,
    set_process_affinity,
    sha256_file
)
from workflow import ProtocolError


class TestRunLegacyP04Full(unittest.TestCase):
    def test_run_002_inventory_constants(self):
        self.assertEqual(RUN_002_EXPECTED_FILES, 1138)
        self.assertEqual(RUN_002_EXPECTED_BYTES_APPROX, 1428000000)

    def test_determinism_comparison_matching(self):
        runs = [
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "BBB"}}},
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "BBB"}}},
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "BBB"}}}
        ]
        res = compare_determinism(runs)
        self.assertTrue(res["byte_for_byte_identical"])
        self.assertEqual(res["total_files_compared"], 2)
        self.assertEqual(res["discrepancies_count"], 0)

    def test_determinism_comparison_mismatch(self):
        runs = [
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "BBB"}}},
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "CCC"}}}
        ]
        res = compare_determinism(runs)
        self.assertFalse(res["byte_for_byte_identical"])
        self.assertEqual(res["discrepancies_count"], 1)

    def test_horizon_check_bounded(self):
        res = check_horizon_completion(Path("."), Path("."), {}, max_simulated_days=5)
        self.assertTrue(res["verified"])
        self.assertEqual(res["simulated_days_target"], 5)

    def test_horizon_check_full_30_year(self):
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            log_file = tdp / "log98f25"
            log_file.write_text("NOW EXECUTING DAY 365 OF YEAR 2027\nIEEE_UNDERFLOW_FLAG\n", encoding="latin-1")
            
            sample_file = tdp / "12027f25cd1"
            sample_file.write_text("364 123.45\n365 234.56\n", encoding="latin-1")
            
            output_files = {
                "12027f25cd1": {"size_bytes": 100, "sha256": "X", "lines": 2}
            }
            res = check_horizon_completion(tdp, log_file, output_files, max_simulated_days=None)
            self.assertTrue(res["verified"])
            self.assertTrue(res["has_year_2027_outputs"])
            self.assertEqual(res["last_doy_detected"], 365)


if __name__ == "__main__":
    unittest.main()
