import json
import os
from pathlib import Path
import tempfile
import time
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from run_legacy_p04_full import (
    RUN_002_EXPECTED_FILES,
    RUN_002_EXPECTED_BYTES_APPROX,
    MAX_HEARTBEAT_STALE_SECONDS,
    compare_determinism,
    check_horizon_completion,
    get_process_affinity,
    set_process_affinity,
    sha256_file,
    is_pid_alive,
    get_system_load,
    read_lock_info,
    inspect_lock_status,
    HeartbeatDaemon,
    MachineLock,
    spawn_detached_child
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

    def test_determinism_comparison_single_run(self):
        runs = [
            {"outputs": {"f1.txt": {"sha256": "AAA"}, "f2.txt": {"sha256": "BBB"}}}
        ]
        res = compare_determinism(runs)
        self.assertTrue(res["byte_for_byte_identical"])
        self.assertTrue(res["deterministic"])
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

    def test_is_pid_alive_self_and_dead(self):
        self.assertTrue(is_pid_alive(os.getpid()))
        self.assertFalse(is_pid_alive(99999999))
        self.assertFalse(is_pid_alive(0))
        self.assertFalse(is_pid_alive(-1))

    def test_system_load_structure(self):
        load = get_system_load()
        self.assertIn("timestamp", load)
        self.assertIn("timestamp_utc", load)
        if os.name == "nt":
            self.assertIn("memory_load_percent", load)
            self.assertIn("total_phys_mb", load)
            self.assertIn("avail_phys_mb", load)
            self.assertIn("cpu_times_raw", load)

    def test_lock_status_no_lock(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "machine.lock"
            status = inspect_lock_status(p)
            self.assertFalse(status["locked"])
            self.assertTrue(status["reclaimable"])
            self.assertEqual(status["reason"], "NO_LOCK")

    def test_lock_status_unowned_legacy_lock(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "machine.lock"
            p.write_bytes(b"0\n")
            status = inspect_lock_status(p)
            self.assertTrue(status["locked"])
            self.assertTrue(status["reclaimable"])
            self.assertEqual(status["reason"], "UNOWNED_LOCK")

    def test_stale_lock_recovery_dead_pid(self):
        """T-00150 C3: Dead PID in lock file is reclaimable."""
        with tempfile.TemporaryDirectory() as td:
            lock_p = Path(td) / "machine.lock"
            hb_p = Path(td) / "heartbeat.json"
            dead_record = {
                "pid": 99999999,
                "campaign_id": "test-dead-pid",
                "heartbeat_path": str(hb_p),
                "acquired_at": time.time(),
                "last_heartbeat": time.time()
            }
            lock_p.write_bytes(b"0\n" + json.dumps(dead_record).encode("utf-8") + b"\n")

            status = inspect_lock_status(lock_p, hb_p)
            self.assertTrue(status["locked"])
            self.assertTrue(status["reclaimable"])
            self.assertEqual(status["reason"], "DEAD_PID")
            self.assertEqual(status["pid"], 99999999)

            # Reclaim the lock using MachineLock
            mlock = MachineLock(lock_p, hb_p, "campaign-reclaim-dead")
            with mlock:
                info = read_lock_info(lock_p)
                self.assertIsNotNone(info)
                self.assertEqual(info["pid"], os.getpid())
                self.assertEqual(info["campaign_id"], "campaign-reclaim-dead")

            # Verify lock released
            after_info = read_lock_info(lock_p)
            self.assertIsNone(after_info)
            self.assertEqual(lock_p.read_bytes().strip(), b"0")

    def test_stale_lock_recovery_stale_heartbeat(self):
        """T-00150 C3: Heartbeat older than 10 minutes (600s) is reclaimable."""
        with tempfile.TemporaryDirectory() as td:
            lock_p = Path(td) / "machine.lock"
            hb_p = Path(td) / "heartbeat.json"

            # Create heartbeat older than 10 min
            stale_time = time.time() - 720.0  # 12 minutes old
            hb_data = {
                "pid": os.getpid(),
                "campaign_id": "test-stale-hb",
                "status": "RUN_1",
                "heartbeat_unix": stale_time,
                "heartbeat_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stale_time))
            }
            hb_p.write_text(json.dumps(hb_data), encoding="utf-8")

            lock_record = {
                "pid": os.getpid(),
                "campaign_id": "test-stale-hb",
                "heartbeat_path": str(hb_p),
                "acquired_at": stale_time,
                "last_heartbeat": stale_time
            }
            lock_p.write_bytes(b"0\n" + json.dumps(lock_record).encode("utf-8") + b"\n")

            status = inspect_lock_status(lock_p, hb_p, max_heartbeat_age=MAX_HEARTBEAT_STALE_SECONDS)
            self.assertTrue(status["locked"])
            self.assertTrue(status["reclaimable"])
            self.assertEqual(status["reason"], "STALE_HEARTBEAT")
            self.assertGreater(status["heartbeat_age"], 600.0)

            # Reclaim the lock using MachineLock
            mlock = MachineLock(lock_p, hb_p, "campaign-reclaim-stale", max_heartbeat_age=MAX_HEARTBEAT_STALE_SECONDS)
            with mlock:
                info = read_lock_info(lock_p)
                self.assertIsNotNone(info)
                self.assertEqual(info["pid"], os.getpid())
                self.assertEqual(info["campaign_id"], "campaign-reclaim-stale")

    def test_live_lock_never_stolen(self):
        """T-00150 C3: A live lock (live PID + fresh heartbeat <= 600s) is NEVER stolen."""
        with tempfile.TemporaryDirectory() as td:
            lock_p = Path(td) / "machine.lock"
            hb_p = Path(td) / "heartbeat.json"

            # Fresh heartbeat (5 seconds ago)
            fresh_time = time.time() - 5.0
            hb_data = {
                "pid": os.getpid(),
                "campaign_id": "test-live-lock",
                "status": "RUN_1",
                "heartbeat_unix": fresh_time,
                "heartbeat_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(fresh_time))
            }
            hb_p.write_text(json.dumps(hb_data), encoding="utf-8")

            lock_record = {
                "pid": os.getpid(),
                "campaign_id": "test-live-lock",
                "heartbeat_path": str(hb_p),
                "acquired_at": fresh_time,
                "last_heartbeat": fresh_time
            }
            lock_p.write_bytes(b"0\n" + json.dumps(lock_record).encode("utf-8") + b"\n")

            status = inspect_lock_status(lock_p, hb_p, max_heartbeat_age=MAX_HEARTBEAT_STALE_SECONDS)
            self.assertTrue(status["locked"])
            self.assertFalse(status["reclaimable"])
            self.assertEqual(status["reason"], "LIVE_LOCK")
            self.assertLessEqual(status["heartbeat_age"], 10.0)

            # Attempting to acquire must raise ProtocolError
            mlock = MachineLock(lock_p, hb_p, "campaign-thief", max_heartbeat_age=MAX_HEARTBEAT_STALE_SECONDS)
            with self.assertRaises(ProtocolError):
                mlock.acquire()

    def test_heartbeat_daemon_lifecycle(self):
        """T-00150 C2: Heartbeat writes structured JSON with PID and system load."""
        with tempfile.TemporaryDirectory() as td:
            hb_p = Path(td) / "heartbeat.json"
            daemon = HeartbeatDaemon(hb_p, "campaign-hb-test", interval=0.1)
            daemon.start()
            try:
                time.sleep(0.2)
                self.assertTrue(hb_p.exists())
                data = json.loads(hb_p.read_text(encoding="utf-8"))
                self.assertEqual(data["pid"], os.getpid())
                self.assertEqual(data["campaign_id"], "campaign-hb-test")
                self.assertEqual(data["status"], "INITIALIZING")
                self.assertIn("system_load", data)

                daemon.set_status("WARMUP_1", current_run=1, total_runs=3)
                data2 = json.loads(hb_p.read_text(encoding="utf-8"))
                self.assertEqual(data2["status"], "WARMUP_1")
                self.assertEqual(data2["current_run"], 1)
                self.assertEqual(data2["total_runs"], 3)
            finally:
                daemon.stop(final_status="COMPLETED")

            data_final = json.loads(hb_p.read_text(encoding="utf-8"))
            self.assertEqual(data_final["status"], "COMPLETED")

    def test_detached_spawn_mock_child(self):
        """T-00150 C1: Detached child spawn launches and returns valid process."""
        with tempfile.TemporaryDirectory() as td:
            log_p = Path(td) / "child.log"
            cmd = [
                sys.executable,
                "-u",
                "-c",
                "import time, sys; sys.stdout.write('CHILD_RUNNING\\n'); sys.stdout.flush(); time.sleep(2)"
            ]
            p = spawn_detached_child(cmd, log_p)
            try:
                self.assertGreater(p.pid, 0)
                self.assertTrue(is_pid_alive(p.pid))
                deadline = time.time() + 5.0
                found = False
                while time.time() < deadline:
                    if log_p.exists():
                        try:
                            text = log_p.read_text(encoding="utf-8", errors="replace")
                            if "CHILD_RUNNING" in text:
                                found = True
                                break
                        except PermissionError:
                            pass
                    time.sleep(0.1)
                self.assertTrue(found, "Mock detached child output not detected in log")
            finally:
                if is_pid_alive(p.pid):
                    from run_legacy_p04_full import stop_process_by_pid
                    stop_process_by_pid(p.pid)
                try:
                    p.wait(timeout=3)
                except Exception:
                    pass


if __name__ == "__main__":
    unittest.main()
