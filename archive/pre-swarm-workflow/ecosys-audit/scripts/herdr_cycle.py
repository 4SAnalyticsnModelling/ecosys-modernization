# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Artifact-driven Herdr controller. No model calls except explicit task prompts.

No terminal scraping, commits, pushes, process kills, or automatic permission answers.
Only runs inside an inherited Herdr environment; integration failures fail closed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from workflow import (ROOT, ProtocolError, artifact, atomic, candidate, check_handoff,
                      close, consume_review, digest, encoded, inside, load, lock,
                      relative, review_path, runtime, save_state, state, task_dir,
                      verify_artifacts)

PROTOCOL = "ecosys-audit/WORKFLOW.md"
SCRIPT = "uv run ecosys-audit/scripts/workflow.py"


def require_herdr():
    if os.environ.get("HERDR_ENV") != "1" or not os.environ.get("HERDR_PANE_ID"):
        raise ProtocolError("Controller requires HERDR_ENV=1 and HERDR_PANE_ID; no external Herdr control")


def agent_info(value: dict) -> dict:
    """Herdr 0.9.1 agent get/rename uses result.agent.agent_status, not state.

    An unsupported envelope must fail explicitly, not look perpetually busy.
    Never collect unrelated nested `state` fields from an arbitrary JSON tree.
    """
    result = value.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("agent"), dict):
        raise ProtocolError("Unsupported Herdr agent_info envelope: expected result.agent")
    agent = result["agent"]
    if agent.get("agent_status") not in ("idle", "done", "working", "blocked", "unknown"):
        raise ProtocolError("Unsupported Herdr agent_info: missing/invalid result.agent.agent_status")
    return agent


class Herdr:
    def __init__(self, root: Path, session: str, timeout=3600, clock=time.monotonic, sleep=time.sleep):
        self.root, self.session, self.timeout = root, session, timeout
        self.clock, self.sleep = clock, sleep
        self.last_observation = {}
        self._reported_key = None
        self._reported_at = float("-inf")

    def observation(self, role, registration, agent):
        # Herdr frequently reports a live Pi as `unknown`; its own extension registration decides.
        settled = ("idle", "done", "unknown") if role == "reviewer" else ("idle", "done")
        ready = registration["activity"] == "idle" and agent["agent_status"] in settled
        record = {"status": "READY" if ready else "WAITING", "role": role,
                  "pane_id": registration["pane_id"], "session_id": registration["session_id"],
                  "registered_activity": registration["activity"], "agent_status": agent["agent_status"],
                  "pid": os.getpid(), "phase": state(self.root)["phase"], "time": time.time()}
        self.last_observation = record
        key = tuple(record[k] for k in ("status", "role", "session_id", "registered_activity", "agent_status", "phase"))
        changed = key != self._reported_key
        if changed or self.clock() - self._reported_at >= 30:
            atomic(runtime(self.root) / "controller-status.json", encoded(record))
            if changed:
                print(json.dumps(record, separators=(",", ":")), flush=True)
            self._reported_key, self._reported_at = key, self.clock()
        return ready

    def call(self, *args, timeout=30):
        require_herdr()
        p = subprocess.run(["herdr", "--session", self.session, *args], cwd=self.root,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        if p.returncode:
            # Never forward agent terminal content. CLI diagnostics only, bounded.
            # Herdr prints its JSON error envelope (e.g. agent_not_found) on stdout.
            raise ProtocolError(f"Herdr exit {p.returncode}: {p.stderr[:800]} {p.stdout[:400]}")
        try:
            value = json.loads(p.stdout)
            if not isinstance(value, dict) or value.get("ok") is False or value.get("error"):
                raise ProtocolError("Herdr returned an error envelope")
            return value
        except ValueError as e:
            raise ProtocolError("Expected Herdr JSON, refusing to infer success from terminal text") from e

    def live(self, role, pane_id):
        """Resolve by name, else by registered pane: Herdr loses pane names on restart."""
        try:
            return agent_info(self.call("agent", "get", role))
        except ProtocolError as e:
            if "agent_not_found" not in str(e) and "error envelope" not in str(e):
                raise
        agents = self.call("agent", "list").get("result", {}).get("agents", [])
        hits = [a for a in agents if isinstance(a, dict) and a.get("pane_id") == pane_id]
        if len(hits) != 1 or hits[0].get("agent_status") not in ("idle", "done", "working", "blocked", "unknown"):
            raise ProtocolError(f"{role}: no live Herdr agent at registered pane {pane_id}")
        try:  # Best effort: restore the name so later lookups and humans see it.
            self.call("agent", "rename", pane_id, role)
        except ProtocolError:
            pass
        return {**hits[0], "name": role}

    def registration(self, role):
        p = runtime(self.root) / f"{role}.json"
        if not p.exists():
            raise ProtocolError(f"{role} has not registered. Its project startup hook/extension must load.")
        a = load(p)
        agent = self.live(role, a.get("pane_id"))
        if a.get("role") != role or agent.get("name") != role or agent.get("pane_id") != a.get("pane_id"):
            raise ProtocolError(f"{role} registration does not match its live named pane")
        expected_kind = {"editor": "claude", "reviewer": "pi"}[role]
        if agent.get("agent") != expected_kind:
            raise ProtocolError(f"{role} pane does not contain the expected {expected_kind} harness")
        if not agent.get("cwd") or Path(agent["cwd"]).resolve() != self.root.resolve():
            raise ProtocolError(f"{role} is not in the expected project directory")
        ref = agent.get("agent_session")
        sid = a.get("session_id")
        if not isinstance(sid, str) or not sid:
            raise ProtocolError(f"{role} has no native session identity to verify")
        if ref is None and role == "reviewer":
            # Herdr 0.9.1 often cannot see Pi's session after /new; the Pi extension's
            # registration (same pane, same cwd, pi harness) is then the only identity source.
            ref = {"agent": "pi", "kind": "id", "value": sid}
        if not isinstance(ref, dict):
            raise ProtocolError(f"{role} has no native session identity to verify")
        value = ref.get("value")
        filename = value.replace("\\", "/").rsplit("/", 1)[-1] if isinstance(value, str) else ""
        matches = ((ref.get("kind") == "id" and value == sid) or
                   (ref.get("kind") == "path" and (filename == sid + ".jsonl" or filename.endswith("_" + sid + ".jsonl"))))
        if ref.get("agent") != expected_kind or not matches:
            raise ProtocolError(f"{role} native session disagrees with its registration; refuse stale identity")
        if a.get("activity") not in ("idle", "working"):
            raise ProtocolError(f"{role} has an invalid native activity registration")
        return a, agent

    def idle(self, role):
        a, agent = self.registration(role)
        # Both native integration and Herdr must agree before dispatch/reset.
        ready = self.observation(role, a, agent)
        if agent["agent_status"] == "blocked":
            raise ProtocolError(f"{role} is at a permission/question dialog; never answer it automatically")
        return ready

    def wait_idle(self, role):
        end = self.clock() + self.timeout
        unknown_since = None
        while self.clock() < end:
            if self.idle(role):
                return
            if self.last_observation.get("agent_status") == "unknown":
                if unknown_since is None:
                    unknown_since = self.clock()
                if self.clock() - unknown_since >= 15:
                    raise ProtocolError(f"{role} remained unknown to Herdr for 15 seconds; inspect integration, not the science")
            else:
                unknown_since = None
            self.sleep(2)
        raise ProtocolError(f"{role} did not settle; no duplicate prompt or destructive reset was sent")

    def prompt(self, role, prompt):
        self.wait_idle(role)
        # Durable at-most-once dispatch intent. A crash between intent and send is ambiguous.
        a, _ = self.registration(role)
        record = {"role": role, "session_id": a["session_id"], "phase": state(self.root)["phase"],
                  "task": state(self.root).get("task"), "prompt_sha256": digest(prompt.encode()),
                  "status": "dispatching", "time": time.time()}
        path = runtime(self.root) / "dispatch.json"
        atomic(path, encoded(record))
        try:
            self.call("agent", "prompt", role, prompt, "--wait", "--timeout", str(int(self.timeout * 1000)),
                      timeout=self.timeout + 30)
            self.wait_idle(role)
        except (ProtocolError, subprocess.SubprocessError):
            atomic(path, encoded({**record, "status": "ambiguous"}))
            raise
        atomic(path, encoded({**record, "status": "settled"}))

    def rotate(self, role, closure):
        verify_artifacts(self.root, [closure["handoff"], closure["review"]])
        check_handoff((self.root / "audit/handoff.md").read_bytes())
        task = load(task_dir(self.root, closure["task"]) / "task.json")
        if candidate(self.root, task["spec"]["scope"])["sha256"] != closure["candidate_sha256"]:
            raise ProtocolError("Candidate changed after closure; do not discard uncheckpointed work")
        self.wait_idle(role)
        before, _ = self.registration(role)
        intent_path = runtime(self.root) / f"rotation-{role}.json"
        prior = load(intent_path) if intent_path.exists() else None
        closure_id = digest(encoded(closure))
        if prior and prior.get("closure_id") == closure_id:
            if before["session_id"] != prior["old_session_id"]:
                return  # reset completed before controller crashed; never clear again
            raise ProtocolError(f"{role} has an unacknowledged reset intent; no blind reset retry")
        if before["session_id"] != closure["sessions"][role]:
            raise ProtocolError(f"{role} now hosts a different conversation; refusing to clear unrelated context")
        atomic(intent_path, encoded({"closure_id": closure_id, "old_session_id": before["session_id"]}))
        self.call("agent", "prompt", role, "/clear" if role == "editor" else "/new")
        end = self.clock() + 90
        while self.clock() < end:
            try:
                after, _ = self.registration(role)
                if after["session_id"] != before["session_id"] and self.idle(role):
                    return
            except ProtocolError as e:
                # Hook registration and Herdr's session reference update at different
                # times after /clear; a transient disagreement is not a stale identity.
                if "native session disagrees" not in str(e):
                    raise
            self.sleep(1)
        raise ProtocolError(f"{role} reset not acknowledged with a NEW session ID; no task prompt sent")


def kickoff(root):
    return (f"Resume the autonomous ecosys audit under {PROTOCOL}. Read only audit/handoff.md, "
            "the shared contract/evidence guide if absent from context, and the relevant issue/skills. "
            "Preserve any unfinished work from this conversation and read audit/reviews/carry-forward.md if present. "
            "Carry unresolved findings and owned-process state into the current checkpoint before rotation. "
            "Select ONE bounded, currently unblocked question. Preserve dirty work. Create its spec, call "
            f"`{SCRIPT} begin --from <spec.json>`, do the focused work, checkpoint and seal. "
            "Do not run the whole-release checklist each turn. If no safe new work exists, use workflow.py park "
            "with an evidence-backed reason. Never replay a failed hypothesis unchanged. "
            "The external controller owns peer dispatch and session rotation; do not start a second loop. "
            "Return <=200 words and artifact paths, then yield.")


def review_prompt(s):
    return (f"Independent reviewer-only task. Read {PROTOCOL} and `{s['packet']}` "
            f"(SHA256 {s['packet_sha256']}). Inspect relevant original source and raw evidence independently. "
            "Review ONLY this package and its dependent interfaces, not all release gates. "
            "Before your first receipt, preserve prior unresolved findings/assignments in "
            "audit/reviews/carry-forward.md (explicitly state none if empty); include it in evidence. "
            "Do not clear outstanding prior work from memory without that durable record. "
            "Write only audit/reviews/ evidence; no source, state ledger, handoff, commits or pushes. "
            f"Submit `{SCRIPT} review --from <audit/reviews/result.json> --session-id <your PI_SESSION_ID>`. "
            "Use PASS/FAIL/BLOCKED bound to the packet hash; no approval strings. "
            "Findings need source/evidence anchors. New unrelated issues are recommendations for the lead's queue. "
            "If tests are blocked, do not fabricate PASS. Return <=300 words and result path, then yield.")


def finish_prompt(s):
    return (f"Finalize only task {s['task']}. Read `{s['last_review']}`. "
            "If recovering into a new native editor session, reconcile the existing work and use workflow.py adopt --reason <recovery-record> first. "
            "Do not edit reviewed sources or rerun whole production. Preserve the verdict and unresolved findings; "
            "update audit/handoff.md through workflow.py checkpoint (<=6500 bytes), naming this task and review path, "
            "candidate, gates, dirty work, no outstanding owned processes, next bounded action, and evidence links. "
            f"Call `{SCRIPT} close`. A task PASS is not release approval. "
            "The controller will rotate both conversations after the durable receipt. Return <=150 words and yield.")


def controller(root: Path, client: Herdr, max_tasks=0):
    require_herdr()
    with lock(runtime(root) / "controller.lock"):
        done = 0
        while not max_tasks or done < max_tasks:
            # Especially on ensure from inside the lead's tool call: do not change
            # phase to planning until that initiating turn has actually yielded.
            client.wait_idle("editor")
            client.wait_idle("reviewer")
            s = state(root)
            dispatch = runtime(root) / "dispatch.json"
            if dispatch.exists() and load(dispatch)["status"] in ("dispatching", "ambiguous"):
                # A late completed receipt can be consumed; otherwise no blind re-submission.
                d = load(dispatch)
                client.wait_idle(d["role"])
                progressed = s["phase"] != d["phase"] or (s["phase"] == "review" and review_path(root, s).exists())
                if not progressed:
                    raise ProtocolError("Ambiguous prior dispatch with no completed receipt. Agent must reconcile existing work; no automatic replay.")
                atomic(dispatch, encoded({**d, "status": "reconciled-from-artifact"}))
            if s["phase"] == "parked":
                return {"status": "PARKED", "reason": s["reason"]}
            if s["phase"] == "closed":
                closure = load(inside(root, s["closure"]))
                # Persist each reset acknowledgement so controller restarts do not reset twice.
                rotation = s.get("rotated", [])
                for role in ("editor", "reviewer"):
                    if role not in rotation:
                        client.rotate(role, closure)
                        rotation.append(role)
                        save_state(root, {**s, "rotated": rotation})
                save_state(root, {"phase": "idle", "task": None, "last_closure": s["closure"]})
                done += 1
                continue
            if s["phase"] in ("idle", "planning"):
                save_state(root, {**s, "phase": "planning"})
                client.prompt("editor", kickoff(root))
                if state(root)["phase"] in ("planning", "editing"):
                    raise ProtocolError("Editor yielded without a sealed package/park receipt. Existing work preserved; resume it, not a new task.")
            elif s["phase"] == "editing":
                feedback = f"Read `{s['last_review']}`." if s.get("last_review") else "Recover the existing task from its files."
                client.prompt("editor", f"Continue ONLY existing task {s['task']}, revision {s['revision']}. {feedback} "
                              f"Follow {PROTOCOL}. If this is a new native editor session, reconcile old owned "
                              "processes/dirty work and use workflow.py adopt --reason <recovery-record>. "
                              "Address scoped findings; checkpoint and seal changed evidence. "
                              "Do not create a duplicate task. Stop owned processes and yield after the receipt.")
                if state(root)["phase"] == "editing":
                    raise ProtocolError("No new sealed package; preserving incomplete task without repeated prompting")
            elif s["phase"] == "review":
                if not review_path(root, s).exists():
                    client.prompt("reviewer", review_prompt(s))
                if not review_path(root, s).exists():
                    raise ProtocolError("Reviewer yielded without a valid receipt; no approval inferred")
                with lock(runtime(root) / "protocol.lock"):
                    consume_review(root)
            elif s["phase"] == "finalizing":
                client.prompt("editor", finish_prompt(s))
                if state(root)["phase"] != "closed":
                    raise ProtocolError("Missing closure/checkpoint: refusing to clear either conversation")
            else:
                raise ProtocolError(f"Unknown workflow phase: {s['phase']}")
        return {"status": "TASK_LIMIT", "closed_tasks": done}


def reviewer_pane(root: Path, client: Herdr) -> dict:
    """Pane/harness/cwd check for lead-driven dispatch. Session binding is enforced later by
    workflow.py review (registered Pi session, never an author); Herdr's Pi session reference
    lags after /new because Pi writes its session file lazily."""
    p = runtime(root) / "reviewer.json"
    if not p.exists():
        raise ProtocolError("reviewer has not registered; start Pi in its Herdr pane with the project extension")
    reg = load(p)
    agent = client.live("reviewer", reg.get("pane_id"))
    if agent.get("agent") != "pi" or not agent.get("cwd") or Path(agent["cwd"]).resolve() != root.resolve():
        raise ProtocolError("reviewer pane does not host Pi in this project")
    if agent["agent_status"] == "blocked":
        raise ProtocolError("reviewer is at a permission/question dialog; never answer it automatically")
    return {**reg, "agent_status": agent["agent_status"]}


def lead_peer(root: Path, client: Herdr, wait: int = 540) -> dict:
    """Lead-driven review round for a lead that never idles (e.g. a /goal stop hook).

    Dispatches the packet to Pi at most once, blocks WITHOUT model calls until Pi's receipt,
    consumes it and returns a small verdict. Re-invoke after PENDING; it never re-sends.
    """
    require_herdr()
    with lock(runtime(root) / "controller.lock"):
        s = state(root)
        if s["phase"] != "review":
            return {"status": "NOT_IN_REVIEW", "phase": s["phase"]}
        path = runtime(root) / "dispatch.json"
        d = load(path) if path.exists() else {}
        sent = (d.get("role") == "reviewer" and d.get("packet_sha256") == s["packet_sha256"]
                and d.get("status") in ("sent", "dispatching"))
        if not review_path(root, s).exists() and not sent:
            reg = reviewer_pane(root, client)
            if reg["activity"] != "idle" or reg["agent_status"] == "working":
                return {"status": "REVIEWER_BUSY", "next": "re-run peer later; nothing was sent"}
            prompt = review_prompt(s)
            d = {"role": "reviewer", "session_id": reg["session_id"], "phase": "review", "task": s["task"],
                 "revision": s["revision"], "packet_sha256": s["packet_sha256"],
                 "prompt_sha256": digest(prompt.encode()), "status": "dispatching", "time": time.time()}
            atomic(path, encoded(d))
            client.call("agent", "prompt", reg["pane_id"], prompt)
            d = {**d, "status": "sent"}
            atomic(path, encoded(d))
        end = client.clock() + wait
        idle_since = None
        while not review_path(root, s).exists():
            if client.clock() >= end:
                return {"status": "PENDING", "task": s["task"], "next": "re-run peer; dispatch is not repeated"}
            reg = reviewer_pane(root, client)
            yielded = ((reg["activity"] == "idle" and reg.get("updated", 0) > d["time"] + 1)
                       or (reg["agent_status"] in ("idle", "done") and time.time() - d["time"] > 90))
            idle_since = (idle_since or client.clock()) if yielded else None
            if idle_since is not None and client.clock() - idle_since >= 30:
                atomic(path, encoded({**d, "status": "ambiguous"}))
                raise ProtocolError("Reviewer yielded without a receipt; inspect audit/reviews/, do not re-send blindly")
            client.sleep(5)
        with lock(runtime(root) / "protocol.lock"):
            new = consume_review(root)
        atomic(path, encoded({**d, "status": "settled"}))
        r = load(review_path(root, s))
        return {"status": "REVIEWED", "verdict": r["verdict"], "findings": len(r["findings"]),
                "review": relative(root, review_path(root, s)), "phase": new["phase"]}


def lead_next(root: Path, client: Herdr) -> dict:
    """After close: give Pi a fresh conversation (/new) and return the lane to idle.

    The lead is not /clear-ed (it is mid-turn); it relies on its own compaction and the
    small checkpoint. Refuses unless the closure receipt and handoff are still valid."""
    require_herdr()
    with lock(runtime(root) / "controller.lock"):
        s = state(root)
        if s["phase"] != "closed":
            return {"status": "NOT_CLOSED", "phase": s["phase"]}
        closure = load(inside(root, s["closure"]))
        verify_artifacts(root, [closure["handoff"], closure["review"]])
        check_handoff((root / "audit/handoff.md").read_bytes())
        reg = reviewer_pane(root, client)
        rotated = False
        if reg["activity"] == "idle" and reg["agent_status"] != "working":
            client.call("agent", "prompt", reg["pane_id"], "/new")
            rotated = True
        save_state(root, {"phase": "idle", "task": None, "last_closure": s["closure"],
                          "note": "lead-driven close; editor not cleared" + ("" if rotated else "; reviewer busy, not rotated")})
        return {"status": "IDLE", "reviewer_rotated": rotated}


def ensure(root: Path, session: str):
    require_herdr()
    try:
        with lock(runtime(root) / "controller.lock"):
            pass
    except ProtocolError:
        return {"status": "ALREADY_RUNNING"}
    if state(root)["phase"] == "parked":
        return {"status": "PARKED", "reason": state(root)["reason"]}
    log = runtime(root) / "controller.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    kwargs = {"start_new_session": True}
    if os.name == "nt":
        # Break out of the tool's Windows Job so yielding the shell cannot kill the controller.
        kwargs = {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | 0x01000000}
    with log.open("ab") as output:
        p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--root", str(root),
                              "--session", session, "run"], cwd=root, stdin=subprocess.DEVNULL,
                             stdout=output, stderr=output, **kwargs)
    return {"status": "STARTED", "pid": p.pid, "log": relative(root, log),
            "next": "Yield at a durable task boundary; controller waits for idle, never interrupts a turn."}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--session", default="ecosys-modernization")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ensure")
    run = sub.add_parser("run")
    run.add_argument("--max-tasks", type=int, default=0)
    run.add_argument("--timeout", type=int, default=3600)
    peer = sub.add_parser("peer", help="lead-driven: dispatch the sealed packet to Pi and wait for its receipt")
    peer.add_argument("--wait", type=int, default=540, help="seconds to block; keep below the tool timeout")
    sub.add_parser("next", help="lead-driven: after close, /new the reviewer and return the lane to idle")
    args = ap.parse_args()
    root = args.root.resolve()
    try:
        if args.cmd == "ensure":
            result = ensure(root, args.session)
        elif args.cmd == "peer":
            result = lead_peer(root, Herdr(root, args.session), args.wait)
        elif args.cmd == "next":
            result = lead_next(root, Herdr(root, args.session))
        else:
            result = controller(root, Herdr(root, args.session, args.timeout), args.max_tasks)
        print(json.dumps(result, separators=(",", ":")), flush=True)
        return 0
    except (ProtocolError, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        result = {"status": "BLOCKED", "reason": str(e), "state": state(root), "time": time.time()}
        atomic(runtime(root) / "controller-status.json", encoded(result))
        print(json.dumps(result, separators=(",", ":")), file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
