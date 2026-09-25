# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Wrapper suite required before autonomy (plan P1.5). No model calls, no real Herdr.

A scripted fake Herdr stands in for the four agents; each fake agent writes the files a real
role would. A temporary Git repository stands in for the project. Covered: happy path
S->P->F->SAGE->S, killed pane + resume, stale result, duplicate delivery, permission-blocked
agent, concurrent dispatch refused by lock, review invalidated by a later source change,
scope violations, task widening, missing hypothesis, budget timeout, unapproved autonomy,
SENTINEL making no decision. NOT covered: orphaned child processes (run_logged.py owns
process-tree cleanup; see its own taskkill path), real Herdr timing.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import swarm_wrapper as sw
import workflow as w
from evidence_binding import dirty_source_digest

REPO = Path(__file__).resolve().parents[2]


class Crash(Exception):
    """Simulates the controller process dying mid-turn."""


class FakeHerdr:
    def __init__(self):
        kinds = {"sentinel": "opencode", "pathfinder": "opencode", "forge": "opencode", "sage": "claude"}
        self.agents = {n: {"agent": k, "agent_status": "idle", "pane_id": f"w1:p{i}", "name": n,
                           "agent_session": {"value": f"{n}-s0"}} for i, (n, k) in enumerate(kinds.items(), 1)}
        self.prompts, self.keys, self.behaviors, self.seq = [], [], {}, 0
        self.screens = {n: "previous conversation" for n in kinds}
        self.reset_works = True

    def agent(self, name):
        a = self.agents.get(name)
        return dict(a) if a else None

    def read(self, name):
        return self.screens[name]

    def prompt(self, name, text, wait, timeout_s=None):
        self.prompts.append((name, text))
        if text in ("/new", "/clear"):
            if not self.reset_works:
                return
            # Real OpenCode under Herdr keeps the OLD session id after /new; Claude gets a new one.
            if self.agents[name]["agent"] == "claude":
                self.seq += 1
                self.agents[name]["agent_session"] = {"value": f"{name}-s{self.seq}"}
            self.screens[name] = "Ask anything... welcome"
            return
        self.screens[name] = "conversation in progress"
        fn = self.behaviors.get(name)
        if fn:
            fn(text)

    def send_keys(self, name, *keys):
        self.keys.append((name, keys))

    def task_prompts(self, name):
        return [t for n, t in self.prompts if n == name and not t.startswith("/")]


TASK = """# TASK: {tid}

## ROLE
{role}

## OBJECTIVE
test objective

## INPUTS
- none

## ALLOWED FILES
{allowed}

## DO NOT
- nothing

## RELEVANT SKILLS
- none

## KNOWN FACTS
- none

## HYPOTHESIS
n/a

## SUCCESS CONDITION
result written

## STOP CONDITIONS
budget

## OUTPUT FILE
.agent/results/{tid}.md
"""

RESULT = """# TASK: {tid}

## STATUS
{status}

## FINDING
{finding}

## EVIDENCE
- none

## FILES INSPECTED OR CHANGED
- none

## TESTS
- none

## SCIENTIFIC IMPACT
None

## UNCERTAINTY
none

## RECOMMENDED NEXT ACTION
none
"""


class SwarmTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = root = Path(self.tmp.name).resolve()
        (root / ".agent").mkdir()
        shutil.copy(REPO / ".agent/roster.json", root / ".agent/roster.json")
        for d in ("tasks", "results", "failures", "locks", "archive"):
            (root / ".agent" / d).mkdir()
            (root / ".agent" / d / ".gitkeep").write_text("")
        for s in ("ecosys-source-navigation", "ecosys-zig-safety-design", "ecosys-process-science-parity"):
            (root / ".agents/skills" / s).mkdir(parents=True)
            (root / ".agents/skills" / s / "SKILL.md").write_text("x")
        w.atomic(root / ".agent/workflow.json", w.encoded({"schema_version": 1, "status": "ROUTING", "autonomy_approved": True}))
        w.atomic(root / ".agent/frontier.json", w.encoded({"verified_frontier": 0, "history": []}))
        w.atomic(root / ".agent/dispatch.json", w.encoded({"schema_version": 1, "status": "IDLE"}))
        (root / ".agent/metrics.csv").write_text("header\n")
        (root / ".gitignore").write_text(".agent/runtime/\n.agent/locks/*\n")
        (root / "ecosys-ng/src").mkdir(parents=True)
        (root / "ecosys-ng/src/a.zig").write_text("const a = 1;\n")
        (root / "f77src").mkdir()
        (root / "f77src/x.f").write_text("      END\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
        self.herdr = FakeHerdr()
        self.runs = []
        self.now = 1_000_000.0

        def advance(seconds):
            self.now += seconds
        self.swarm = sw.Swarm(root, self.herdr, runner=self.fake_runner, clock=lambda: self.now, sleep=advance)

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def fake_runner(self, argv, cwd, label, timeout):
        self.runs.append((argv, cwd, label))
        return {"exit_code": 0, "receipt": f"audit/runs/swarm/{label}/receipt.json"}

    # --- helpers that play the agents
    def sentinel_queue(self, items):
        queue = list(items)

        def act(_text):
            item = queue.pop(0)
            if item.get("status") != "PENDING":
                w.atomic(self.root / ".agent/dispatch.json", w.encoded({"schema_version": 1, **item}))
                return
            tid = item["task_id"]
            (self.root / f".agent/tasks/{tid}.md").write_text(
                TASK.format(tid=tid, role=item["role"], allowed=item.pop("allowed", "- none")))
            w.atomic(self.root / ".agent/dispatch.json", w.encoded({
                "schema_version": 1, "status": "PENDING", "task_file": f".agent/tasks/{tid}.md",
                "result_file": f".agent/results/{tid}.md", "skills": [], "t1_argv": None,
                "requires_sage_review": False, "full_run_justification": None, "reason": "test", **item}))
        self.herdr.behaviors["sentinel"] = act

    def write_result(self, tid, status="DONE", finding="ok"):
        (self.root / f".agent/results/{tid}.md").write_text(RESULT.format(tid=tid, status=status, finding=finding))

    def dispatch_pending(self, tid, role, allowed="- none", **extra):
        (self.root / f".agent/tasks/{tid}.md").write_text(TASK.format(tid=tid, role=role, allowed=allowed))
        w.atomic(self.root / ".agent/dispatch.json", w.encoded({
            "schema_version": 1, "status": "PENDING", "task_id": tid, "role": role,
            "task_file": f".agent/tasks/{tid}.md", "result_file": f".agent/results/{tid}.md",
            "skills": [], "t1_argv": None, "requires_sage_review": False, "full_run_justification": None, **extra}))

    def wf(self):
        return w.load(self.root / ".agent/workflow.json")

    # --- tests
    def test_happy_path_sentinel_pathfinder_forge_sage_sentinel(self):
        self.sentinel_queue([
            {"status": "PENDING", "task_id": "T-00001", "role": "PATHFINDER", "skills": ["ecosys-source-navigation"]},
            {"status": "PENDING", "task_id": "T-00002", "role": "FORGE", "skills": ["ecosys-zig-safety-design"],
             "allowed": "- `ecosys-ng/src/a.zig`", "t1_argv": ["zig", "build", "test"]},
            {"status": "IDLE", "reason": "worklist empty"},
        ])
        self.herdr.behaviors["pathfinder"] = lambda t: self.write_result("T-00001")

        def forge(_t):
            (self.root / ".agent/tasks/T-00002.hypothesis.md").write_text("# HYPOTHESIS\n")
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 2;\n")
            self.write_result("T-00002")
        self.herdr.behaviors["forge"] = forge

        def sage(_t):
            h = dirty_source_digest(self.root)["sha256"]
            self.write_result("T-00003", finding=f"VERDICT: APPROVE\nDIFF SHA256: {h}")
        self.herdr.behaviors["sage"] = sage

        seen = [self.swarm.step()["status"] for _ in range(6)]
        self.assertEqual(seen, ["ROUTED", "COLLECTED", "ROUTED", "COLLECTED", "COLLECTED", "IDLE"])
        arch = w.load(self.root / ".agent/archive/T-00002.json")
        self.assertEqual(arch["changed"], [".agent/results/T-00002.md", ".agent/tasks/T-00002.hypothesis.md", "ecosys-ng/src/a.zig"])
        self.assertEqual([r[2] for r in self.runs], ["T-00002-fmt", "T-00002-t1"])
        self.assertTrue(w.load(self.root / ".agent/archive/T-00003.json")["review"]["valid"])
        self.assertEqual(self.swarm.precommit()["status"], "PASS")
        # Each role got a fresh session before its task; every task prompt was delivered once.
        self.assertEqual(len(self.herdr.task_prompts("pathfinder")), 1)
        self.assertEqual(sum(1 for n, t in self.herdr.prompts if t == "/new"), 5)
        self.assertEqual(sum(1 for n, t in self.herdr.prompts if t == "/clear"), 1)
        self.assertEqual(len((self.root / ".agent/metrics.csv").read_text().splitlines()), 1 + 6)

    def test_source_change_after_review_invalidates_it(self):
        self.test_happy_path_sentinel_pathfinder_forge_sage_sentinel()
        (self.root / "ecosys-ng/src/a.zig").write_text("const a = 3;\n")
        self.assertEqual(self.swarm.precommit()["status"], "FAIL")

    def test_killed_controller_resume_never_reprompts(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def crash(_t):
            raise Crash()
        self.herdr.behaviors["pathfinder"] = crash
        with self.assertRaises(Crash):
            self.swarm.step()
        self.assertTrue((self.root / ".agent/runtime/inflight.json").exists())
        del self.herdr.agents["pathfinder"]  # the pane was killed too
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "STAGNATED"))
        self.assertEqual(len(self.herdr.task_prompts("pathfinder")), 1)
        self.assertIsNotNone(w.load(self.root / ".agent/archive/T-00001.json")["failure_packet"])

    def test_resume_collects_result_written_before_crash(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def crash(_t):
            self.write_result("T-00001")
            raise Crash()
        self.herdr.behaviors["pathfinder"] = crash
        with self.assertRaises(Crash):
            self.swarm.step()
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "DONE"))
        self.assertEqual(len(self.herdr.task_prompts("pathfinder")), 1)

    def test_duplicate_delivery_refused_while_agent_still_working(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def crash(_t):
            raise Crash()
        self.herdr.behaviors["pathfinder"] = crash
        with self.assertRaises(Crash):
            self.swarm.step()
        self.herdr.agents["pathfinder"]["agent_status"] = "working"
        self.assertEqual(self.swarm.step()["status"], "WAITING")
        self.assertEqual(len(self.herdr.task_prompts("pathfinder")), 1)

    def test_stale_result_blocks_delivery(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.write_result("T-00001")
        out = self.swarm.step()
        self.assertEqual(out["status"], "HUMAN_REVIEW_REQUIRED")
        self.assertIn("stale result", out["reason"])
        self.assertEqual(self.herdr.prompts, [])

    def test_permission_blocked_agent_is_never_answered(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.agents["pathfinder"]["agent_status"] = "blocked"
        out = self.swarm.step()
        self.assertEqual(out["status"], "HUMAN_REVIEW_REQUIRED")
        self.assertEqual(self.herdr.prompts, [])
        self.assertEqual(self.herdr.keys, [])
        self.assertEqual(self.swarm.step()["status"], "STOPPED")

    def test_concurrent_dispatch_refused_by_lock(self):
        with w.lock(self.root / ".agent/locks/swarm.lock"):
            with self.assertRaises(w.ProtocolError):
                self.swarm.step()
        self.assertEqual(self.herdr.prompts, [])

    def test_pathfinder_editing_source_is_a_scope_violation_left_in_place(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 9;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = edit
        out = self.swarm.step()
        self.assertEqual(out["status"], "HUMAN_REVIEW_REQUIRED")
        self.assertIn("ecosys-ng/src/a.zig: outside PATHFINDER may_write", out["reason"])
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 9;\n")  # never auto-reverted

    def test_protected_reference_edit_is_a_violation(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- `f77src/x.f`")

        def edit(_t):
            (self.root / "f77src/x.f").write_text("      STOP\n")
            self.write_result("T-00001")
        self.herdr.behaviors["forge"] = edit
        self.assertIn("protected reference", self.swarm.step()["reason"])

    def test_forge_cannot_widen_its_own_task(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- none")

        def widen(_t):
            p = self.root / ".agent/tasks/T-00001.md"
            p.write_text(p.read_text().replace("## ALLOWED FILES\n- none", "## ALLOWED FILES\n- `ecosys-ng/src/a.zig`"))
            (self.root / ".agent/tasks/T-00001.hypothesis.md").write_text("h")
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 5;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["forge"] = widen
        out = self.swarm.step()
        self.assertEqual(out["status"], "HUMAN_REVIEW_REQUIRED")
        self.assertIn("not in the task's ALLOWED FILES", out["reason"])

    def test_forge_source_edit_without_hypothesis_is_rejected(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- `ecosys-ng/src/a.zig`")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 4;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["forge"] = edit
        self.assertIn("hypothesis", self.swarm.step()["reason"])
        self.assertEqual(self.runs, [])  # hooks do not run on a rejected change

    def test_budget_timeout_interrupts_and_stagnates(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def slow(_t):
            raise sw.HerdrError("timed out", "timeout")
        self.herdr.behaviors["pathfinder"] = slow
        out = self.swarm.step()
        self.assertEqual(out["result_status"], "STAGNATED")
        self.assertEqual(self.herdr.keys, [("pathfinder", ("esc",))])
        self.assertEqual(self.wf()["failure_signatures"], {"PATHFINDER:T-00001": 1})

    def test_autonomy_requires_user_approval(self):
        wf = self.wf()
        wf["autonomy_approved"] = False
        w.atomic(self.root / ".agent/workflow.json", w.encoded(wf))
        self.assertEqual(self.swarm.step()["status"], "REFUSED")
        self.assertEqual(self.herdr.prompts, [])

    def test_sentinel_without_decision_twice_escalates(self):
        self.herdr.behaviors["sentinel"] = lambda t: None
        self.assertEqual(self.swarm.step()["status"], "ROUTE_INVALID")
        self.assertEqual(self.swarm.step()["status"], "HUMAN_REVIEW_REQUIRED")

    def test_sentinel_writing_source_is_a_violation(self):
        def bad(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("x\n")
        self.herdr.behaviors["sentinel"] = bad
        self.assertIn("SENTINEL wrote outside its lane", self.swarm.step()["reason"])

    def test_reset_that_does_not_land_blocks_the_task(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.reset_works = False
        out = self.swarm.step()
        self.assertEqual(out["status"], "HUMAN_REVIEW_REQUIRED")
        self.assertIn("did not acknowledge /new", out["reason"])
        self.assertEqual(self.herdr.task_prompts("pathfinder"), [])

    def test_invalid_sage_skill_rejected(self):
        self.dispatch_pending("T-00001", "SAGE", skills=["ecosys-source-navigation"])
        self.assertIn("SAGE tasks name exactly one", self.swarm.step()["reason"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
