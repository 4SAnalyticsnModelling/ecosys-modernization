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
    spawn_detached_child,
    quarantine_path,
    quarantine_campaign_artifacts,
    stage_run_directory,
    validate_terminal_receipt,
    relaunch_campaign,
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

    def test_quarantine_path_file(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "driver.log"
            p.write_text("sample log content", encoding="utf-8")
            q_dest = quarantine_path(p)
            self.assertFalse(p.exists())
            self.assertIsNotNone(q_dest)
            self.assertTrue(q_dest.exists())
            self.assertIn("_quarantine_", q_dest.name)
            self.assertEqual(q_dest.read_text(encoding="utf-8"), "sample log content")

    def test_quarantine_path_directory(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td) / "run_1"
            d.mkdir()
            (d / "output.txt").write_text("data 123", encoding="utf-8")
            q_dest = quarantine_path(d)
            self.assertFalse(d.exists())
            self.assertIsNotNone(q_dest)
            self.assertTrue(q_dest.is_dir())
            self.assertIn("run_1_quarantine_", q_dest.name)
            self.assertEqual((q_dest / "output.txt").read_text(encoding="utf-8"), "data 123")

    def test_quarantine_campaign_artifacts(self):
        with tempfile.TemporaryDirectory() as td:
            c_dir = Path(td) / "campaign"
            c_dir.mkdir()
            r1 = c_dir / "run_1"
            r1.mkdir()
            (r1 / "file1.txt").write_text("r1", encoding="utf-8")
            r2 = c_dir / "run_2"
            r2.mkdir()
            (r2 / "file2.txt").write_text("r2", encoding="utf-8")
            w1 = c_dir / "warmup_1"
            w1.mkdir()
            d_log = c_dir / "driver.log"
            d_log.write_text("log", encoding="utf-8")
            rec = Path(td) / "receipt.json"
            rec.write_text("{}", encoding="utf-8")

            quarantined = quarantine_campaign_artifacts(c_dir, receipt_path=rec, driver_log=d_log)
            self.assertFalse(r1.exists())
            self.assertFalse(r2.exists())
            self.assertFalse(w1.exists())
            self.assertFalse(d_log.exists())
            self.assertFalse(rec.exists())
            self.assertEqual(len(quarantined), 5)
            for orig, q in quarantined.items():
                self.assertTrue(Path(q).exists())

    def test_stage_run_directory_quarantine_existing(self):
        with tempfile.TemporaryDirectory() as td:
            deck = Path(td) / "staged_deck"
            deck.mkdir()
            (deck / "runottawa").write_text("cat << eor\ninput\neor\n", encoding="latin-1")
            (deck / "f1.dat").write_text("data", encoding="latin-1")
            exe = Path(td) / "oracle.exe"
            exe.write_bytes(b"dummy_exe")

            target = Path(td) / "run_1"
            target.mkdir()
            (target / "old_prior_run.txt").write_text("prior evidence", encoding="utf-8")

            stage_run_directory(deck, exe, target, quarantine_existing=True)
            self.assertTrue(target.exists())
            self.assertFalse((target / "old_prior_run.txt").exists())
            self.assertTrue((target / "ecosys_oracle.exe").exists())
            self.assertTrue((target / "runscript").exists())

            # Verify quarantine copy was saved
            q_dirs = [p for p in Path(td).iterdir() if "run_1_quarantine_" in p.name]
            self.assertEqual(len(q_dirs), 1)
            self.assertTrue((q_dirs[0] / "old_prior_run.txt").exists())

    def test_validate_terminal_receipt_missing(self):
        res = validate_terminal_receipt(Path("nonexistent/receipt.json"))
        self.assertFalse(res["valid"])
        self.assertEqual(res["status"], "MISSING")
        self.assertTrue(any("does not exist" in p for p in res["problems"]))

    def test_validate_terminal_receipt_malformed(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text("NOT_JSON", encoding="utf-8")
            res = validate_terminal_receipt(p)
            self.assertFalse(res["valid"])
            self.assertEqual(res["status"], "MALFORMED_JSON")

    def test_validate_terminal_receipt_stale_mtime(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({"status": "ALL_RUNS_COMPLETED", "runs": []}), encoding="utf-8")
            res = validate_terminal_receipt(p, min_mtime=time.time() + 100.0)
            self.assertFalse(res["valid"])
            self.assertTrue(any("predates minimum mtime threshold" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_stale_lock(self):
        with tempfile.TemporaryDirectory() as td:
            lock_p = Path(td) / "machine.lock"
            lock_record = {"acquired_at": time.time() + 50.0}
            lock_p.write_bytes(b"0\n" + json.dumps(lock_record).encode("utf-8") + b"\n")

            rec_p = Path(td) / "receipt.json"
            rec_p.write_text(json.dumps({"status": "ALL_RUNS_COMPLETED", "runs": []}), encoding="utf-8")

            res = validate_terminal_receipt(rec_p, lock_path=lock_p)
            self.assertFalse(res["valid"])
            self.assertTrue(any("predates lock acquisition" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_run_failed(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({
                "status": "RUN_FAILED",
                "error": "Run run_1 failed: exit_code=2",
                "runs": []
            }), encoding="utf-8")
            res = validate_terminal_receipt(p)
            self.assertFalse(res["valid"])
            self.assertEqual(res["status"], "RUN_FAILED")
            self.assertTrue(any("RUN_FAILED" in pr for pr in res["problems"]))
            self.assertTrue(any("exit_code=2" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({
                "status": "ALL_RUNS_COMPLETED",
                "runs_count": 3,
                "runs": [
                    {"run_id": "run_1", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                    {"run_id": "run_2", "status": "RUN_FAILED", "exit_code": 2, "horizon_check": {"verified": False}},
                    {"run_id": "run_3", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                ],
                "determinism_audit": {"byte_for_byte_identical": True},
                "inventory_audit": {"actual_output_files": 1138}
            }), encoding="utf-8")
            res = validate_terminal_receipt(p)
            self.assertFalse(res["valid"])
            self.assertTrue(any("Run 2 exit code is 2" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_unverified_horizon(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({
                "status": "ALL_RUNS_COMPLETED",
                "runs_count": 1,
                "runs": [
                    {"run_id": "run_1", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": False}},
                ],
                "determinism_audit": {"byte_for_byte_identical": True},
                "inventory_audit": {"actual_output_files": 1138}
            }), encoding="utf-8")
            res = validate_terminal_receipt(p, expected_runs=1)
            self.assertFalse(res["valid"])
            self.assertTrue(any("horizon check not verified" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_determinism_mismatch(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({
                "status": "ALL_RUNS_COMPLETED",
                "runs_count": 2,
                "runs": [
                    {"run_id": "run_1", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                    {"run_id": "run_2", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                ],
                "determinism_audit": {"byte_for_byte_identical": False, "discrepancies_count": 3},
                "inventory_audit": {"actual_output_files": 1138}
            }), encoding="utf-8")
            res = validate_terminal_receipt(p, expected_runs=2)
            self.assertFalse(res["valid"])
            self.assertTrue(any("not byte-for-byte identical" in pr for pr in res["problems"]))

    def test_validate_terminal_receipt_success(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "receipt.json"
            p.write_text(json.dumps({
                "status": "ALL_RUNS_COMPLETED",
                "runs_count": 3,
                "runs": [
                    {"run_id": "run_1", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                    {"run_id": "run_2", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                    {"run_id": "run_3", "status": "RUN_COMPLETED_SUCCESS", "exit_code": 0, "horizon_check": {"verified": True}},
                ],
                "determinism_audit": {"byte_for_byte_identical": True, "discrepancies_count": 0},
                "inventory_audit": {"actual_output_files": 1138}
            }), encoding="utf-8")
            res = validate_terminal_receipt(p, expected_runs=3)
            self.assertTrue(res["valid"])
            self.assertEqual(len(res["problems"]), 0)
            self.assertTrue(res["exit_code_zero_all_runs"])
            self.assertTrue(res["determinism_verified"])
            self.assertTrue(res["horizon_verified"])

    def test_relaunch_campaign_refuses_live_lock(self):
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            deck = tdp / "deck"
            deck.mkdir()
            (deck / "dummy.txt").write_text("d")
            exe = tdp / "dummy.exe"
            exe.write_bytes(b"exe")

            lock_p = tdp / "machine.lock"
            hb_p = tdp / "heartbeat.json"
            # Live lock (current PID with fresh heartbeat)
            hb_p.write_text(json.dumps({"pid": os.getpid(), "heartbeat_unix": time.time()}))
            lock_p.write_bytes(b"0\n" + json.dumps({"pid": os.getpid(), "heartbeat_path": str(hb_p), "last_heartbeat": time.time()}).encode("utf-8") + b"\n")

            with self.assertRaises(ProtocolError) as ctx:
                relaunch_campaign(
                    deck_src=deck,
                    exe_src=exe,
                    output_base=tdp / "evidence",
                    campaign_id="test-relaunch-live",
                    lock_path=lock_p,
                    heartbeat_path=hb_p,
                )
            self.assertIn("live lock cannot be stolen", str(ctx.exception))

    def test_relaunch_campaign_dry_run_quarantine(self):
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            deck = tdp / "deck"
            deck.mkdir()
            (deck / "f.txt").write_text("deck file")
            exe = tdp / "dummy.exe"
            exe.write_bytes(b"exe")

            out_base = tdp / "evidence"
            camp_dir = out_base / "test-camp"
            camp_dir.mkdir(parents=True)
            r1 = camp_dir / "run_1"
            r1.mkdir()
            (r1 / "partial_output.txt").write_text("partial")

            lock_p = tdp / "machine.lock"
            hb_p = tdp / "heartbeat.json"
            # Dead lock (reclaimable)
            lock_p.write_bytes(b"0\n" + json.dumps({"pid": 99999999, "heartbeat_path": str(hb_p), "last_heartbeat": 0.0}).encode("utf-8") + b"\n")

            rec_out = tdp / "receipt.json"
            rec_out.write_text(json.dumps({"status": "STALE"}), encoding="utf-8")
            log_p = tdp / "driver.log"
            log_p.write_text("old log", encoding="utf-8")

            res = relaunch_campaign(
                deck_src=deck,
                exe_src=exe,
                output_base=out_base,
                campaign_id="test-camp",
                lock_path=lock_p,
                heartbeat_path=hb_p,
                out_receipt=rec_out,
                campaign_log=log_p,
                dry_run=True,
            )
            self.assertEqual(res["status"], "RELAUNCH_DRY_RUN_PASSED")
            self.assertFalse(r1.exists())
            self.assertFalse(log_p.exists())
            self.assertIn(str(r1), res["quarantined_artifacts"])
            self.assertTrue(rec_out.exists())  # dry run receipt written

    def test_spawn_detached_child_unbuffered_logging(self):
        with tempfile.TemporaryDirectory() as td:
            log_p = Path(td) / "unbuf.log"
            # Child writes without explicit flush and sleeps
            cmd = [
                sys.executable,
                "-c",
                "import sys, time; sys.stdout.write('UNBUFFERED_TEST_LINE\\n'); time.sleep(2)"
            ]
            p = spawn_detached_child(cmd, log_p)
            try:
                deadline = time.time() + 5.0
                found = False
                while time.time() < deadline:
                    if log_p.exists():
                        try:
                            text = log_p.read_text(encoding="utf-8", errors="replace")
                            if "UNBUFFERED_TEST_LINE" in text:
                                found = True
                                break
                        except PermissionError:
                            pass
                    time.sleep(0.05)
                self.assertTrue(found, "Unbuffered child output was not flushed to log immediately")
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
