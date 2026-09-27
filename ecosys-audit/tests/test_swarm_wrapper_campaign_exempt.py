# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Regression tests for detached campaign heartbeat/lock attribution (T-00175 / T-00163).

Verifies that:
1. When machine.lock is held by a live campaign with a fresh heartbeat, the campaign's
   heartbeat_path and sibling driver.log are excluded from changed_paths scope attribution,
   are not quarantined, are not restored to pre-turn content, and are not committed by agent turns.
2. When machine.lock is not held, or is stale (dead PID or heartbeat age > 600s),
   the campaign paths are NOT exempt, and writes by roles outside their lane are quarantined.
3. Both SENTINEL routing turns and SAGE review/decision turns (and CHAIN dispatch) proceed
   without interference from live detached campaign writes.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import swarm_wrapper as sw
import workflow as w
from test_swarm_wrapper import SwarmBase, FakeHerdr, TASK, RESULT


class SwarmCampaignExemptTests(SwarmBase):
    def _setup_machine_lock(self, pid: int, heartbeat_age_s: float = 0.0) -> tuple[Path, Path, Path]:
        lock_path = self.root / ".agent/locks/machine.lock"
        campaign_dir = self.root / "audit/runs/p04-full-campaign"
        campaign_dir.mkdir(parents=True, exist_ok=True)
        hb_path = campaign_dir / "heartbeat.json"
        driver_log = campaign_dir / "driver.log"

        now = time.time()
        hb_unix = now - heartbeat_age_s
        hb_data = {
            "pid": pid,
            "campaign_id": "p04-full-campaign",
            "run_index": 1,
            "status": "RUNNING",
            "elapsed_seconds": 120.0,
            "heartbeat_unix": hb_unix,
            "heartbeat_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(hb_unix)),
        }
        hb_path.write_text(json.dumps(hb_data), encoding="utf-8")
        driver_log.write_text(f"campaign started pid={pid}\n", encoding="utf-8")

        lock_record = {
            "pid": pid,
            "campaign_id": "p04-full-campaign",
            "heartbeat_path": str(hb_path),
            "acquired_at": now - 300.0,
            "last_heartbeat": hb_unix,
        }
        lock_path.write_bytes(b"0\n" + json.dumps(lock_record, indent=2).encode("utf-8") + b"\n")
        return lock_path, hb_path, driver_log

    def test_campaign_exempt_paths_unit_states(self):
        """Unit checks for Swarm.campaign_exempt_paths() under all lock states."""
        # 1. No lock file
        lock_path = self.root / ".agent/locks/machine.lock"
        lock_path.unlink(missing_ok=True)
        self.assertEqual(self.swarm.campaign_exempt_paths(), set())

        # 2. Unowned lock (reclaimable)
        lock_path.write_bytes(b"0\n")
        self.assertEqual(self.swarm.campaign_exempt_paths(), set())

        # 3. Dead PID lock (reclaimable)
        self._setup_machine_lock(pid=99999999, heartbeat_age_s=5.0)
        self.assertEqual(self.swarm.campaign_exempt_paths(), set())

        # 4. Stale heartbeat (>600s, reclaimable)
        self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=700.0)
        self.assertEqual(self.swarm.campaign_exempt_paths(), set())

        # 5. Live lock with fresh heartbeat (never stolen, exempt)
        _, hb_path, log_path = self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=5.0)
        exempt = self.swarm.campaign_exempt_paths()
        expected = {
            hb_path.relative_to(self.root).as_posix(),
            log_path.relative_to(self.root).as_posix(),
        }
        self.assertEqual(exempt, expected)

    def test_sentinel_brief_reports_measured_campaign_liveness(self):
        """2026-09-27: SENTINEL idled 17 h on a prose claim that a dead driver was alive."""
        self._setup_machine_lock(pid=99999999, heartbeat_age_s=5.0)
        brief = self.swarm.sentinel_brief()
        self.assertIn("Detached campaign liveness", brief)
        self.assertIn("reason=DEAD_PID", brief)
        self.assertIn("driver is DEAD", brief)
        self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=5.0)
        brief = self.swarm.sentinel_brief()
        self.assertIn("campaign is live and healthy", brief)
        (self.root / ".agent/locks/machine.lock").unlink()
        self.assertNotIn("Detached campaign liveness", self.swarm.sentinel_brief())

    def test_sentinel_idle_rejected_while_lock_holder_is_dead(self):
        """2026-09-27: SENTINEL wrote 'campaign live and healthy' IDLE over a measured DEAD_PID."""
        self._setup_machine_lock(pid=99999999, heartbeat_age_s=5.0)
        self.sentinel_queue([{"status": "IDLE", "reason": "no unblocked work: campaign live and healthy"}])
        out = self.swarm.step()
        self.assertNotEqual(out.get("status"), "IDLE")
        self.assertNotEqual(out.get("status"), "ESCALATED")
        errs = self.swarm.workflow().get("last_route_errors") or []
        self.assertTrue(any("contradicts the measured campaign state" in e for e in errs), errs)

    def test_sentinel_idle_accepted_while_campaign_live(self):
        self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=5.0)
        self.sentinel_queue([{"status": "IDLE", "reason": "no unblocked work: campaign live"}])
        out = self.swarm.step()
        self.assertEqual(out.get("status"), "ESCALATED")  # normal idle-check path to SAGE

    def test_sentinel_routing_not_blocked_by_live_campaign_heartbeat(self):
        """Live detached campaign writes must not cause SENTINEL routing turn to fail or quarantine."""
        _, hb_path, log_path = self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=2.0)
        # Commit initial tracked files
        self.git("add", "audit/runs/p04-full-campaign/heartbeat.json", "audit/runs/p04-full-campaign/driver.log")
        self.git("commit", "-m", "track campaign initial")

        # SENTINEL queues a task for PATHFINDER
        self.sentinel_queue([
            {"status": "PENDING", "task_id": "T-00001", "role": "PATHFINDER", "skills": ["ecosys-source-navigation"]},
        ])

        # Simulate background campaign modifying heartbeat and log during SENTINEL turn
        prev_sentinel = self.herdr.behaviors.get("sentinel")

        def concurrent_campaign_write(text):
            if prev_sentinel:
                prev_sentinel(text)
            # Live campaign updates heartbeat timestamp and appends to log
            now = time.time()
            hb_data = json.loads(hb_path.read_text(encoding="utf-8"))
            hb_data["heartbeat_unix"] = now
            hb_data["elapsed_seconds"] = 150.0
            hb_path.write_text(json.dumps(hb_data), encoding="utf-8")
            with log_path.open("a", encoding="utf-8") as f:
                f.write("step 150 elapsed\n")

        self.herdr.behaviors["sentinel"] = concurrent_campaign_write

        out = self.swarm.step()
        self.assertEqual(out.get("status"), "ROUTED")
        self.assertEqual(out.get("task_id"), "T-00001")
        self.assertEqual(out.get("role"), "PATHFINDER")

        # No quarantine created
        q_dirs = list((self.root / ".agent/failures").glob("Q-route-*"))
        self.assertEqual(q_dirs, [])

        # Heartbeat file was NOT restored to old content
        hb_after = json.loads(hb_path.read_text(encoding="utf-8"))
        self.assertEqual(hb_after["elapsed_seconds"], 150.0)

        # Commit did NOT include heartbeat or driver.log
        commit_paths = (self.root / ".agent/runtime/commit-paths.txt").read_text() if (self.root / ".agent/runtime/commit-paths.txt").exists() else ""
        self.assertNotIn("heartbeat.json", commit_paths)
        self.assertNotIn("driver.log", commit_paths)

    def test_sentinel_routing_quarantined_when_lock_is_stale(self):
        """When lock is stale (dead PID), heartbeat writes outside lane must be quarantined as usual."""
        _, hb_path, _ = self._setup_machine_lock(pid=99999999, heartbeat_age_s=5.0)
        self.git("add", "audit/runs/p04-full-campaign/heartbeat.json", "audit/runs/p04-full-campaign/driver.log")
        self.git("commit", "-m", "track campaign initial")

        self.sentinel_queue([
            {"status": "PENDING", "task_id": "T-00001", "role": "PATHFINDER", "skills": ["ecosys-source-navigation"]},
        ])

        prev_sentinel = self.herdr.behaviors.get("sentinel")

        def sentinel_with_bad_write(text):
            if prev_sentinel:
                prev_sentinel(text)
            hb_data = json.loads(hb_path.read_text(encoding="utf-8"))
            hb_data["heartbeat_unix"] = time.time()
            hb_data["elapsed_seconds"] = 999.0
            hb_path.write_text(json.dumps(hb_data), encoding="utf-8")

        self.herdr.behaviors["sentinel"] = sentinel_with_bad_write

        out = self.swarm.step()
        # Route should be rejected/invalid due to out-of-lane write
        self.assertEqual(out.get("status"), "ROUTE_INVALID")
        q_dirs = list((self.root / ".agent/failures").glob("Q-route-*"))
        self.assertEqual(len(q_dirs), 1)

        # Heartbeat was restored to pre-turn content
        hb_after = json.loads(hb_path.read_text(encoding="utf-8"))
        self.assertEqual(hb_after["elapsed_seconds"], 120.0)

    def test_sage_turn_and_chain_not_blocked_by_live_campaign_heartbeat(self):
        """During SAGE turn, live detached campaign writes do not cause SAGE to fail, and CHAIN is dispatched."""
        _, hb_path, log_path = self._setup_machine_lock(pid=os.getpid(), heartbeat_age_s=2.0)
        self.git("add", "audit/runs/p04-full-campaign/heartbeat.json", "audit/runs/p04-full-campaign/driver.log")
        self.git("commit", "-m", "track campaign initial")

        # Set up a pending SAGE decision task
        tid = "T-00010"
        (self.root / f".agent/tasks/{tid}.md").write_text(
            TASK.format(tid=tid, role="SAGE", allowed="- `.agent/results/`")
        )
        w.atomic(self.root / ".agent/dispatch.json", w.encoded({
            "schema_version": 1, "status": "PENDING", "task_id": tid, "role": "SAGE",
            "task_file": f".agent/tasks/{tid}.md", "result_file": f".agent/results/{tid}.md",
            "skills": ["ecosys-process-science-parity"], "decision_of": "SENTINEL",
            "t1_argv": None, "requires_sage_review": False, "full_run_justification": None,
        }))

        # SAGE behavior: writes result with DECISION and a valid CHAIN block targeting FORGE
        def sage_act(_text):
            # Concurrent campaign write
            now = time.time()
            hb_data = json.loads(hb_path.read_text(encoding="utf-8"))
            hb_data["heartbeat_unix"] = now
            hb_data["elapsed_seconds"] = 180.0
            hb_path.write_text(json.dumps(hb_data), encoding="utf-8")

            result_content = (
                f"# TASK: {tid}\n\n## STATUS\nDONE\n\n## FINDING\nDECISION: proceed with fix.\n\n"
                f"## EVIDENCE\nnone\n\n## FILES INSPECTED OR CHANGED\nnone\n\n## TESTS\nnone\n\n"
                f"## SCIENTIFIC IMPACT\nNone\n\n## UNCERTAINTY\nnone\n\n## RECOMMENDED NEXT ACTION\nnone\n\n"
                f"## CHAIN\nROLE: FORGE\nOBJECTIVE: Test follow-up\nALLOWED: ecosys-audit/scripts/swarm_wrapper.py\nSKILLS: none\n"
            )
            (self.root / f".agent/results/{tid}.md").write_text(result_content, encoding="utf-8")

        self.herdr.behaviors["sage"] = sage_act

        out = self.swarm.step()
        self.assertEqual(out.get("status"), "COLLECTED")
        self.assertEqual(out.get("result_status"), "DONE")
        self.assertTrue(out.get("chained"), "SAGE CHAIN was not dispatched")
        self.assertEqual(out.get("chained"), "T-00011")

        # Verify no quarantine
        q_dirs = list((self.root / ".agent/failures").glob("Q-*"))
        self.assertEqual(q_dirs, [])

        # Heartbeat was NOT reverted
        hb_after = json.loads(hb_path.read_text(encoding="utf-8"))
        self.assertEqual(hb_after["elapsed_seconds"], 180.0)


if __name__ == "__main__":
    unittest.main()
