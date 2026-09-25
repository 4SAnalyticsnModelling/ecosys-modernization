# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Offline tests: temporary repositories and fake agents only; no paid model calls."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import workflow as w
import workflow_hook as hooks
import herdr_cycle as cycle
import run_logged


HANDOFF = b"# Current\n## Candidate\nfixture\n## Gates\nNOT_ASSESSED\n## Active work\nnone\n## Next action\nfixture\n## Recovery\nowned processes: none\n"


class RepoCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        for tree in ("f77src", "f77example", "ecosys-ng", "ecosys-ng-prod-examples"):
            (self.root / tree).mkdir()
        self.source = self.root / "ecosys-ng/a.zig"
        self.source.write_text("original")
        (self.root / "audit").mkdir()
        (self.root / "audit/handoff.md").write_bytes(HANDOFF)
        (self.root / "audit/evidence.md").write_text("actual test evidence fixture")
        subprocess.run(["git", "-c", "core.autocrlf=false", "-C", str(self.root), "add", "."], check=True)
        self.spec = {"issue": "issue-fixture", "question": "Check this conversion", "scope": ["ecosys-ng/a.zig"],
                     "done_condition": "focused test plus independent review", "stop_condition": "bounded hypotheses"}

    def begin(self):
        return w.begin(self.root, self.spec, "claude-session")

    def seal(self):
        return w.seal(self.root, {"summary": "One bounded result", "next_action": "Review it",
            "status": "READY_FOR_REVIEW", "open_processes": [], "evidence": ["audit/evidence.md"]}, "claude-session")

    def result(self, verdict="PASS"):
        return {"packet_sha256": w.state(self.root)["packet_sha256"], "verdict": verdict,
                "summary": "Independent source/evidence inspection", "findings": [] if verdict == "PASS" else ["F1: a.zig:1, conversion evidence"],
                "evidence": ["audit/reviews/independent.md", "audit/reviews/carry-forward.md"], "open_processes": []}

    def review(self, verdict="PASS"):
        (self.root / "audit/reviews").mkdir(exist_ok=True)
        (self.root / "audit/reviews/independent.md").write_text("independently inspected fixture")
        (self.root / "audit/reviews/carry-forward.md").write_text("No earlier pending assignments or owned processes")
        return w.review(self.root, self.result(verdict), "pi-session")

    def finalize(self):
        s = w.state(self.root)
        draft = self.root / "draft.md"
        draft.write_bytes(HANDOFF + f"\nTask {s['task']} review {s['last_review']}\n".encode())
        w.checkpoint(self.root, draft, w.digest((self.root / "audit/handoff.md").read_bytes()))
        return w.close(self.root, "claude-session")


class CheckpointTests(RepoCase):
    def test_archive_is_byte_identical_and_replacement_is_bounded(self):
        old = HANDOFF + b"\r\nold details\r\n"
        (self.root / "audit/handoff.md").write_bytes(old)
        draft = self.root / "draft.md"
        draft.write_bytes(HANDOFF)
        result = w.checkpoint(self.root, draft, w.digest(old))
        self.assertEqual((self.root / result["archived"]["path"]).read_bytes(), old)
        self.assertEqual((self.root / "audit/handoff.md").read_bytes(), HANDOFF)

    def test_publication_does_not_require_filesystem_hardlink_support(self):
        with patch.object(os, "link", side_effect=OSError("Incorrect function: no hard links")):
            p = self.root / "audit/new-evidence.json"
            w.immutable(p, b"complete evidence")
            self.assertEqual(p.read_bytes(), b"complete evidence")
            w.immutable(p, b"complete evidence")
            with self.assertRaises(w.ProtocolError):
                w.immutable(p, b"different")

    def test_stale_writer_does_not_replace_handoff(self):
        draft = self.root / "draft.md"
        draft.write_bytes(HANDOFF)
        with self.assertRaises(w.ProtocolError):
            w.checkpoint(self.root, draft, "0" * 64)
        self.assertEqual((self.root / "audit/handoff.md").read_bytes(), HANDOFF)

    def test_oversized_or_missing_fields_rejected(self):
        for data in (b"incomplete", HANDOFF + b"x" * 6500):
            with self.assertRaises(w.ProtocolError):
                w.check_handoff(data)

    def test_path_escape_rejected(self):
        with self.assertRaises(w.ProtocolError):
            w.inside(self.root, "../outside")

    def test_immutable_evidence_cannot_be_overwritten(self):
        p = self.root / "audit/immutable"
        w.immutable(p, b"one")
        w.immutable(p, b"one")
        with self.assertRaises(w.ProtocolError):
            w.immutable(p, b"two")


class ProtocolTests(RepoCase):
    def test_complete_task_does_not_approve_release(self):
        self.begin(); self.seal(); self.review()
        w.consume_review(self.root)
        receipt = self.finalize()
        self.assertEqual(receipt["verdict"], "PASS")
        self.assertEqual(receipt["release_status"], "NOT_ASSESSED")
        self.assertEqual(w.state(self.root)["phase"], "closed")

    def test_self_review_rejected(self):
        self.begin(); self.seal()
        with self.assertRaisesRegex(w.ProtocolError, "Independent"):
            w.review(self.root, self.result(), "claude-session")

    def test_author_identity_rejected(self):
        self.begin()
        with self.assertRaisesRegex(w.ProtocolError, "author"):
            w.seal(self.root, {}, "someone-else")

    def test_recovered_editor_adopts_without_losing_prior_authorship(self):
        self.begin()
        w.adopt(self.root, "new-claude-session", "Old session ended; dirty work reconciled; no owned processes")
        w.seal(self.root, {"summary": "recovered", "next_action": "review", "status": "READY_FOR_REVIEW",
               "open_processes": [], "evidence": ["audit/evidence.md"]}, "new-claude-session")
        with self.assertRaisesRegex(w.ProtocolError, "Independent"):
            w.review(self.root, self.result(), "claude-session")
        self.assertEqual(w.task_authors(self.root, w.state(self.root)["task"]), {"claude-session", "new-claude-session"})

    def test_reviewer_phase_cannot_be_adopted_by_editor(self):
        self.begin(); self.seal()
        with self.assertRaisesRegex(w.ProtocolError, "unfinished editor"):
            w.adopt(self.root, "new", "not permitted")

    def test_wrong_packet_digest_rejected(self):
        self.begin(); self.seal()
        r = self.result(); r["packet_sha256"] = "0" * 64
        with self.assertRaisesRegex(w.ProtocolError, "bound"):
            w.review(self.root, r, "pi-session")

    def test_unknown_result_fields_cannot_override_identity(self):
        self.begin(); self.seal()
        r = self.result(); r["reviewer_session"] = "claude-session"
        with self.assertRaisesRegex(w.ProtocolError, "Unexpected"):
            w.review(self.root, r, "pi-session")

    def test_changed_source_invalidates_review(self):
        self.begin(); self.seal()
        self.source.write_text("changed")
        with self.assertRaisesRegex(w.ProtocolError, "changed during review"):
            self.review()

    def test_new_source_outside_declared_scope_invalidates_review(self):
        self.begin(); self.seal()
        (self.root / "ecosys-ng/other.zig").write_text("new production path")
        with self.assertRaisesRegex(w.ProtocolError, "changed during review"):
            self.review()

    def test_deleted_tracked_source_invalidates_review(self):
        self.begin(); self.seal(); self.source.unlink()
        with self.assertRaisesRegex(w.ProtocolError, "changed during review"):
            self.review()

    def test_stale_raw_evidence_rejected(self):
        self.begin(); self.seal()
        (self.root / "audit/evidence.md").write_text("tampered")
        with self.assertRaisesRegex(w.ProtocolError, "Stale artifact"):
            self.review()

    def test_modified_packet_rejected(self):
        self.begin(); self.seal()
        path = self.root / w.state(self.root)["packet"]
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(w.ProtocolError, "Packet modified"):
            self.review()

    def test_pass_with_unresolved_findings_rejected(self):
        self.begin(); self.seal()
        r = self.result(); r["findings"] = ["still broken"]
        with self.assertRaisesRegex(w.ProtocolError, "unresolved"):
            w.review(self.root, r, "pi-session")

    def test_blocked_editor_cannot_become_pass(self):
        self.begin()
        w.seal(self.root, {"summary": "blocked", "next_action": "another issue", "status": "BLOCKED",
            "open_processes": [], "evidence": ["audit/evidence.md"]}, "claude-session")
        with self.assertRaisesRegex(w.ProtocolError, "blocked editor"):
            self.review()

    def test_running_receipt_cannot_seal(self):
        self.begin()
        path = self.root / "audit/runs/owned/receipt.json"
        w.atomic(path, w.encoded({"status": "RUNNING", "pid": 123}))
        with self.assertRaisesRegex(w.ProtocolError, "RUNNING"):
            w.seal(self.root, {"summary": "not finished", "next_action": "wait", "status": "READY_FOR_REVIEW",
                "open_processes": [], "evidence": ["audit/runs/owned/receipt.json"]}, "claude-session")

    def test_pending_process_cannot_seal(self):
        self.begin()
        with self.assertRaisesRegex(w.ProtocolError, "processes"):
            w.seal(self.root, {"summary": "working", "next_action": "wait", "open_processes": [123]}, "claude-session")

    def test_same_evidence_cannot_repeat_review(self):
        self.begin(); self.seal(); self.review("FAIL"); w.consume_review(self.root)
        self.assertEqual(w.state(self.root)["revision"], 2)
        with self.assertRaisesRegex(w.ProtocolError, "Unchanged"):
            self.seal()

    def test_renaming_evidence_does_not_bypass_duplicate_review_guard(self):
        self.begin(); self.seal(); self.review("FAIL"); w.consume_review(self.root)
        (self.root / "audit/alias.md").write_bytes((self.root / "audit/evidence.md").read_bytes())
        with self.assertRaisesRegex(w.ProtocolError, "renaming/copying"):
            w.seal(self.root, {"summary": "same thing", "next_action": "review", "status": "READY_FOR_REVIEW",
                "open_processes": [], "evidence": ["audit/alias.md"]}, "claude-session")

    def test_two_failed_reviews_finalize_without_third_round(self):
        self.begin(); self.seal(); self.review("FAIL"); w.consume_review(self.root)
        (self.root / "audit/evidence.md").write_text("new failed experiment")
        self.seal(); self.review("FAIL"); w.consume_review(self.root)
        self.assertEqual(w.state(self.root)["phase"], "finalizing")
        self.assertEqual(self.finalize()["verdict"], "FAIL")

    def test_same_question_and_candidate_cannot_restart_under_new_id(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root); self.finalize()
        w.save_state(self.root, {"phase": "idle", "task": None})
        with self.assertRaisesRegex(w.ProtocolError, "Duplicate"):
            self.begin()

    def test_source_edit_after_review_prevents_closure(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        self.source.write_text("unreviewed follow-on change")
        with self.assertRaisesRegex(w.ProtocolError, "Finalization changed"):
            self.finalize()

    def test_checkpoint_must_name_task_and_review(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        with self.assertRaisesRegex(w.ProtocolError, "Checkpoint must identify"):
            w.close(self.root, "claude-session")

    def test_handoff_and_workflow_state_cannot_be_sealed_as_evidence(self):
        # workflow-002: a byte-frozen handoff made close unsatisfiable.
        self.begin()
        (self.root / "audit/workflow").mkdir(exist_ok=True)
        (self.root / "audit/workflow/result-next.json").write_text("{}")
        for path in ("audit/handoff.md", "audit/workflow/result-next.json"):
            with self.assertRaisesRegex(w.ProtocolError, "not sealable evidence"):
                w.seal(self.root, {"summary": "r", "next_action": "n", "status": "READY_FOR_REVIEW",
                                   "open_processes": [], "evidence": ["audit/evidence.md", path]}, "claude-session")
        self.assertEqual(w.state(self.root)["phase"], "editing")

    def test_packet_already_holding_handoff_can_still_close(self):
        # Reproduces task 20260923-184059-9b086122: sealed before the guard existed.
        self.begin()
        with patch.object(w, "HANDOFF", "not-the-handoff"):
            w.seal(self.root, {"summary": "r", "next_action": "n", "status": "READY_FOR_REVIEW", "open_processes": [],
                               "evidence": ["audit/evidence.md", "audit/handoff.md"]}, "claude-session")
        self.review(); w.consume_review(self.root)
        receipt = self.finalize()
        self.assertEqual(w.state(self.root)["phase"], "closed")
        self.assertEqual(receipt["release_status"], "NOT_ASSESSED")

    def test_other_evidence_still_frozen_at_close(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        (self.root / "audit/evidence.md").write_text("edited after review")
        with self.assertRaisesRegex(w.ProtocolError, "Stale artifact"):
            self.finalize()


class LogTests(RepoCase):
    def test_raw_streams_preserved_and_preview_bounded(self):
        out = self.root / "audit/runs/logtest"
        result = run_logged.run(self.root, self.root, out,
            [sys.executable, "-c", "import sys;sys.stdout.write('A'*30000);sys.stderr.write('failure Z'*4000);sys.exit(7)"], 20)
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual((out / "stdout.log").read_text(), "A" * 30000)
        self.assertEqual((out / "stderr.log").read_text(), "failure Z" * 4000)
        self.assertLess(len(json.dumps(result)), 8000)
        self.assertEqual(result["test_acceptance"], "NOT_ASSESSED")
        self.assertIsNone(result["test_count"])

    def test_cli_json_works_with_windows_legacy_console_encoding(self):
        env = {**os.environ, "PYTHONIOENCODING": "cp1252"}
        p = subprocess.run([sys.executable, str(Path(run_logged.__file__)), "--root", str(self.root),
            "--cwd", str(self.root), "--out", "audit/runs/unicode", "--timeout", "10", "--",
            sys.executable, "-c", "import sys;sys.stdout.buffer.write('\\u2714 passed'.encode('utf8'))"],
            env=env, capture_output=True, timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr.decode(errors="replace"))
        parsed = json.loads(p.stdout.decode("ascii"))
        self.assertIn(chr(0x2714), parsed["stdout_excerpt"]["preview"])
        self.assertEqual((self.root / "audit/runs/unicode/stdout.log").read_bytes(), (chr(0x2714) + " passed").encode())

    def test_output_directory_cannot_be_reused(self):
        out = self.root / "audit/runs/existing"
        out.mkdir(parents=True)
        with self.assertRaises(FileExistsError):
            run_logged.run(self.root, self.root, out, [sys.executable, "-c", "print('no')"], 10)

    def test_timeout_not_success(self):
        result = run_logged.run(self.root, self.root, self.root / "audit/runs/timeout",
                                [sys.executable, "-c", "import time;time.sleep(60)"], 0.2)
        self.assertEqual(result["exit_code"], 124)
        self.assertEqual(result["status"], "TIMED_OUT")

    def test_launch_failure_has_receipt(self):
        result = run_logged.run(self.root, self.root, self.root / "audit/runs/missing", ["missing-executable-fixture-987"], 10)
        self.assertEqual(result["exit_code"], 127)
        self.assertTrue(result["launch_error"])


class HookTests(RepoCase):
    def test_startup_is_context_only_no_controller_or_model_call(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(subprocess, "run") as run:
            result = hooks.respond(self.root, {"hook_event_name": "SessionStart", "session_id": "test"})
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertLess(len(json.dumps(result)), 1800)
        run.assert_not_called()

    def test_direct_handoff_write_denied(self):
        r = hooks.respond(self.root, {"hook_event_name": "PreToolUse", "tool_name": "Write",
                                     "tool_input": {"file_path": str(self.root / "audit/handoff.md")}})
        self.assertEqual(r["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_verbose_build_requires_raw_log_wrapper(self):
        self.assertTrue(hooks.noisy_command("zig build test"))
        self.assertFalse(hooks.noisy_command("uv run run_logged.py --timeout 30 -- zig build test"))
        self.assertFalse(hooks.noisy_command("rg hello ecosys-ng/src/ecosys_ng.zig"))

    def test_stop_reminder_is_assigned_and_one_shot(self):
        w.save_state(self.root, {"phase": "editing", "task": "test"})
        w.atomic(w.runtime(self.root) / "dispatch.json", w.encoded({"role": "editor", "session_id": "c"}))
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:p1"}):
            event = {"hook_event_name": "Stop", "session_id": "c", "stop_hook_active": False}
            self.assertEqual(hooks.respond(self.root, event)["decision"], "block")
            self.assertNotIn("decision", hooks.respond(self.root, {**event, "stop_hook_active": True}))
            self.assertNotIn("decision", hooks.respond(self.root, {**event, "session_id": "other"}))


class ControllerTests(RepoCase):
    def test_external_herdr_control_refused_without_cli_call(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(subprocess, "run") as run:
            with self.assertRaises(w.ProtocolError):
                cycle.Herdr(self.root, "fixture").call("agent", "list")
            run.assert_not_called()

    def test_complete_cycle_rotates_both_after_closure(self):
        case = self
        class Fake:
            def __init__(self): self.rotations = []; self.waits = []
            def wait_idle(self, role): self.waits.append((role, w.state(case.root)["phase"]))
            def prompt(self, role, prompt):
                phase = w.state(case.root)["phase"]
                if phase == "planning": case.begin(); case.seal()
                elif phase == "review": case.review()
                elif phase == "finalizing": case.finalize()
                else: raise AssertionError(phase)
            def rotate(self, role, closure):
                self.assert_closed = w.state(case.root)["phase"] == "closed"
                assert self.assert_closed
                w.verify_artifacts(case.root, [closure["handoff"], closure["review"]])
                self.rotations.append(role)
        fake = Fake()
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:p1"}):
            result = cycle.controller(self.root, fake, max_tasks=1)
        self.assertEqual(fake.rotations, ["editor", "reviewer"])
        self.assertEqual(fake.waits[0], ("editor", "idle"))  # no planning before initiating turn yields
        self.assertEqual(result["closed_tasks"], 1)

    def test_missing_seal_does_not_reset_or_approve(self):
        class Fake:
            def wait_idle(self, role): pass
            def prompt(self, role, prompt): pass
            def rotate(self, *args): raise AssertionError("must not reset")
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:p1"}):
            with self.assertRaisesRegex(w.ProtocolError, "without a sealed"):
                cycle.controller(self.root, Fake(), max_tasks=1)

    def test_ambiguous_dispatch_is_not_replayed(self):
        w.save_state(self.root, {"phase": "planning", "task": None})
        w.atomic(w.runtime(self.root) / "dispatch.json", w.encoded({"status": "ambiguous", "role": "editor", "phase": "planning"}))
        class Fake:
            def wait_idle(self, role): pass
            def prompt(self, *args): raise AssertionError("duplicate prompt")
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "fixture:p1"}):
            with self.assertRaisesRegex(w.ProtocolError, "Ambiguous"):
                cycle.controller(self.root, Fake(), max_tasks=1)

    def test_changed_candidate_after_closure_prevents_rotation(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        closure = self.finalize()
        self.source.write_text("someone's new work")
        with self.assertRaisesRegex(w.ProtocolError, "changed after closure"):
            cycle.Herdr(self.root, "fixture").rotate("editor", closure)

    def test_unrelated_new_conversation_never_cleared(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        closure = self.finalize()
        class Fake(cycle.Herdr):
            def wait_idle(self, role): pass
            def registration(self, role): return {"session_id": "unrelated-new-session"}, []
            def call(self, *args, **kwargs): raise AssertionError("must not clear unrelated context")
        with self.assertRaisesRegex(w.ProtocolError, "different conversation"):
            Fake(self.root, "fixture").rotate("editor", closure)

    def test_completed_reset_intent_not_replayed_after_crash(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        closure = self.finalize()
        w.atomic(w.runtime(self.root) / "rotation-editor.json", w.encoded({"closure_id": w.digest(w.encoded(closure)), "old_session_id": "old"}))
        class Fake(cycle.Herdr):
            def wait_idle(self, role): pass
            def registration(self, role): return {"session_id": "new"}, []
            def call(self, *args, **kwargs): raise AssertionError("must not clear twice")
        Fake(self.root, "fixture").rotate("editor", closure)

    def test_reset_requires_new_native_session_id(self):
        self.begin(); self.seal(); self.review(); w.consume_review(self.root)
        closure = self.finalize()
        class Fake(cycle.Herdr):
            def __init__(self, root):
                self.t = 0
                super().__init__(root, "fixture", clock=lambda: self.t, sleep=self.advance)
            def advance(self, n): self.t += n
            def wait_idle(self, role): pass
            def registration(self, role): return {"session_id": "claude-session"}, []
            def idle(self, role): return True
            def call(self, *args, **kwargs): return {"ok": True}
        with self.assertRaisesRegex(w.ProtocolError, "NEW session ID"):
            Fake(self.root).rotate("editor", closure)


if __name__ == "__main__":
    unittest.main()
