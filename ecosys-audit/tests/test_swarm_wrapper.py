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
SENTINEL making no decision. Autonomy (2026-09-25, no human decisions): every former halt is
resolved in place -- quarantine + restore, pre-delivery lane checks, agent relaunch, SAGE
decision tasks, git failures retried -- and one regression per recorded halt. NOT covered:
orphaned child processes (run_logged.py owns process-tree cleanup), real Herdr timing.
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
        self.countdown, self.on_done = {}, {}
        self.pane_screen, self.pane_typed, self.pane_log, self.variant_works = {}, {}, [], True
        self.picker_open, self.chat_messages = {}, []
        self.pane_list = []

    def panes(self):
        return list(self.pane_list)

    def agent(self, name):
        if name in self.countdown:
            self.countdown[name] -= 1
            if self.countdown[name] <= 0:
                del self.countdown[name]
                self.agents[name]["agent_status"] = "idle"
                self.on_done.pop(name, lambda: None)()
        a = self.agents.get(name)
        return dict(a) if a else None

    def pane_read(self, pane):
        return self.pane_screen.get(pane, "")

    def pane_send_text(self, pane, text):
        self.pane_log.append(("text", pane, text))
        self.pane_typed[pane] = text

    def pane_keys(self, pane, *keys):
        self.pane_log.append(("keys", pane, keys))
        typed = self.pane_typed.pop(pane, None)
        if keys == ("enter",) and typed == "/variants" and self.variant_works:
            self.picker_open[pane] = True
            self.pane_screen[pane] = self.pane_screen.get(pane, "") + "\nSelect variant"
        elif keys == ("enter",) and self.picker_open.pop(pane, False) and typed in ("low", "medium", "high"):
            self.pane_screen[pane] = f"Forge auto · Gemini 3.8 Flash GitHub Copilot · {typed}"
        elif keys == ("enter",) and typed and not typed.startswith("/"):
            self.chat_messages.append((pane, typed))  # plain text submitted as a prompt: must never happen

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
        for s in ("ecosys-source-navigation", "ecosys-zig-safety-design", "ecosys-process-science-parity",
                  "ecosys-feature-attribution"):
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
        roster = w.load(root / ".agent/roster.json")
        roster["git"].update({"commit": True, "push": False})  # push is exercised by its own tests
        w.atomic(root / ".agent/roster.json", w.encoded(roster))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@t")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")
        self.herdr = FakeHerdr()
        self.runs = []
        self.now = 1_000_000.0

        def advance(seconds):
            self.now += seconds
        self.swarm = sw.Swarm(root, self.herdr, runner=self.fake_runner, clock=lambda: self.now, sleep=advance,
                              usage=self.fake_usage)

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def fake_usage(self, kind, sid):
        return {"input": 1000, "cache_read": 9000, "cache_write": 0, "output": 200, "tool_calls": 4,
                "llm_calls": 2, "cost": 0.01 if kind == "opencode" else None} if sid else None

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
        # SENTINEL's IDLE is not final until SAGE has been asked (no human decides it).
        self.assertEqual(seen, ["ROUTED", "COLLECTED", "ROUTED", "COLLECTED", "COLLECTED", "ESCALATED"])
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

    def enable_push(self, url):
        self.git("remote", "add", "origin", url)
        roster = w.load(self.root / ".agent/roster.json")
        roster["git"].update({"push": True, "remote": "origin", "branch": "main"})
        w.atomic(self.root / ".agent/roster.json", w.encoded(roster))
        self.git("commit", "-qam", "enable push")
        self.swarm = sw.Swarm(self.root, self.herdr, runner=self.fake_runner, clock=lambda: self.now,
                              sleep=self.swarm.sleep, usage=self.fake_usage)

    def out(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True).stdout.strip()

    def test_every_cycle_commits_and_pushes_and_unreviewed_source_waits_for_sage(self):
        remote = self.root.parent / (self.root.name + "-remote.git")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True, capture_output=True)
        self.addCleanup(shutil.rmtree, remote, True)
        self.enable_push(str(remote))
        self.git("push", "-q", "origin", "main")
        start = int(self.out("rev-list", "--count", "HEAD"))
        seen = []
        orig_step = self.swarm.step

        def step_and_check():
            r = orig_step()
            seen.append(r)
            return r
        self.swarm.step = step_and_check
        self.test_happy_path_sentinel_pathfinder_forge_sage_sentinel()
        self.assertEqual([r["git"]["push"] for r in seen], ["ok"] * 6)
        self.assertEqual(int(self.out("rev-list", "--count", "HEAD")) - start, 6)
        self.assertEqual(self.out("rev-parse", "HEAD"),
                         subprocess.run(["git", "--git-dir", str(remote), "rev-parse", "main"],
                                        capture_output=True, text=True).stdout.strip())
        forge_cycle, sage_cycle = seen[3], seen[4]
        self.assertEqual(forge_cycle["git"]["withheld_unreviewed_source"], ["ecosys-ng/src/a.zig"])
        self.assertEqual(sage_cycle["git"]["withheld_unreviewed_source"], [])
        # a.zig entered history exactly in the SAGE-approved cycle, and the tree is clean afterwards.
        self.assertEqual(self.out("log", "--format=%s", "-n", "1", "--", "ecosys-ng/src/a.zig"), "swarm: T-00003 DONE COLLECTED")
        self.assertEqual(self.out("status", "--porcelain"), "")

    def test_push_failure_never_stops_the_swarm_and_keeps_commits(self):
        self.enable_push(str(self.root.parent / "no-such-remote.git"))
        start = int(self.out("rev-list", "--count", "HEAD"))
        n = [0]

        def idle(_t):
            n[0] += 1
            w.atomic(self.root / ".agent/dispatch.json", w.encoded({"schema_version": 1, "status": "IDLE", "reason": f"r{n[0]}"}))
        self.herdr.behaviors["sentinel"] = idle
        self.herdr.behaviors["sage"] = lambda t: self.write_result("T-00001", finding="DECISION: phase work is finished")
        seen = [self.swarm.step() for _ in range(3)]
        # IDLE -> SAGE idle check -> SAGE decides -> IDLE again is final. Push failed every cycle, no stop.
        self.assertEqual([s["status"] for s in seen], ["ESCALATED", "COLLECTED", "IDLE"])
        self.assertEqual([s["git"]["consecutive_push_failures"] for s in seen], [1, 2, 3])
        self.assertEqual(int(self.out("rev-list", "--count", "HEAD")) - start, 3)

    def test_out_of_lane_source_edit_is_undone_and_never_committed(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.git("add", "-A")
        self.git("commit", "-qm", "dispatch")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 9;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = edit
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"], out["quarantined"]), ("COLLECTED", "FAIL", "Q-T-00001"))
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 1;\n")
        self.assertEqual((self.root / ".agent/failures/Q-T-00001/files/ecosys-ng/src/a.zig").read_text(), "const a = 9;\n")
        self.assertNotIn("ecosys-ng/src/a.zig", self.out("show", "--name-only", "--format=", "HEAD").splitlines())
        self.assertEqual(self.out("status", "--porcelain"), "")

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

    def test_stale_result_blocks_delivery_and_routes_again(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.write_result("T-00001")
        out = self.swarm.step()
        self.assertEqual(out["status"], "ROUTE_INVALID")
        self.assertIn("stale result", out["errors"][0])
        self.assertEqual(self.herdr.prompts, [])
        self.assertEqual(w.load(self.root / ".agent/dispatch.json")["status"], "REJECTED")

    def test_blocked_agent_is_declined_relaunched_and_task_delivered_later(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.agents["pathfinder"]["agent_status"] = "blocked"
        out = self.swarm.step()
        self.assertEqual(out["status"], "AGENT_RECOVERY")
        self.assertEqual(self.herdr.task_prompts("pathfinder"), [])
        self.assertTrue(all(k in (("esc",), ("ctrl+c",)) for _, k in self.herdr.keys))  # declined, never approved
        self.assertEqual(w.load(self.root / ".agent/dispatch.json")["status"], "PENDING")
        self.herdr.agents["pathfinder"]["agent_status"] = "idle"
        self.herdr.behaviors["pathfinder"] = lambda _t: self.write_result("T-00001")
        self.assertEqual(self.swarm.step()["result_status"], "DONE")
        self.assertEqual(len(self.herdr.task_prompts("pathfinder")), 1)

    def test_dialog_mid_turn_is_declined_and_the_turn_continues(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def ask(_t):
            self.herdr.agents["pathfinder"]["agent_status"] = "blocked"
            real = self.herdr.send_keys

            def esc(name, *keys):
                real(name, *keys)
                self.herdr.agents[name]["agent_status"] = "idle"
                self.write_result("T-00001")
            self.herdr.send_keys = esc
        self.herdr.behaviors["pathfinder"] = ask
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "DONE"))
        self.assertEqual(self.herdr.keys, [("pathfinder", ("esc",))])

    def test_concurrent_dispatch_refused_by_lock(self):
        with w.lock(self.root / ".agent/locks/swarm.lock"):
            with self.assertRaises(w.ProtocolError):
                self.swarm.step()
        self.assertEqual(self.herdr.prompts, [])

    def archive(self, tid):
        return w.load(self.root / f".agent/archive/{tid}.json")

    def test_pathfinder_editing_source_is_quarantined(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 9;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = edit
        out = self.swarm.step()
        self.assertEqual(out["result_status"], "FAIL")
        self.assertIn("ecosys-ng/src/a.zig: outside PATHFINDER may_write", self.archive("T-00001")["violations"])
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 1;\n")

    def test_protected_reference_in_allowed_files_is_refused_before_delivery(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- `f77src/x.f`")
        out = self.swarm.step()
        self.assertEqual(out["status"], "ROUTE_INVALID")
        self.assertIn("protected reference", out["errors"][0])
        self.assertEqual(self.herdr.task_prompts("forge"), [])

    def test_protected_reference_edit_is_restored_from_head(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        original = (self.root / "f77src/x.f").read_bytes()

        def edit(_t):
            (self.root / "f77src/x.f").write_text("      STOP\n")
            self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = edit
        self.swarm.step()
        self.assertIn("f77src/x.f: protected reference path", self.archive("T-00001")["violations"])
        self.assertEqual((self.root / "f77src/x.f").read_bytes(), original)  # byte-exact (eol conversion kept)

    def test_out_of_lane_edit_restores_pre_turn_content_not_head(self):
        (self.root / "ecosys-ng/src/a.zig").write_text("const a = 7; // edited before the turn\n")
        self.dispatch_pending("T-00001", "PATHFINDER")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 9;\n")
            (self.root / "ecosys-ng/src/new.zig").write_text("new\n")
            self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = edit
        self.swarm.step()
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 7; // edited before the turn\n")
        self.assertFalse((self.root / "ecosys-ng/src/new.zig").exists())

    def test_forge_cannot_widen_its_own_task(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- none")
        original = (self.root / ".agent/tasks/T-00001.md").read_text()

        def widen(_t):
            p = self.root / ".agent/tasks/T-00001.md"
            p.write_text(p.read_text().replace("## ALLOWED FILES\n- none", "## ALLOWED FILES\n- `ecosys-ng/src/a.zig`"))
            (self.root / ".agent/tasks/T-00001.hypothesis.md").write_text("h")
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 5;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["forge"] = widen
        out = self.swarm.step()
        self.assertEqual(out["result_status"], "FAIL")
        self.assertTrue(any("not in the task's ALLOWED FILES" in v for v in self.archive("T-00001")["violations"]))
        self.assertEqual((self.root / ".agent/tasks/T-00001.md").read_text(), original)
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 1;\n")

    def test_forge_source_edit_without_hypothesis_is_rejected(self):
        self.dispatch_pending("T-00001", "FORGE", allowed="- `ecosys-ng/src/a.zig`")

        def edit(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("const a = 4;\n")
            self.write_result("T-00001")
        self.herdr.behaviors["forge"] = edit
        self.swarm.step()
        self.assertTrue(any("hypothesis" in v for v in self.archive("T-00001")["violations"]))
        self.assertEqual(self.runs, [])  # hooks do not run on a rejected change
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 1;\n")

    def test_budget_timeout_interrupts_and_stagnates(self):
        self.dispatch_pending("T-00001", "PATHFINDER")

        def slow(_t):
            self.herdr.agents["pathfinder"]["agent_status"] = "working"  # never finishes
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

    def test_sentinel_without_decision_twice_escalates_to_sage(self):
        self.herdr.behaviors["sentinel"] = lambda t: None
        self.assertEqual(self.swarm.step()["status"], "ROUTE_INVALID")
        out = self.swarm.step()
        self.assertEqual((out["status"], out["role"]), ("ESCALATED", "SAGE"))
        d = w.load(self.root / ".agent/dispatch.json")
        self.assertEqual((d["status"], d["role"], d["decision_kind"]), ("PENDING", "SAGE", "routing-failure"))
        self.assertEqual(self.wf()["route_failures"], 0)

    def test_sentinel_writing_source_is_undone_and_rerouted(self):
        def bad(_t):
            (self.root / "ecosys-ng/src/a.zig").write_text("x\n")
        self.herdr.behaviors["sentinel"] = bad
        out = self.swarm.step()
        self.assertEqual(out["status"], "ROUTE_INVALID")
        self.assertIn("you wrote outside your lane", out["errors"][0])
        self.assertEqual((self.root / "ecosys-ng/src/a.zig").read_text(), "const a = 1;\n")

    def test_sentinel_asking_for_a_human_gets_a_sage_decision(self):
        self.herdr.behaviors["sentinel"] = lambda t: w.atomic(self.root / ".agent/dispatch.json", w.encoded(
            {"schema_version": 1, "status": "HUMAN_REVIEW_REQUIRED", "reason": "2 campaigns without advance"}))
        out = self.swarm.step()
        self.assertEqual((out["status"], out["role"]), ("ESCALATED", "SAGE"))
        task = (self.root / f".agent/tasks/{out['task_id']}.md").read_text()
        self.assertIn("DECIDE (sentinel-escalation, from SENTINEL): 2 campaigns without advance", task)
        self.assertIn("there is no human reviewer", task)

    def test_result_asking_for_a_human_becomes_a_sage_decision(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.behaviors["pathfinder"] = lambda t: self.write_result(
            "T-00001", finding="x\n\nHUMAN_REVIEW_REQUIRED: the user should decide whether DEV-004 and DEV-006 merge.")
        out = self.swarm.step()
        self.assertEqual(out["decision_queued"], "T-00002")
        d = w.load(self.root / ".agent/dispatch.json")
        self.assertEqual((d["role"], d["decision_of"], d["skills"]), ("SAGE", "T-00001", [sw.DECISION_SKILL]))
        self.assertIn("whether DEV-004 and DEV-006 merge", (self.root / ".agent/tasks/T-00002.md").read_text())
        # SAGE decides; a decision result that defers again is not re-escalated (no loop).
        self.herdr.behaviors["sage"] = lambda t: self.write_result("T-00002", finding="HUMAN_REVIEW_REQUIRED: still unsure")
        out = self.swarm.step()
        self.assertEqual(out["result_status"], "FAIL")  # no DECISION: line
        self.assertNotIn("decision_queued", out)

    def test_reset_that_does_not_land_relaunches_and_task_stays_pending(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.reset_works = False
        out = self.swarm.step()
        self.assertEqual(out["status"], "AGENT_RECOVERY")
        self.assertIn("did not acknowledge /new", out["fault"])
        self.assertEqual(self.herdr.task_prompts("pathfinder"), [])
        # 2026-09-25: the task was never sent, so it stays PENDING and is delivered after recovery.
        self.assertFalse((self.root / ".agent/runtime/inflight.json").exists())
        self.assertEqual(w.load(self.root / ".agent/dispatch.json")["status"], "PENDING")
        self.herdr.reset_works = True
        self.herdr.behaviors["pathfinder"] = lambda _t: self.write_result("T-00001")
        self.assertEqual(self.swarm.step()["result_status"], "DONE")

    def test_transient_agent_not_running_on_task_prompt_is_waited_out_never_resent(self):
        # 2026-09-25 T-00018 route: the prompt landed, Herdr answered agent_not_running and
        # dropped the name while it re-detected OpenCode after /new.
        h = self.herdr
        self.dispatch_pending("T-00001", "PATHFINDER")
        h.pane_list = [{"pane_id": "w1:p2", "label": "PATHFINDER", "agent": "opencode"}]
        real_prompt = h.prompt

        def prompt(name, text, wait, timeout_s=None):
            real_prompt(name, text, wait, timeout_s)
            if not text.startswith("/"):
                h.dropped = h.agents.pop(name)
                raise sw.HerdrError("agent is no longer running in the target pane", "agent_not_running")
        h.prompt = prompt

        def rename(pane, name):
            h.agents[name] = {**h.dropped, "pane_id": pane, "name": name}
        h.rename = rename
        h.behaviors["pathfinder"] = lambda _t: self.write_result("T-00001")
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "DONE"))
        self.assertEqual(len(h.task_prompts("pathfinder")), 1)

    def test_name_dropped_by_herdr_after_clear_is_rebound_to_the_labelled_pane(self):
        # 2026-09-25: a directly launched Claude lost its Herdr name at /clear (new session).
        h = self.herdr
        self.dispatch_pending("T-00001", "SAGE", skills=["ecosys-process-science-parity"])
        h.pane_list = [{"pane_id": "w1:p4", "label": "SAGE", "agent": "claude"}]
        real_prompt = h.prompt

        def prompt(name, text, wait, timeout_s=None):
            real_prompt(name, text, wait, timeout_s)
            if text == "/clear":
                h.dropped = h.agents.pop("sage")
        h.prompt = prompt

        def rename(pane, name):
            h.agents[name] = {**h.dropped, "pane_id": pane, "name": name}
        h.rename = rename
        h.behaviors["sage"] = lambda _t: self.write_result("T-00001")
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "DONE"))
        self.assertEqual(len(h.task_prompts("sage")), 1)

    def test_sentinel_gets_one_self_contained_brief(self):
        (self.root / ".agent/roles").mkdir(parents=True, exist_ok=True)
        (self.root / ".agent/roles/sentinel.md").write_text("ROLE RULES MARKER\n")
        (self.root / ".agent/templates").mkdir(parents=True, exist_ok=True)
        (self.root / ".agent/templates/task.md").write_text("TEMPLATE MARKER\n")
        (self.root / ".agent/state.md").write_text("STATE MARKER\n")
        (self.root / "audit").mkdir(exist_ok=True)
        (self.root / "audit/unresolved-gaps.md").write_text("GAPS MARKER\n")
        (self.root / ".agent/tasks/T-00001.md").write_text(TASK.format(tid="T-00001", role="PATHFINDER", allowed="- none"))
        self.write_result("T-00001", finding="FINDING MARKER")
        w.atomic(self.root / ".agent/archive/T-00001.json", w.encoded({"result_status": "DONE"}))
        seen = {}

        def sentinel(text):
            seen["prompt"] = text
            seen["brief"] = (self.root / ".agent/runtime/sentinel-brief.md").read_text()
            w.atomic(self.root / ".agent/dispatch.json", w.encoded({"schema_version": 1, "status": "IDLE", "reason": "x"}))
        self.herdr.behaviors["sentinel"] = sentinel
        self.assertEqual(self.swarm.step()["status"], "ESCALATED")
        self.assertIn(".agent/runtime/sentinel-brief.md", seen["prompt"])
        for marker in ("next free task ID: T-00002", "ROLE RULES MARKER", "STATE MARKER", "GAPS MARKER", "FINDING MARKER",
                       "- T-00001 PATHFINDER [DONE]: test objective", "TEMPLATE MARKER",
                       "- FORGE: ecosys-ng/src/", "- SAGE: .agent/results/, audit/intentional-deviations.md"):
            self.assertIn(marker, seen["brief"])

    def test_metrics_record_tokens_and_cost_report(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.herdr.behaviors["pathfinder"] = lambda t: self.write_result("T-00001")
        self.swarm.step()
        lines = (self.root / ".agent/metrics.csv").read_text().splitlines()
        self.assertEqual(lines[0], sw.Swarm.METRICS_HEADER)
        row = dict(zip(lines[0].split(","), lines[-1].split(",")))
        self.assertEqual((row["input_tokens"], row["output_tokens"], row["tool_calls"], row["cache_read_tokens"],
                          row["cost_usd_estimate"]), ("10000", "200", "4", "9000", "0.0100"))
        rep = self.swarm.cost_report()
        self.assertEqual(rep["by_role"]["PATHFINDER"]["tokens_in"], 10000)
        self.assertIsNone(rep["tokens_in_per_advance"])

    def sage_chain_result(self, allowed):
        self.dispatch_pending("T-00001", "SAGE", skills=["ecosys-process-science-parity"])

        def sage(_t):
            self.write_result("T-00001")
            with (self.root / ".agent/results/T-00001.md").open("a") as f:
                f.write(f"\n## CHAIN\nROLE: FORGE            (or PATHFINDER)\nOBJECTIVE: apply the approved lines\n"
                        f"ALLOWED: {allowed}\nSKILLS: none           (or skill names)\n")
        self.herdr.behaviors["sage"] = sage
        return self.swarm.step()

    def test_sage_chain_dispatches_a_mechanical_followup_without_sentinel(self):
        out = self.sage_chain_result("audit/issues/issue-001.md, audit/issues/issue-002.md")
        self.assertEqual(out["chained"], "T-00002")
        d = w.load(self.root / ".agent/dispatch.json")
        self.assertEqual((d["status"], d["role"], d["chained_from"], d["skills"]), ("PENDING", "FORGE", "T-00001", []))
        task = (self.root / ".agent/tasks/T-00002.md").read_text()
        self.assertIn("- `audit/issues/issue-002.md`", task)

        def forge(_t):
            (self.root / "audit/issues").mkdir(parents=True, exist_ok=True)
            (self.root / "audit/issues/issue-001.md").write_text("Status: CLOSED\n")
            self.write_result("T-00002")
        self.herdr.behaviors["forge"] = forge
        self.assertEqual(self.swarm.step()["result_status"], "DONE")
        self.assertEqual(self.herdr.task_prompts("sentinel"), [])  # no routing turn was spent

    def test_chain_outside_the_chained_roles_lane_is_not_dispatched(self):
        # 2026-09-25 T-00031 regression: SAGE chained FORGE onto SAGE's own ledger file.
        out = self.sage_chain_result("audit/intentional-deviations.md")
        self.assertNotIn("chained", out)
        self.assertIn("`audit/intentional-deviations.md` is outside FORGE may_write (writable by SAGE)", out["chain_note"])
        self.assertEqual(self.herdr.task_prompts("forge"), [])

    def test_chain_naming_production_source_is_ignored(self):
        out = self.sage_chain_result("ecosys-ng/src/a.zig")
        self.assertNotIn("chained", out)
        self.assertIn("production/protected", out["chain_note"])
        self.assertEqual(w.load(self.root / ".agent/dispatch.json")["status"], "COMPLETE")

    def test_early_prompt_return_does_not_cut_a_working_agent_short(self):
        # T-00007 regression: prompt --wait returned while PATHFINDER was still working.
        self.dispatch_pending("T-00001", "PATHFINDER")

        def long_task(_t):
            self.herdr.agents["pathfinder"]["agent_status"] = "working"
            self.herdr.countdown["pathfinder"] = 200  # ~10 simulated minutes of polling
            self.herdr.on_done["pathfinder"] = lambda: self.write_result("T-00001")
        self.herdr.behaviors["pathfinder"] = long_task
        out = self.swarm.step()
        self.assertEqual((out["status"], out["result_status"]), ("COLLECTED", "DONE"))
        self.assertEqual(self.herdr.keys, [])  # never interrupted

    def test_launch_variant_is_selected_and_verified(self):
        self.herdr.pane_screen["w1:p2"] = "Forge auto · Gemini 3.8 Flash GitHub Copilot"
        self.swarm.set_variant("FORGE", "w1:p2")
        self.assertIn("· high", self.herdr.pane_screen["w1:p2"])
        self.assertEqual([e[2] for e in self.herdr.pane_log if e[0] == "text"], ["/variants", "high"])
        self.herdr.pane_log.clear()
        self.swarm.set_variant("FORGE", "w1:p2")  # already set: no keystrokes
        self.assertEqual(self.herdr.pane_log, [])

    def test_launch_runs_executable_directly_and_names_the_detected_agent(self):
        # 2026-09-25: `herdr agent start` typed its long shim at 1-6 chars/s and timed out.
        h = self.herdr
        del h.agents["forge"]
        runs, detected = [], {"n": 0}
        h.foreground = lambda pane: ["zsh"]
        h.pane_run = lambda pane, cmd: runs.append((pane, cmd))

        def pane(p):
            detected["n"] += 1
            return {"pane_id": p, "agent": "opencode" if detected["n"] >= 3 else None}
        h.pane = pane

        def rename(p, name):
            h.agents[name] = {"agent": "opencode", "agent_status": "idle", "pane_id": p, "name": name}
        h.rename = rename
        h.start = lambda *a, **k: self.fail("agent start must not be used when an executable is configured")
        self.swarm.roster["executables"] = {"opencode": "C:/x/opencode.exe"}
        self.swarm.roster["roles"]["FORGE"].pop("variant", None)
        self.swarm.launch("FORGE", "w1:p9")
        self.assertEqual(runs, [("w1:p9", "export ECOSYS_SWARM_ROLE=forge && C:/x/opencode.exe --agent forge -m "
                                          "github-copilot/gemini-3.8-flash --auto")])
        self.assertEqual(h.agents["forge"]["pane_id"], "w1:p9")

    def test_launch_variant_that_never_shows_is_an_error(self):
        self.herdr.variant_works = False
        self.herdr.pane_screen["w1:p2"] = "Forge auto · Gemini 3.8 Flash GitHub Copilot"
        with self.assertRaises(w.ProtocolError):
            self.swarm.set_variant("FORGE", "w1:p2")
        # The picker never opened, so the variant name was never typed into the chat.
        self.assertEqual([e[2] for e in self.herdr.pane_log if e[0] == "text"], ["/variants"] * 3)
        self.assertEqual(self.herdr.chat_messages, [])

    def test_legacy_halt_is_cleared_automatically_and_its_leftovers_committed(self):
        # The T-00031 halt as left by the pre-autonomy controller.
        (self.root / "audit").mkdir(exist_ok=True)
        (self.root / "audit/intentional-deviations.md").write_text("merged row\n")
        (self.root / "f77src/x.f").write_text("      STOP\n")
        self.swarm.halt("T-00031 (FORGE) scope violation, left in place for the user")
        out = self.swarm.step()
        self.assertEqual((out["status"], out["next"]), ("RECOVERED", "route"))
        self.assertEqual(self.wf()["halts"][-1]["cleared_by"], "swarm_wrapper (autonomous)")
        self.assertEqual((self.root / "f77src/x.f").read_text(), "      END\n")  # protected edit undone
        self.assertEqual(self.out("status", "--porcelain"), "")
        self.assertIn("audit/intentional-deviations.md", self.out("show", "--name-only", "--format=", "HEAD"))

    def test_run_loop_retries_errors_and_waits_and_stops_only_when_idle(self):
        results = iter([w.ProtocolError("herdr call failed"), {"status": "WAITING"}, {"status": "AGENT_RECOVERY"},
                        {"status": "COLLECTED"}, {"status": "IDLE"}])

        def step():
            r = next(results)
            if isinstance(r, Exception):
                raise r
            return r
        self.swarm.step = step
        out = self.swarm.run()
        self.assertEqual((out["status"], out["steps"]), ("IDLE", 5))

    def test_run_loop_refuses_when_another_controller_holds_the_lock(self):
        with w.lock(self.root / ".agent/locks/swarm.lock"):
            self.assertEqual(self.swarm.run()["status"], "REFUSED")

    def test_clear_review_records_decision_commits_leftovers_and_resumes(self):
        self.dispatch_pending("T-00001", "PATHFINDER")
        self.write_result("T-00001")
        self.swarm.halt("operator halt")
        with self.assertRaises(w.ProtocolError):
            self.swarm.clear_review("user", "short")
        out = self.swarm.clear_review("user", "stale result was a leftover test file; keep it as evidence")
        self.assertEqual((out["status"], out["next"], out["git"]["commit"] != "nothing"), ("CLEARED", "deliver pending dispatch", True))
        wf = self.wf()
        self.assertEqual((wf["status"], wf["halts"][-1]["cleared_by"]), ("DISPATCHED", "user"))
        self.assertEqual(subprocess.run(["git", "status", "--porcelain"], cwd=self.root, capture_output=True, text=True).stdout, "")
        with self.assertRaises(w.ProtocolError):
            self.swarm.clear_review("user", "not halted any more, must refuse")

    def test_clear_review_refuses_while_protected_reference_is_modified(self):
        (self.root / "f77src/x.f").write_text("      STOP\n")
        self.swarm.halt("test halt")
        with self.assertRaises(w.ProtocolError):
            self.swarm.clear_review("user", "trying to clear with f77src modified")

    def test_rejected_route_is_not_delivered_and_errors_reach_the_next_brief(self):
        (self.root / ".agent/tasks/T-00001.md").write_text(TASK.format(tid="T-00001", role="SAGE", allowed="- none"))
        briefs = []

        def sentinel(_t):
            briefs.append((self.root / ".agent/runtime/sentinel-brief.md").read_text())
            if len(briefs) == 1:  # first attempt: two SAGE skills (the T-00015 mistake)
                w.atomic(self.root / ".agent/dispatch.json", w.encoded({
                    "schema_version": 1, "status": "PENDING", "task_id": "T-00001", "role": "SAGE",
                    "task_file": ".agent/tasks/T-00001.md", "result_file": ".agent/results/T-00001.md",
                    "skills": ["ecosys-process-science-parity", "ecosys-source-navigation"]}))
            else:
                w.atomic(self.root / ".agent/dispatch.json", w.encoded({"schema_version": 1, "status": "IDLE", "reason": "fixed"}))
        self.herdr.behaviors["sentinel"] = sentinel
        self.assertEqual(self.swarm.step()["status"], "ROUTE_INVALID")
        self.assertEqual(w.load(self.root / ".agent/dispatch.json")["status"], "REJECTED")
        self.assertEqual(self.swarm.step()["status"], "ESCALATED")  # routed again, the bad one never delivered
        self.assertIn("PREVIOUS ROUTING ATTEMPT WAS REJECTED", briefs[1])
        self.assertIn("SAGE tasks name exactly one", briefs[1])
        self.assertEqual(self.herdr.task_prompts("sage"), [])

    def test_controller_writes_state_sections_from_the_dispatch(self):
        (self.root / ".agent/state.md").write_text("# S\n\n## Confirmed facts\n- keep me\n\n## Recent accepted change\n- old\n\n"
                                                   "## Next expected operation\nold next\n")

        def sentinel(_t):
            w.atomic(self.root / ".agent/dispatch.json", w.encoded({
                "schema_version": 1, "status": "IDLE", "reason": "r",
                "state_recent": ["T-00009 PATHFINDER DONE: thing"], "state_next": "wait for the user"}))
        self.herdr.behaviors["sentinel"] = sentinel
        self.swarm.step()
        s = (self.root / ".agent/state.md").read_text()
        self.assertIn("- keep me", s)
        self.assertIn("## Recent accepted change\n- T-00009 PATHFINDER DONE: thing\n", s)
        self.assertIn("## Next expected operation\nwait for the user\n", s)
        self.assertNotIn("old next", s)

    def test_invalid_sage_skill_rejected(self):
        self.dispatch_pending("T-00001", "SAGE", skills=["ecosys-source-navigation"])
        self.assertIn("SAGE tasks name exactly one", self.swarm.step()["errors"][0])

    def test_no_code_path_raises_a_human_halt(self):
        src = (REPO / "ecosys-audit/scripts/swarm_wrapper.py").read_text(encoding="utf-8")
        self.assertNotIn("HumanReview", src)
        self.assertEqual(src.count("self.halt("), 0)  # halt() survives only for the operator override tests


if __name__ == "__main__":
    unittest.main(verbosity=2)
