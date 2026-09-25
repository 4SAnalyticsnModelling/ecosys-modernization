# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Deterministic 4-agent swarm controller (spec section 4; plan P1.2-P1.5). Not an AI.

It routes nothing and judges no science. Each `step` does exactly one agent turn:
  - no pending dispatch  -> fresh SENTINEL session writes .agent/dispatch.json
  - pending dispatch     -> fresh session of the named role executes the task file
then deterministic hooks: scope check of every changed path against the roster and the task's
ALLOWED FILES, `zig fmt` + T1 after FORGE, failure packet on failure, automatic SAGE review of any
production-source change (bound to the source-diff hash), archive + metrics.

Safety: at-most-once delivery (a crash mid-turn is never re-prompted), one global lock, blocked
agents are never answered, out-of-scope edits are never reverted automatically (HUMAN_REVIEW_REQUIRED),
no commit, no push. Autonomous `run` requires .agent/workflow.json autonomy_approved=true.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from workflow import ROOT, ProtocolError, atomic, digest, encoded, load, lock
from evidence_binding import dirty_source_digest

AGENT = ".agent"
SCRIPTS = Path(__file__).resolve().parent
TASK_RE = re.compile(r"^T-\d{5}$")
WORKER_ROLES = ("PATHFINDER", "FORGE", "SAGE")
RESULT_STATUSES = ("DONE", "FAIL", "STAGNATED", "BLOCKED")
TASK_SECTIONS = ("ROLE", "OBJECTIVE", "INPUTS", "ALLOWED FILES", "RELEVANT SKILLS", "KNOWN FACTS",
                 "SUCCESS CONDITION", "STOP CONDITIONS", "OUTPUT FILE")
RESULT_SECTIONS = ("STATUS", "FINDING", "EVIDENCE", "FILES INSPECTED OR CHANGED", "TESTS",
                   "SCIENTIFIC IMPACT", "UNCERTAINTY", "RECOMMENDED NEXT ACTION")
SHELLS = ("zsh", "bash", "sh", "pwsh", "powershell", "cmd")
LIMITATIONS = ("Process management only. Scope checks see Git-visible files (ignored paths such as evidence/ "
               "are not attributed); concurrent human edits during a turn are attributed to the agent.")


class HumanReview(Exception):
    """Stop the swarm and ask the user; never resolved automatically."""


# ------------------------------------------------------------------ Herdr client

class HerdrError(ProtocolError):
    def __init__(self, message: str, code: str | None = None):
        super().__init__(message)
        self.code = code


class Herdr:
    """Thin JSON client for one named Herdr session. Fails closed on anything unexpected."""

    def __init__(self, session: str, root: Path):
        self.session, self.root = session, root

    def call(self, *args: str, timeout: float = 60) -> dict:
        if os.environ.get("HERDR_ENV") != "1":
            raise ProtocolError("swarm_wrapper must run inside a Herdr pane (HERDR_ENV=1)")
        p = subprocess.run(["herdr", "--session", self.session, *args], cwd=self.root, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=timeout)
        text = (p.stdout or "").strip() or (p.stderr or "").strip()
        try:
            value = json.loads(text) if text else {}
        except ValueError:
            value = {}
        err = value.get("error") if isinstance(value, dict) else None
        if p.returncode or err:
            code = err.get("code") if isinstance(err, dict) else None
            raise HerdrError(f"herdr {' '.join(args[:2])}: exit {p.returncode} {text[:400]}", code)
        return value

    def agent(self, name: str) -> dict | None:
        try:
            return self.call("agent", "get", name)["result"]["agent"]
        except HerdrError as e:
            if e.code == "agent_not_found":
                return None
            raise

    def panes(self) -> list[dict]:
        return self.call("pane", "list")["result"]["panes"]

    def foreground(self, pane: str) -> list[str]:
        info = self.call("pane", "process-info", "--pane", pane)["result"]["process_info"]
        return [Path(p.get("name", "")).stem.lower() for p in info.get("foreground_processes", [])]

    def prompt(self, name: str, text: str, wait: bool, timeout_s: float | None = None):
        args = ["agent", "prompt", name, text]
        if wait:
            args += ["--wait", "--timeout", str(int((timeout_s or 600) * 1000))]
        self.call(*args, timeout=(timeout_s or 60) + 60)

    def send_keys(self, name: str, *keys: str):
        self.call("agent", "send-keys", name, *keys)

    def read(self, name: str) -> str:
        """Visible screen text. Used ONLY to confirm a reset landed on the welcome screen."""
        if os.environ.get("HERDR_ENV") != "1":
            raise ProtocolError("swarm_wrapper must run inside a Herdr pane (HERDR_ENV=1)")
        p = subprocess.run(["herdr", "--session", self.session, "agent", "read", name, "--source", "visible"],
                           cwd=self.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        if p.returncode:
            raise HerdrError(f"herdr agent read: exit {p.returncode}")
        return p.stdout

    def rename(self, target: str, name: str):
        self.call("agent", "rename", target, name)

    def pane_run(self, pane: str, command: str):
        self.call("pane", "run", pane, command)

    def start(self, name: str, kind: str, pane: str, args: list[str], timeout_s: float = 150):
        self.call("agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", str(int(timeout_s * 1000)),
                  "--", *args, timeout=timeout_s + 60)


def session_id(agent: dict | None):
    ref = (agent or {}).get("agent_session")
    return ref.get("value") if isinstance(ref, dict) else None


# ------------------------------------------------------------------ file helpers

def git_dirty(root: Path) -> dict[str, tuple | None]:
    """Git-visible changed/untracked files -> (size, mtime_ns) or None if deleted."""
    p = subprocess.run(["git", "status", "--porcelain=v1", "-z", "-uall"], cwd=root, capture_output=True, timeout=300)
    if p.returncode:
        raise ProtocolError("git status failed")
    tokens = p.stdout.decode("utf-8", errors="surrogateescape").split("\0")
    paths, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        i += 1
        if len(t) < 4:
            continue
        paths.append(t[3:])
        if t[0] in "RC" and i < len(tokens):
            paths.append(tokens[i])
            i += 1
    out = {}
    for rel in paths:
        f = root / rel
        try:
            st = f.stat()
            out[rel] = (st.st_size, st.st_mtime_ns)
        except FileNotFoundError:
            out[rel] = None
    return out


def changed_paths(before: dict, after: dict) -> list[str]:
    return sorted(p for p in set(before) | set(after) if tuple(before.get(p) or ()) != tuple(after.get(p) or ()))


def sections(text: str) -> dict[str, str]:
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1).strip().upper()
            out[cur] = ""
        elif cur:
            out[cur] += line + "\n"
    return out


def allowed_globs(task_text: str) -> list[str]:
    body = sections(task_text).get("ALLOWED FILES", "")
    globs = []
    for line in body.splitlines():
        m = re.match(r"^\s*[-*]\s+`?([^`\s]+)`?", line)
        if m and not m.group(1).lower().startswith(("none", "n/a", "empty")):
            globs.append(m.group(1).replace("\\", "/"))
    return globs


def matches(path: str, pattern: str) -> bool:
    pattern = pattern.rstrip()
    return path == pattern or (pattern.endswith("/") and path.startswith(pattern)) or fnmatch.fnmatch(path, pattern)


# ------------------------------------------------------------------ the swarm

class Swarm:
    def __init__(self, root: Path, herdr, runner=None, clock=time.time, sleep=time.sleep):
        self.root, self.herdr = root.resolve(), herdr
        self.clock, self.sleep = clock, sleep
        self.runner = runner or self._run_logged
        self.dir = self.root / AGENT
        self.roster = load(self.dir / "roster.json")
        self.rt = self.dir / "runtime"

    # --- small state accessors
    def role(self, role: str) -> dict:
        return self.roster["roles"][role]

    def workflow(self) -> dict:
        return load(self.dir / "workflow.json")

    def save_workflow(self, wf: dict):
        atomic(self.dir / "workflow.json", encoded(wf))

    def dispatch(self) -> dict:
        p = self.dir / "dispatch.json"
        return load(p) if p.exists() else {"schema_version": 1, "status": "IDLE"}

    def save_dispatch(self, d: dict):
        atomic(self.dir / "dispatch.json", encoded(d))

    def rel(self, p: Path) -> str:
        return p.resolve().relative_to(self.root).as_posix()

    def next_task_id(self) -> str:
        nums = [int(m.group(1)) for d in ("tasks", "results", "archive") for p in (self.dir / d).glob("T-*")
                if (m := re.match(r"T-(\d{5})", p.name))]
        return f"T-{(max(nums) + 1 if nums else 1):05d}"

    def halt(self, reason: str) -> dict:
        wf = self.workflow()
        wf.update({"status": "HUMAN_REVIEW_REQUIRED", "status_reason": reason})
        self.save_workflow(wf)
        return {"status": "HUMAN_REVIEW_REQUIRED", "reason": reason}

    # --- validation
    def validate_dispatch(self, d: dict) -> list[str]:
        errs = []
        if d.get("schema_version") != 1:
            errs.append("schema_version must be 1")
        st = d.get("status")
        if st not in ("PENDING", "IDLE", "HUMAN_REVIEW_REQUIRED", "COMPLETE"):
            return errs + [f"invalid status {st!r}"]
        if st != "PENDING":
            return errs
        tid, role = d.get("task_id", ""), d.get("role")
        if not TASK_RE.match(str(tid)):
            return errs + ["task_id must match T-NNNNN"]
        if role not in WORKER_ROLES:
            errs.append(f"role must be one of {WORKER_ROLES}")
        if d.get("task_file") != f"{AGENT}/tasks/{tid}.md":
            errs.append("task_file must be .agent/tasks/<task_id>.md")
        elif not (self.root / d["task_file"]).exists():
            errs.append("task_file does not exist")
        else:
            secs = sections((self.root / d["task_file"]).read_text(encoding="utf-8", errors="replace"))
            missing = [s for s in TASK_SECTIONS if s not in secs]
            if missing:
                errs.append(f"task file missing sections {missing}")
        if d.get("result_file") != f"{AGENT}/results/{tid}.md":
            errs.append("result_file must be .agent/results/<task_id>.md")
        elif (self.root / d["result_file"]).exists():
            errs.append("stale result: result_file already exists before delivery")
        if (self.dir / "archive" / f"{tid}.json").exists():
            errs.append("duplicate task_id: already archived")
        skills = d.get("skills", [])
        if not isinstance(skills, list) or not all(isinstance(s, str) for s in skills):
            errs.append("skills must be a list of names")
        else:
            for s in skills:
                if not (self.root / ".agents/skills" / s / "SKILL.md").exists():
                    errs.append(f"unknown skill {s}")
            if role == "SAGE" and (len(skills) != 1 or skills[0] not in self.role("SAGE")["skills_one_of"]):
                errs.append("SAGE tasks name exactly one of its skills_one_of")
        t1 = d.get("t1_argv")
        if t1 is not None and (not isinstance(t1, list) or not t1 or not all(isinstance(a, str) for a in t1)):
            errs.append("t1_argv must be null or a non-empty list of strings")
        j = d.get("full_run_justification")
        if j is not None and (not isinstance(j, str) or len(j.strip()) < 20):
            errs.append("full_run_justification must be null or a real justification")
        return errs

    def validate_result(self, d: dict) -> tuple[str | None, list[str]]:
        p = self.root / d["result_file"]
        if not p.exists():
            return None, ["result file missing"]
        text = p.read_text(encoding="utf-8", errors="replace")
        errs = []
        if not re.search(rf"^#\s*TASK:\s*{re.escape(d['task_id'])}\b", text, re.M):
            errs.append("result does not name its task")
        secs = sections(text)
        errs += [f"missing section {s}" for s in RESULT_SECTIONS if s not in secs]
        first = next((l.strip(" *`") for l in secs.get("STATUS", "").splitlines() if l.strip()), "")
        status = first.split()[0].upper() if first else None
        if status not in RESULT_STATUSES:
            errs.append(f"STATUS must be one of {RESULT_STATUSES}")
            status = None
        return status, errs

    def scope_violations(self, role: str, changed: list[str], task_text: str) -> list[str]:
        r = self.role(role)
        writable = r["may_write"] + self.roster["always_writable"]
        task_globs = allowed_globs(task_text)
        out = []
        for p in changed:
            if any(matches(p, x) for x in self.roster["protected_prefixes"]):
                out.append(f"{p}: protected reference path")
            elif not any(matches(p, x) for x in writable):
                out.append(f"{p}: outside {role} may_write")
            elif any(matches(p, x) for x in self.roster["production_source_prefixes"]):
                if not r["may_edit_production_source"]:
                    out.append(f"{p}: {role} may not edit production source")
                elif not any(matches(p, g) for g in task_globs):
                    out.append(f"{p}: not in the task's ALLOWED FILES")
        return out

    # --- agent turns
    def wait_settled(self, name: str, timeout_s: float) -> dict:
        end = self.clock() + timeout_s
        while True:
            a = self.herdr.agent(name)
            if a is None:
                raise HumanReview(f"agent {name} is not live in Herdr")
            if a["agent_status"] == "blocked":
                raise HumanReview(f"agent {name} is at a permission/question dialog; never answered automatically")
            if a["agent_status"] in ("idle", "done"):
                return a
            if self.clock() >= end:
                raise TimeoutError(name)
            self.sleep(2)

    def fresh_session(self, role: str) -> dict:
        r = self.role(role)
        name = r["agent_name"]
        before = self.wait_settled(name, 120)
        if before.get("agent") != r["kind"]:
            raise HumanReview(f"{name} hosts {before.get('agent')}, roster expects {r['kind']}")
        old = session_id(before)
        marker = r.get("reset_marker")
        self.herdr.prompt(name, r["reset_command"], wait=False)
        end = self.clock() + 90
        while self.clock() < end:
            self.sleep(1)
            a = self.herdr.agent(name)
            if a and a["agent_status"] in ("idle", "done"):
                sid = session_id(a)
                if marker:
                    # OpenCode: Herdr keeps the OLD session id after /new until the next message
                    # (observed 2026-09-25), so the welcome screen is the only reset evidence.
                    if marker in self.herdr.read(name):
                        return {"reset": "verified-welcome-screen", "old": old, "new": None}
                elif old is None or (sid and sid != old):
                    return {"reset": "verified" if old else "unverified-no-session-id", "old": old, "new": sid}
            if a and a["agent_status"] == "blocked":
                raise HumanReview(f"{name} blocked during session reset")
        raise HumanReview(f"{name} did not acknowledge {r['reset_command']} with a new session")

    def turn(self, role: str, text: str) -> str:
        r = self.role(role)
        budget = float(r["budget"]["minutes"]) * 60
        try:
            self.herdr.prompt(r["agent_name"], text, wait=True, timeout_s=budget)
            self.wait_settled(r["agent_name"], 60)
            return "settled"
        except (TimeoutError, HerdrError, subprocess.TimeoutExpired) as e:
            if isinstance(e, HerdrError) and e.code == "agent_blocked":
                raise HumanReview(f"{r['agent_name']} is at a permission/question dialog") from e
            if isinstance(e, HerdrError) and e.code not in ("timeout", "agent_prompt_stalled"):
                raise
            try:  # interrupt generation; never kill the harness
                self.herdr.send_keys(r["agent_name"], "esc")
            except HerdrError:
                pass
            return "timeout"

    def prompt_text(self, role: str, d: dict | None) -> str:
        r = self.role(role)
        if role == "SENTINEL":
            return (f"ROLE SENTINEL. Read {r['prompt_file']} and follow it exactly. Make ONE routing decision, "
                    "write .agent/dispatch.json (and the task file), validate it, then stop.")
        skills = ", ".join(f".agents/skills/{s}/SKILL.md" for s in d.get("skills", [])) or "none"
        return (f"ROLE {role}. Read {r['prompt_file']} and follow it exactly. Task: {d['task_file']}. "
                f"Skills to load: {skills}. Write ONLY {d['result_file']} (contract: .agent/templates/result.md). "
                f"Budget {r['budget']['minutes']} minutes. Then stop.")

    # --- hooks
    def _run_logged(self, argv: list[str], cwd: str, label: str, timeout: float) -> dict:
        out = f"audit/runs/swarm/{time.strftime('%Y%m%d-%H%M%S')}-{label}"
        p = subprocess.run([sys.executable, str(SCRIPTS / "run_logged.py"), "--root", str(self.root),
                            "--cwd", str(self.root / cwd), "--out", out, "--timeout", str(timeout), "--", *argv],
                           cwd=self.root,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout + 120)
        return {"exit_code": p.returncode, "receipt": f"{out}/receipt.json"}

    def forge_hooks(self, d: dict, changed: list[str]) -> dict:
        hooks = {}
        zig = [p for p in changed if p.endswith(".zig") and (self.root / p).exists()]
        if zig:
            hooks["zig_fmt"] = self.runner(["zig", "fmt", *[str(self.root / p) for p in zig]], ".",
                                           f"{d['task_id']}-fmt", 300)
        if d.get("t1_argv"):
            hooks["t1"] = self.runner(d["t1_argv"], "ecosys-ng", f"{d['task_id']}-t1", 1800)
        return hooks

    def failure_packet(self, d: dict, status: str, notes: list[str]) -> str | None:
        argv = [sys.executable, str(SCRIPTS / "make_failure_packet.py"), "--root", str(self.root),
                "--signature", d.get("signature") or f"{d['role']}:{d['task_id']}", "--task", d["task_id"],
                "--exact-error", f"task {status}: " + "; ".join(notes)[:300]]
        p = subprocess.run(argv, cwd=self.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        try:
            return json.loads(p.stdout).get("path")
        except ValueError:
            return None

    def queue_review(self, forge: dict, diff_sha: str) -> dict:
        tid = self.next_task_id()
        skill = forge.get("sage_skill") or "ecosys-process-science-parity"
        text = (f"# TASK: {tid}\n\n## ROLE\nSAGE\n\n## OBJECTIVE\nReview the production-source change made by "
                f"{forge['task_id']} against its hypothesis and packet; APPROVE, REVISE or REJECT.\n\n## INPUTS\n"
                f"- `.agent/tasks/{forge['task_id']}.md`\n- `.agent/tasks/{forge['task_id']}.hypothesis.md`\n"
                f"- `.agent/results/{forge['task_id']}.md`\n- `git diff HEAD -- ecosys-ng/src ecosys-ng/build.zig`\n\n"
                "## ALLOWED FILES\n- none (read-only review)\n\n## DO NOT\n- Edit source. Run builds or simulations.\n\n"
                f"## RELEVANT SKILLS\n- `.agents/skills/{skill}`\n\n## KNOWN FACTS\n- Source diff sha256 at queue time: "
                f"{diff_sha}\n\n## HYPOTHESIS\nsee inputs\n\n## SUCCESS CONDITION\nResult contains `VERDICT: <APPROVE|REVISE|REJECT>` "
                f"and `DIFF SHA256: {diff_sha}`.\n\n## STOP CONDITIONS\nSAGE budget.\n\n## OUTPUT FILE\n.agent/results/{tid}.md\n")
        atomic(self.dir / "tasks" / f"{tid}.md", text.encode())
        d = {"schema_version": 1, "status": "PENDING", "task_id": tid, "role": "SAGE",
             "task_file": f"{AGENT}/tasks/{tid}.md", "result_file": f"{AGENT}/results/{tid}.md",
             "skills": [skill], "t1_argv": None, "requires_sage_review": False, "full_run_justification": None,
             "review_of": forge["task_id"], "diff_sha256": diff_sha, "reason": "automatic review of production-source change"}
        self.save_dispatch(d)
        return d

    def read_review(self, d: dict) -> dict:
        text = (self.root / d["result_file"]).read_text(encoding="utf-8", errors="replace")
        v = re.search(r"VERDICT:\s*(APPROVE|REVISE|REJECT)\b", text)
        h = re.search(r"DIFF SHA256:\s*`?([0-9a-f]{64})", text)
        current = dirty_source_digest(self.root)["sha256"]
        bound = h.group(1) if h else None
        return {"verdict": v.group(1) if v else None, "bound_sha256": bound, "queued_sha256": d.get("diff_sha256"),
                "valid": bool(v and bound and bound == d.get("diff_sha256") == current)}

    # --- metrics / archive
    def metric(self, d: dict, role: str, status: str, started: float, over: bool, fr: tuple):
        r = self.role(role)
        row = [d.get("task_id") or "route", role, r["model"], status, f"{started:.0f}", f"{self.clock():.0f}",
               f"{self.clock() - started:.0f}", "", "", "", str(r["budget"]["minutes"]), str(over).lower(),
               str(fr[0]), str(fr[1])]
        with (self.dir / "metrics.csv").open("a", encoding="utf-8", newline="") as f:
            f.write(",".join(row) + "\n")

    def frontier(self) -> int:
        return load(self.dir / "frontier.json").get("verified_frontier", 0)

    # --- the cycle
    def step(self, require_approval=True) -> dict:
        with lock(self.dir / "locks" / "swarm.lock"):
            wf = self.workflow()
            if require_approval and not wf.get("autonomy_approved"):
                return {"status": "REFUSED", "reason": "autonomy_approved is false in .agent/workflow.json (plan GP1)"}
            if wf.get("status") == "HUMAN_REVIEW_REQUIRED":
                return {"status": "STOPPED", "reason": wf.get("status_reason")}
            try:
                inflight = self.rt / "inflight.json"
                if inflight.exists():
                    return self.recover(load(inflight))
                d = self.dispatch()
                if d.get("status") == "PENDING":
                    return self.deliver(d)
                return self.route()
            except HumanReview as e:
                return self.halt(str(e))

    def route(self) -> dict:
        prev_sha = digest(encoded(self.dispatch()))
        started = self.clock()
        atomic(self.rt / "before.json", encoded(git_dirty(self.root)))
        atomic(self.rt / "inflight.json", encoded({"kind": "route", "started": started,
                                                   "prev_dispatch_sha256": prev_sha}))
        self.fresh_session("SENTINEL")
        outcome = self.turn("SENTINEL", self.prompt_text("SENTINEL", None))
        return self.finish_route(outcome, started, prev_sha)

    def finish_route(self, outcome: str, started: float, prev_sha: str) -> dict:
        before = load(self.rt / "before.json")
        changed = changed_paths(before, git_dirty(self.root))
        d = self.dispatch()
        if digest(encoded(d)) == prev_sha:
            d = {**d, "status": "COMPLETE"}  # SENTINEL made no decision; treated as an invalid route
        task_text = ""
        if d.get("task_file") and (self.root / d["task_file"]).exists():
            task_text = (self.root / d["task_file"]).read_text(encoding="utf-8", errors="replace")
        violations = self.scope_violations("SENTINEL", changed, task_text)
        errs = self.validate_dispatch(d)
        fr = (self.frontier(), self.frontier())
        self.metric(d, "SENTINEL", "timeout" if outcome == "timeout" else d.get("status", "?"), started,
                    outcome == "timeout", fr)
        (self.rt / "inflight.json").unlink(missing_ok=True)
        if violations:
            raise HumanReview("SENTINEL wrote outside its lane: " + "; ".join(violations))
        wf = self.workflow()
        if errs or d.get("status") == "COMPLETE":
            wf["route_failures"] = wf.get("route_failures", 0) + 1
            self.save_workflow(wf)
            if wf["route_failures"] >= 2:
                raise HumanReview("SENTINEL produced no valid dispatch twice: " + "; ".join(errs or ["unchanged"]))
            return {"status": "ROUTE_INVALID", "errors": errs or ["dispatch unchanged"]}
        wf["route_failures"] = 0
        if d["status"] == "HUMAN_REVIEW_REQUIRED":
            self.save_workflow(wf)
            raise HumanReview(f"SENTINEL: {d.get('reason')}")
        if d["status"] == "IDLE":
            wf.update({"status": "IDLE", "status_reason": d.get("reason")})
            self.save_workflow(wf)
            return {"status": "IDLE", "reason": d.get("reason")}
        if d.get("full_run_justification"):
            wf.setdefault("full_run_justifications", []).append({"task_id": d["task_id"], "text": d["full_run_justification"]})
        wf.update({"status": "DISPATCHED", "task_id": d["task_id"], "worker": d["role"], "status_reason": d.get("reason")})
        self.save_workflow(wf)
        return {"status": "ROUTED", "task_id": d["task_id"], "role": d["role"]}

    def deliver(self, d: dict) -> dict:
        errs = self.validate_dispatch(d)
        if errs:
            raise HumanReview(f"invalid pending dispatch {d.get('task_id')}: " + "; ".join(errs))
        role = d["role"]
        started = self.clock()
        atomic(self.rt / "before.json", encoded(git_dirty(self.root)))
        # Scope is judged against the task AS DISPATCHED; an agent cannot widen it mid-turn.
        atomic(self.rt / "task.md", (self.root / d["task_file"]).read_bytes())
        # At-most-once: the intent is durable BEFORE any keystroke reaches the agent.
        atomic(self.rt / "inflight.json", encoded({"kind": "task", "task_id": d["task_id"], "role": role,
                                                   "started": started, "frontier_before": self.frontier()}))
        reset = self.fresh_session(role)
        outcome = self.turn(role, self.prompt_text(role, d))
        return self.collect(d, outcome, started, reset)

    def recover(self, inflight: dict) -> dict:
        if inflight["kind"] == "route":
            return self.finish_route("recovered", inflight["started"], inflight["prev_dispatch_sha256"])
        d = self.dispatch()
        if d.get("task_id") != inflight["task_id"]:
            raise HumanReview("inflight record and dispatch.json disagree; inspect before resuming")
        a = self.herdr.agent(self.role(d["role"])["agent_name"])
        if a and a["agent_status"] == "working":
            return {"status": "WAITING", "task_id": d["task_id"], "reason": "agent still working; no duplicate prompt"}
        # Never re-prompt: either the result exists, or the task ends STAGNATED.
        return self.collect(d, "recovered", inflight["started"], {"reset": "recovered"})

    def collect(self, d: dict, outcome: str, started: float, reset: dict) -> dict:
        role, tid = d["role"], d["task_id"]
        inflight = load(self.rt / "inflight.json") if (self.rt / "inflight.json").exists() else {}
        frozen = self.rt / "task.md"
        task_bytes = frozen.read_bytes() if frozen.exists() else (self.root / d["task_file"]).read_bytes()
        task_text = task_bytes.decode("utf-8", errors="replace")
        changed = changed_paths(load(self.rt / "before.json"), git_dirty(self.root))
        violations = self.scope_violations(role, changed, task_text)
        if (self.root / d["task_file"]).read_bytes() != task_bytes:
            violations.append(f"{d['task_file']}: task file changed during its own execution")
        status, rerrs = self.validate_result(d)
        notes = list(rerrs)
        if status is None:
            status = "STAGNATED" if outcome in ("timeout", "recovered") else "FAIL"
        prod = [p for p in changed if any(matches(p, x) for x in self.roster["production_source_prefixes"])]
        if prod and not (self.dir / "tasks" / f"{tid}.hypothesis.md").exists():
            violations.append("production source changed without .agent/tasks/<task>.hypothesis.md (spec section 15)")
        hooks, review = {}, None
        if role == "FORGE" and changed and not violations:
            hooks = self.forge_hooks(d, changed)
            if any(h.get("exit_code") for h in hooks.values()):
                status, notes = "FAIL", notes + [f"hook failed: {k}" for k, h in hooks.items() if h.get("exit_code")]
        if role == "SAGE" and d.get("review_of"):
            review = self.read_review(d) if (self.root / d["result_file"]).exists() else {"valid": False}
        packet = self.failure_packet(d, status, notes or [outcome]) if status in ("FAIL", "STAGNATED") else None
        wf = self.workflow()
        sig = d.get("signature") or f"{role}:{tid}"
        if status in ("FAIL", "STAGNATED"):
            wf.setdefault("failure_signatures", {})[sig] = wf.get("failure_signatures", {}).get(sig, 0) + 1
        record = {"dispatch": d, "outcome": outcome, "reset": reset, "result_status": status, "result_errors": rerrs,
                  "changed": changed, "violations": violations, "hooks": hooks, "review": review,
                  "failure_packet": packet, "ended": self.clock()}
        atomic(self.dir / "archive" / f"{tid}.json", encoded(record))
        self.metric(d, role, status, started, outcome == "timeout",
                    (inflight.get("frontier_before", self.frontier()), self.frontier()))
        self.save_dispatch({**d, "status": "COMPLETE", "result_status": status})
        wf.update({"status": "ROUTING", "task_id": tid, "worker": None})
        self.save_workflow(wf)
        (self.rt / "inflight.json").unlink(missing_ok=True)
        frozen.unlink(missing_ok=True)
        if violations:
            raise HumanReview(f"{tid} ({role}) scope violation, left in place for the user: " + "; ".join(violations))
        if role == "FORGE" and prod and status == "DONE":
            q = self.queue_review(d, dirty_source_digest(self.root)["sha256"])
            return {"status": "COLLECTED", "task_id": tid, "result_status": status, "review_queued": q["task_id"]}
        return {"status": "COLLECTED", "task_id": tid, "result_status": status, "failure_packet": packet}

    # --- gates
    def precommit(self) -> dict:
        cur = dirty_source_digest(self.root)
        if not cur["dirty"]:
            return {"status": "PASS", "reason": "no production-source change vs HEAD"}
        for p in sorted((self.dir / "archive").glob("T-*.json"), reverse=True):
            rec = load(p)
            rv = rec.get("review") or {}
            if rv.get("verdict") == "APPROVE" and rv.get("bound_sha256") == cur["sha256"]:
                return {"status": "PASS", "review_task": rec["dispatch"]["task_id"], "diff_sha256": cur["sha256"]}
        return {"status": "FAIL", "diff_sha256": cur["sha256"],
                "reason": "no SAGE APPROVE bound to the current source diff (any later change invalidates a review)"}

    # --- agent lifecycle
    def ensure_agents(self, start=False) -> dict:
        panes = {p.get("label"): p for p in self.herdr.panes()}
        report = {}
        for role, r in self.roster["roles"].items():
            pane = panes.get(r["pane_label"])
            if not pane:
                report[role] = "MISSING_PANE"
                continue
            a = self.herdr.agent(r["agent_name"])
            if a and a.get("pane_id") == pane["pane_id"] and a.get("agent") == r["kind"]:
                report[role] = "OK"
            elif pane.get("agent") == r["kind"]:
                self.herdr.rename(pane["pane_id"], r["agent_name"])
                report[role] = "RENAMED"
            elif start and any(s in SHELLS for s in self.herdr.foreground(pane["pane_id"])):
                self.launch(role, pane["pane_id"])
                report[role] = "STARTED"
            else:
                report[role] = "NOT_RUNNING" + ("" if start else " (use --start)")
        return report

    def launch(self, role: str, pane: str):
        r = self.role(role)
        fg = self.herdr.foreground(pane)
        env = (f"$env:ECOSYS_SWARM_ROLE='{role.lower()}'" if any(s in ("pwsh", "powershell") for s in fg)
               else f"export ECOSYS_SWARM_ROLE={role.lower()}")
        self.herdr.pane_run(pane, env)
        for attempt in range(15):  # the shell is briefly "busy" right after running the export
            self.sleep(1 + attempt * 0.5)
            try:
                self.herdr.start(r["agent_name"], r["kind"], pane, r["launch_args"])
                return
            except HerdrError as e:
                if e.code != "agent_pane_busy" or attempt == 14:
                    raise

    def relaunch(self, role: str) -> dict:
        r = self.role(role)
        a = self.herdr.agent(r["agent_name"])
        pane = a["pane_id"] if a else next(p["pane_id"] for p in self.herdr.panes() if p.get("label") == r["pane_label"])
        if a:
            if a["agent_status"] == "working":
                raise ProtocolError(f"{r['agent_name']} is working; refusing to relaunch")
            if r["kind"] == "claude":
                self.herdr.prompt(r["agent_name"], "/exit", wait=False)
            else:
                self.herdr.send_keys(r["agent_name"], "ctrl+c")
        end = self.clock() + 30
        while not any(s in SHELLS for s in self.herdr.foreground(pane)):
            if self.clock() > end:
                raise ProtocolError(f"{role}: shell did not return in pane {pane}")
            self.sleep(1)
        self.launch(role, pane)
        return {"status": "RELAUNCHED", "role": role, "pane": pane}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--session", help="Herdr session (default: roster herdr_session)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    e = sub.add_parser("ensure-agents")
    e.add_argument("--start", action="store_true", help="start roles whose pane is at a shell prompt")
    rl = sub.add_parser("relaunch")
    rl.add_argument("role", choices=["SENTINEL", "PATHFINDER", "FORGE", "SAGE"])
    sub.add_parser("validate-dispatch")
    dh = sub.add_parser("diff-hash")
    dh.add_argument("--task", help="informational; the hash covers the whole production-source diff")
    sub.add_parser("precommit")
    st = sub.add_parser("step")
    st.add_argument("--manual", action="store_true", help="one user-supervised step without autonomy approval")
    rn = sub.add_parser("run")
    rn.add_argument("--max-steps", type=int, default=50)
    rn.add_argument("--resume", action="store_true", help="required when an inflight turn exists")
    ap_ = sub.add_parser("approve")
    ap_.add_argument("--by", required=True)
    a = ap.parse_args()
    root = a.root.resolve()
    try:
        roster = load(root / AGENT / "roster.json")
        sw = Swarm(root, Herdr(a.session or roster["herdr_session"], root))
        if a.cmd == "status":
            out = {"workflow": sw.workflow(), "dispatch": sw.dispatch(),
                   "inflight": (sw.rt / "inflight.json").exists(), "frontier": sw.frontier()}
            try:
                out["agents"] = {r: (lambda x: x and {"status": x["agent_status"], "kind": x.get("agent"),
                                                      "pane": x.get("pane_id")})(sw.herdr.agent(v["agent_name"]))
                                 for r, v in roster["roles"].items()}
            except ProtocolError as err:
                out["agents"] = f"unavailable: {err}"
        elif a.cmd == "ensure-agents":
            out = sw.ensure_agents(a.start)
        elif a.cmd == "relaunch":
            out = sw.relaunch(a.role)
        elif a.cmd == "validate-dispatch":
            errs = sw.validate_dispatch(sw.dispatch())
            out = {"status": "VALID" if not errs else "INVALID", "errors": errs}
        elif a.cmd == "diff-hash":
            out = {"diff_sha256": dirty_source_digest(root)["sha256"], **dirty_source_digest(root)}
        elif a.cmd == "precommit":
            out = sw.precommit()
        elif a.cmd == "approve":
            wf = sw.workflow()
            wf.update({"autonomy_approved": True, "approved_by": a.by, "approved_unix": time.time()})
            if wf.get("status") == "AWAITING_USER":
                wf["status"] = "ROUTING"
            sw.save_workflow(wf)
            out = {"status": "APPROVED", "by": a.by}
        elif a.cmd == "step":
            out = sw.step(require_approval=not a.manual)
        else:
            if (sw.rt / "inflight.json").exists() and not a.resume:
                raise ProtocolError("an inflight turn exists; rerun with --resume (it is never re-prompted)")
            out, steps = {}, []
            for _ in range(a.max_steps):
                out = sw.step()
                steps.append(out)
                print(json.dumps(out, separators=(",", ":")), flush=True)
                if out["status"] in ("REFUSED", "STOPPED", "HUMAN_REVIEW_REQUIRED", "IDLE", "WAITING"):
                    break
            out = {"status": out.get("status"), "steps": len(steps)}
        out = out if isinstance(out, dict) else {"result": out}
        out.setdefault("limitations", LIMITATIONS)
        print(json.dumps(out, indent=2))
        return 0 if out.get("status") not in ("FAIL", "INVALID", "HUMAN_REVIEW_REQUIRED") else 1
    except (OSError, ValueError, KeyError, ProtocolError, subprocess.SubprocessError) as err:
        print(json.dumps({"status": "BLOCKED", "error": str(err)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
