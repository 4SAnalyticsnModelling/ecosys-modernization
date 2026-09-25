# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Recorded Herdr 0.9.1 agent_info shape; identities replaced with test values.

Source: saved Claude CLI results from 2026-09-23, NOT a live server query.
No model requests, real Herdr calls or process control in these tests.
"""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import herdr_cycle as cycle
import workflow as w


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.clock = 0.0
        self.client = cycle.Herdr(self.root, "fixture", timeout=40,
                                 clock=lambda: self.clock, sleep=self.advance)
        self.output = io.StringIO()
        for role in ("editor", "reviewer"):
            w.atomic(w.runtime(self.root) / f"{role}.json", w.encoded({
                "role": role, "pane_id": f"fixture:{role}", "session_id": f"{role}-session",
                "activity": "idle", "updated": 0,
            }))
        # This is the actual response field spelling, NOT the old mock's `state`.
        self.info = {"id": "cli:agent:get", "result": {"type": "agent_info", "agent": {
            "agent": "claude", "name": "editor", "pane_id": "fixture:editor",
            "agent_status": "idle", "cwd": str(self.root),
            "agent_session": {"agent": "claude", "kind": "id", "source": "herdr:claude", "value": "editor-session"},
            "revision": 14, "state_change_seq": 15,
        }}}

    def advance(self, seconds):
        self.clock += seconds

    def idle(self, role="editor", info=None):
        with patch.object(self.client, "call", return_value=info or self.info), contextlib.redirect_stdout(self.output):
            return self.client.idle(role)

    def test_recorded_agent_status_idle_is_ready(self):
        self.assertTrue(self.idle())

    def test_done_is_also_ready(self):
        self.info["result"]["agent"]["agent_status"] = "done"
        self.assertTrue(self.idle())

    def test_working_is_not_ready_and_wait_reason_is_persisted(self):
        self.info["result"]["agent"]["agent_status"] = "working"
        self.assertFalse(self.idle())
        status = w.load(w.runtime(self.root) / "controller-status.json")
        self.assertEqual(status["status"], "WAITING")
        self.assertEqual(status["agent_status"], "working")
        self.assertEqual(status["registered_activity"], "idle")

    def test_native_working_registration_still_blocks_dispatch(self):
        p = w.runtime(self.root) / "editor.json"
        w.atomic(p, w.encoded({**w.load(p), "activity": "working"}))
        self.assertFalse(self.idle())

    def test_blocked_dialog_never_becomes_ready(self):
        self.info["result"]["agent"]["agent_status"] = "blocked"
        with self.assertRaisesRegex(w.ProtocolError, "permission/question"):
            self.idle()

    def test_missing_agent_status_is_an_error_not_an_hour_of_silent_polling(self):
        del self.info["result"]["agent"]["agent_status"]
        self.info["result"]["agent"]["state"] = "idle"
        with self.assertRaisesRegex(w.ProtocolError, "agent_status"):
            self.idle()

    def test_unsupported_status_and_envelope_fail_closed(self):
        self.info["result"]["agent"]["agent_status"] = "ready-ish"
        with self.assertRaisesRegex(w.ProtocolError, "agent_status"):
            self.idle()
        with self.assertRaisesRegex(w.ProtocolError, "envelope"):
            self.idle(info={"result": {"agents": []}})

    def test_incidental_nested_state_does_not_override_actual_agent_status(self):
        self.info["debug"] = {"state": "working"}
        self.assertTrue(self.idle())

    def test_wrong_named_pane_rejected(self):
        for field, bad in (("pane_id", "another:p1"), ("name", "someone-else")):
            with self.subTest(field=field):
                info = copy.deepcopy(self.info)
                info["result"]["agent"][field] = bad
                with self.assertRaisesRegex(w.ProtocolError, "live named pane"):
                    self.idle(info=info)

    def test_stale_native_session_rejected(self):
        self.info["result"]["agent"]["agent_session"]["value"] = "replacement-session"
        with self.assertRaisesRegex(w.ProtocolError, "native session"):
            self.idle()

    def test_wrong_harness_or_project_rejected(self):
        info = copy.deepcopy(self.info)
        info["result"]["agent"]["agent"] = "pi"
        with self.assertRaisesRegex(w.ProtocolError, "expected claude"):
            self.idle(info=info)
        info = copy.deepcopy(self.info)
        info["result"]["agent"]["cwd"] = str(self.root / "different")
        with self.assertRaisesRegex(w.ProtocolError, "project directory"):
            self.idle(info=info)

    def reviewer_info(self):
        info = copy.deepcopy(self.info)
        info["result"]["agent"].update({"agent": "pi", "name": "reviewer", "pane_id": "fixture:reviewer",
            "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi",
                "value": "C:/Users/test/.pi/agent/sessions/project/2026-09-23T17-39-16-291Z_reviewer-session.jsonl"}})
        return info

    def test_pi_path_session_reference_is_verified(self):
        self.assertTrue(self.idle("reviewer", self.reviewer_info()))
        info = self.reviewer_info()
        info["result"]["agent"]["agent_session"]["value"] = "C:/tmp/someone-else.jsonl"
        with self.assertRaisesRegex(w.ProtocolError, "native session"):
            self.idle("reviewer", info)

    def test_unknown_state_gets_short_bounded_grace(self):
        self.info["result"]["agent"]["agent_status"] = "unknown"
        with patch.object(self.client, "call", return_value=self.info), contextlib.redirect_stdout(self.output):
            with self.assertRaisesRegex(w.ProtocolError, "unknown to Herdr"):
                self.client.wait_idle("editor")
        self.assertGreaterEqual(self.clock, 15)
        self.assertLess(self.clock, 20)

    def test_wait_diagnostics_do_not_print_on_every_poll(self):
        self.info["result"]["agent"]["agent_status"] = "working"
        for _ in range(20):
            self.idle()
            self.advance(2)
        self.assertEqual(len(self.output.getvalue().splitlines()), 1)
        self.assertEqual(w.load(w.runtime(self.root) / "controller-status.json")["agent_status"], "working")

    def test_actual_shape_reaches_first_dispatch_without_model_calls(self):
        calls = []
        def fake_call(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("agent", "get"):
                return self.info if args[2] == "editor" else self.reviewer_info()
            if args[:3] == ("agent", "prompt", "editor"):
                w.save_state(self.root, {"phase": "parked", "task": None, "reason": "fixture complete"})
                return {"result": {"type": "agent_prompt"}}
            raise AssertionError(args)
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:editor"}), \
                patch.object(self.client, "call", side_effect=fake_call), contextlib.redirect_stdout(self.output):
            result = cycle.controller(self.root, self.client)
        self.assertEqual(result["status"], "PARKED")
        self.assertEqual(sum(x[:2] == ("agent", "prompt") for x in calls), 1)
        self.assertEqual(w.load(w.runtime(self.root) / "dispatch.json")["status"], "settled")

    def test_lost_pane_name_falls_back_to_registered_pane_and_restores_name(self):
        calls = []
        listed = copy.deepcopy(self.info["result"]["agent"])
        del listed["name"]
        def fake_call(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("agent", "get"):
                raise w.ProtocolError('Herdr exit 1:  {"error":{"code":"agent_not_found"}}')
            if args[:2] == ("agent", "list"):
                return {"result": {"agents": [listed]}}
            if args[:2] == ("agent", "rename"):
                return {"result": {}}
            raise AssertionError(args)
        with patch.object(self.client, "call", side_effect=fake_call), contextlib.redirect_stdout(self.output):
            self.assertTrue(self.client.idle("editor"))
        self.assertIn(("agent", "rename", "fixture:editor", "editor"), calls)

    def review_fixture(self):
        w.save_state(self.root, {"phase": "review", "task": "t1", "revision": 1,
                                 "packet": "audit/tasks/t1/packet-1.json", "packet_sha256": "p" * 64})
        return self.root / "audit/reviews/t1-r1.json"

    def peer(self, fake_call, wait=60):
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:editor"}), \
                patch.object(self.client, "call", side_effect=fake_call), \
                patch.object(cycle, "consume_review", return_value={"phase": "finalizing"}):
            return cycle.lead_peer(self.root, self.client, wait)

    def test_lead_peer_dispatches_once_and_returns_small_verdict(self):
        receipt = self.review_fixture()
        prompts = []
        def fake_call(*args, **kwargs):
            if args[:2] == ("agent", "get"):
                return self.reviewer_info()
            if args[:2] == ("agent", "prompt"):
                prompts.append(args)
                return {"result": {}}
            raise AssertionError(args)
        # First call: Pi never answers inside the wait -> PENDING, one prompt.
        self.assertEqual(self.peer(fake_call)["status"], "PENDING")
        # Second call: the receipt arrives; the packet is NOT sent again.
        w.atomic(receipt, w.encoded({"verdict": "PASS", "findings": []}))
        result = self.peer(fake_call)
        self.assertEqual((result["status"], result["verdict"], result["phase"]), ("REVIEWED", "PASS", "finalizing"))
        self.assertEqual(len(prompts), 1)
        self.assertEqual(prompts[0][2], "fixture:reviewer")
        self.assertEqual(w.load(w.runtime(self.root) / "dispatch.json")["status"], "settled")

    def test_lead_peer_never_prompts_a_busy_or_blocked_reviewer(self):
        self.review_fixture()
        info = self.reviewer_info()
        def fake_call(*args, **kwargs):
            if args[:2] == ("agent", "get"):
                return info
            raise AssertionError(args)
        info["result"]["agent"]["agent_status"] = "working"
        self.assertEqual(self.peer(fake_call)["status"], "REVIEWER_BUSY")
        info["result"]["agent"]["agent_status"] = "blocked"
        with self.assertRaisesRegex(w.ProtocolError, "permission/question"):
            self.peer(fake_call)

    def test_lead_peer_reports_reviewer_that_yields_without_receipt(self):
        self.review_fixture()
        reg = w.runtime(self.root) / "reviewer.json"
        def fake_call(*args, **kwargs):
            if args[:2] == ("agent", "get"):
                return self.reviewer_info()
            if args[:2] == ("agent", "prompt"):
                w.atomic(reg, w.encoded({**w.load(reg), "activity": "idle", "updated": 1e12}))
                return {"result": {}}
            raise AssertionError(args)
        with self.assertRaisesRegex(w.ProtocolError, "without a receipt"):
            self.peer(fake_call, wait=300)
        self.assertEqual(w.load(w.runtime(self.root) / "dispatch.json")["status"], "ambiguous")


if __name__ == "__main__":
    unittest.main()
