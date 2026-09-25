# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Local, model-free task/checkpoint protocol. Not a scientific gate or sandbox.

RETIRED (2026-09-25): the begin/seal/review/close/checkpoint CLI and the editor/reviewer lane
belong to the old Claude-lead / Pi-reviewer workflow (archive/pre-swarm-workflow/). Do not use
them for new work. The 4-agent swarm (.agent/, swarm_wrapper.py) imports only the file helpers
here: atomic, immutable, lock, load, encoded, digest, file_digest, inside, relative, archive.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HANDOFF_LIMIT = 6500  # bytes, NOT a tokenizer estimate
PACKET_LIMIT = 16000
HANDOFF = "audit/handoff.md"
LIMITATIONS = "Bookkeeping and hash freshness only; not scientific approval or an OS security sandbox."


class ProtocolError(Exception):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def encoded(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def inside(root: Path, value: str) -> Path:
    p = (root / value).resolve()
    if not p.is_relative_to(root.resolve()):
        raise ProtocolError(f"Path escapes project: {value}")
    return p


def only_keys(obj: dict, allowed: set[str]):
    extra = set(obj) - allowed
    if extra:
        raise ProtocolError(f"Unexpected protocol fields: {sorted(extra)}")


def relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def atomic(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".workflow-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        # Windows: a scanner/indexer can briefly hold the target open right after a
        # previous write; os.replace then fails with WinError 5. Retry, bounded.
        for attempt in range(20):
            try:
                os.replace(name, path)
                break
            except PermissionError:
                if os.name != "nt" or attempt == 19:
                    raise
                time.sleep(0.05 * (attempt + 1))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def immutable(path: Path, data: bytes):
    # D: on the deployment host does not support hard links. Serialize cooperating
    # publishers, check existence under the lock, then publish a complete temp file
    # with same-directory atomic replacement. Direct filesystem writes are not a sandbox.
    path.parent.mkdir(parents=True, exist_ok=True)
    with lock(path.parent / ".workflow-publish.lock"):
        if path.exists():
            if path.read_bytes() != data:
                raise ProtocolError(f"Refusing to overwrite evidence: {path}")
            return
        atomic(path, data)


@contextlib.contextmanager
def lock(path: Path):
    """Kernel-held lock; crash releases it, no stale PID deletion or unsafe takeover."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as f:
        f.seek(0, 2)
        if not f.tell():
            f.write(b"0")
            f.flush()
        f.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise ProtocolError("Another workflow process owns this lane") from e
        try:
            yield
        finally:
            f.seek(0)
            if os.name == "nt":
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def archive(root: Path, path: Path) -> dict:
    data = path.read_bytes()
    sha = digest(data)
    target = root / "audit/history" / f"{path.stem}-{sha}.md"
    immutable(target, data)
    return {"path": relative(root, target), "sha256": sha, "bytes": len(data)}


def check_handoff(data: bytes):
    if len(data) > HANDOFF_LIMIT:
        raise ProtocolError(f"Handoff exceeds {HANDOFF_LIMIT} bytes; move details to issue/history records")
    text = data.decode("utf-8-sig")
    for heading in ("## Candidate", "## Gates", "## Active work", "## Next action", "## Recovery"):
        if heading not in text:
            raise ProtocolError(f"Handoff missing {heading}")


def checkpoint(root: Path, source: Path, expected: str) -> dict:
    new = source.read_bytes()
    check_handoff(new)
    path = root / "audit/handoff.md"
    with lock(root / "audit/workflow/runtime/checkpoint.lock"):
        before = path.read_bytes()
        if digest(before) != expected:
            raise ProtocolError("Handoff changed concurrently. Re-read current checkpoint; do not overwrite it.")
        old = archive(root, path)
        # Recheck after archiving to catch non-cooperating writers.
        if path.read_bytes() != before:
            raise ProtocolError("Concurrent handoff writer detected after archive")
        atomic(path, new)
    return {"handoff_sha256": digest(new), "archived": old}


def artifact(root: Path, value: str) -> dict:
    p = inside(root, value)
    if not p.is_file():
        raise ProtocolError(f"Missing artifact: {value}")
    return {"path": relative(root, p), "sha256": file_digest(p)}


def verify_artifacts(root: Path, items):
    if not isinstance(items, list):
        raise ProtocolError("Artifact list required")
    for a in items:
        if not isinstance(a, dict) or artifact(root, a["path"]) != a:
            raise ProtocolError(f"Stale artifact: {a}")


def git(root: Path, *args: str) -> bytes:
    p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, timeout=60)
    if p.returncode:
        raise ProtocolError(p.stderr.decode(errors="replace")[:1000])
    return p.stdout


def candidate(root: Path, scope: list[str]) -> dict:
    """Hash declared files + tracked/unignored source/config in the four trees.

    This is an operational invalidation guard, not a replacement for snapshot.py.
    Generated/ignored artifacts are excluded and scope completeness needs review.
    """
    tracked = set()
    for tree in ("f77src", "f77example", "ecosys-ng", "ecosys-ng-prod-examples"):
        if not (root / tree).exists():
            continue
        # -C supports nested repositories as well as the shared outer repository.
        for raw in git(root / tree, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0"):
            if raw:
                tracked.add(relative(root, root / tree / os.fsdecode(raw)))
    for name in scope:
        inside(root, name)  # explicit paths cannot escape the project
    tracked.update(scope)
    files = {}
    for name in sorted(tracked):
        # Preserve link identity from Git's lexical path; do not resolve it away.
        p = root / name
        if p.is_symlink():
            # Link identity plus frozen target bytes; external links need the baseline manifest.
            files[name] = {"link": os.readlink(p), "target_sha256": digest(p.read_bytes()) if p.is_file() else None}
        elif p.is_file():
            files[name] = digest(p.read_bytes())
        elif not p.exists():
            files[name] = None
        else:
            raise ProtocolError(f"Scope needs files, not directories: {name}")
    return {"sha256": digest(encoded(files)), "files": files,
            "limitation": "Operational source/deck and explicit-scope hash; ignored/generated files excluded. Not a release snapshot."}


def runtime(root: Path) -> Path:
    return root / "audit/workflow/runtime"


def state(root: Path) -> dict:
    p = runtime(root) / "state.json"
    return load(p) if p.exists() else {"phase": "idle", "task": None}


def save_state(root: Path, value: dict):
    atomic(runtime(root) / "state.json", encoded(value))


def task_dir(root: Path, task: str) -> Path:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", task):
        raise ProtocolError("Invalid task ID")
    return root / "audit/tasks" / task


def task_authors(root: Path, task: str) -> set[str]:
    folder = task_dir(root, task)
    authors = {load(folder / "task.json")["author_session"]}
    for p in folder.glob("author-transfer-*.json"):
        authors.add(load(p)["new_session"])
    return authors


def adopt(root: Path, author: str, reason: str) -> dict:
    s = state(root)
    if s["phase"] not in ("editing", "finalizing"):
        raise ProtocolError("Adopt only unfinished editor work, never a review or closed package")
    authors = task_authors(root, s["task"])
    if author in authors:
        return {"task": s["task"], "status": "ALREADY_OWNED"}
    if not reason.strip() or len(reason) > 1600:
        raise ProtocolError("Record bounded recovery reason and reconciled owned-process/dirty-work state")
    check_handoff((root / "audit/handoff.md").read_bytes())
    t = load(task_dir(root, s["task"]) / "task.json")
    record = {"task": s["task"], "previous_sessions": sorted(authors), "new_session": author,
              "reason": reason, "handoff": artifact(root, "audit/handoff.md"),
              "candidate_sha256": candidate(root, t["spec"]["scope"])["sha256"]}
    path = task_dir(root, s["task"]) / f"author-transfer-{digest(author.encode())}.json"
    immutable(path, encoded(record))
    return {"task": s["task"], "adoption": relative(root, path)}


def require_text(obj, key, limit=2500):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ProtocolError(f"{key}: nonempty string, maximum {limit} characters required")
    return value


def read_small(path: Path, limit=PACKET_LIMIT):
    if path.stat().st_size > limit:
        raise ProtocolError(f"Oversized protocol document: {path}")
    value = load(path)
    if not isinstance(value, dict):
        raise ProtocolError("JSON object required")
    return value


def begin(root: Path, spec: dict, author: str) -> dict:
    s = state(root)
    if s["phase"] not in ("idle", "planning"):
        raise ProtocolError(f"Cannot begin while phase={s['phase']}")
    only_keys(spec, {"issue", "question", "done_condition", "stop_condition", "scope"})
    for key in ("issue", "question", "done_condition", "stop_condition"):
        require_text(spec, key)
    scope = spec.get("scope")
    if not isinstance(scope, list) or not scope or len(scope) > 100 or any(not isinstance(x, str) for x in scope):
        raise ProtocolError("scope: 1-100 explicit file paths required")
    base = candidate(root, scope)
    fingerprint = digest(encoded({"issue": spec["issue"], "question": spec["question"], "candidate": base["sha256"]}))
    for p in (root / "audit/tasks").glob("*/task.json"):
        old = load(p)
        if old.get("fingerprint") == fingerprint:
            raise ProtocolError(f"Duplicate task/evidence: {p.parent.name}. Resume it or choose a NEW falsifiable question.")
    task = f"{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{uuid.uuid4().hex[:8]}"
    record = {"id": task, "author_session": author, "spec": spec, "base": base,
              "fingerprint": fingerprint, "created_utc": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    immutable(task_dir(root, task) / "task.json", encoded(record))
    save_state(root, {"phase": "editing", "task": task, "revision": 1})
    return {"task": task, "revision": 1, "base_sha256": base["sha256"]}


def seal(root: Path, result: dict, author: str) -> dict:
    s = state(root)
    if s["phase"] != "editing":
        raise ProtocolError("seal requires editing phase")
    t = load(task_dir(root, s["task"]) / "task.json")
    if author not in task_authors(root, s["task"]):
        raise ProtocolError("Only assigned author sessions may seal; after recovery use adopt with a durable reason")
    only_keys(result, {"status", "summary", "next_action", "open_processes", "evidence"})
    require_text(result, "summary", 1600)
    require_text(result, "next_action", 1600)
    if result.get("open_processes") != []:
        raise ProtocolError("Finish/reap task-owned processes before sealing (open_processes must be [])")
    if result.get("status") not in ("READY_FOR_REVIEW", "BLOCKED"):
        raise ProtocolError("Editor status is READY_FOR_REVIEW or BLOCKED, never a release PASS")
    evidence = result.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        raise ProtocolError("At least one actual evidence path required")
    refs = [artifact(root, x) for x in evidence]
    for ref in refs:
        if ref["path"] == HANDOFF or ref["path"].startswith("audit/workflow/"):
            raise ProtocolError(f"{ref['path']} is mutable workflow state, not sealable evidence; "
                                "seal records the handoff separately")
        if ref["path"].endswith("/receipt.json") and load(inside(root, ref["path"])).get("status") == "RUNNING":
            raise ProtocolError("A referenced command is still RUNNING; cannot seal")
    check_handoff((root / "audit/handoff.md").read_bytes())
    c = candidate(root, t["spec"]["scope"])
    packet = {"task": s["task"], "revision": s["revision"], "author_session": author,
              "author_sessions": sorted(task_authors(root, s["task"])), "spec": t["spec"], "base_sha256": t["base"]["sha256"], "candidate_sha256": c["sha256"],
              "result": result, "artifacts": refs, "handoff": artifact(root, "audit/handoff.md"),
              "limitations": LIMITATIONS}
    if len(encoded(packet)) > PACKET_LIMIT:
        raise ProtocolError("Review packet too large; link detailed evidence instead")
    if s["revision"] > 1:
        prev = load(task_dir(root, s["task"]) / f"packet-{s['revision'] - 1}.json")
        old_evidence = {a["sha256"] for a in prev["artifacts"]}
        new_evidence = {a["sha256"] for a in refs}
        if prev["candidate_sha256"] == c["sha256"] and old_evidence == new_evidence:
            raise ProtocolError("Unchanged candidate and evidence: renaming/copying logs does not justify another review")
    path = task_dir(root, s["task"]) / f"packet-{s['revision']}.json"
    immutable(path, encoded(packet))
    immutable(task_dir(root, s["task"]) / f"candidate-{s['revision']}.json", encoded(c))
    save_state(root, {**s, "phase": "review", "packet": relative(root, path), "packet_sha256": digest(path.read_bytes())})
    return {"packet": relative(root, path), "packet_sha256": digest(path.read_bytes())}


def review(root: Path, result: dict, reviewer: str) -> dict:
    s = state(root)
    if s["phase"] != "review":
        raise ProtocolError("review requires review phase")
    p = inside(root, s["packet"])
    if digest(p.read_bytes()) != s["packet_sha256"]:
        raise ProtocolError("Packet modified after sealing")
    packet = load(p)
    only_keys(result, {"packet_sha256", "verdict", "summary", "findings", "evidence", "open_processes"})
    if result.get("packet_sha256") != s["packet_sha256"]:
        raise ProtocolError("Review is not bound to this packet digest")
    if not reviewer or reviewer in task_authors(root, s["task"]):
        raise ProtocolError("Independent reviewer session required (including all prior author sessions)")
    if result.get("verdict") not in ("PASS", "FAIL", "BLOCKED"):
        raise ProtocolError("verdict must be PASS, FAIL or BLOCKED")
    require_text(result, "summary", 2500)
    if (not isinstance(result.get("findings"), list) or len(result["findings"]) > 20
            or any(not isinstance(x, str) or not x.strip() or len(x) > 1500 for x in result["findings"])):
        raise ProtocolError("findings: at most 20 nonempty strings, <=1500 chars each; link overflow")
    if result["verdict"] == "PASS" and result["findings"]:
        raise ProtocolError("PASS cannot carry unresolved findings")
    if result["verdict"] == "PASS" and packet["result"]["status"] == "BLOCKED":
        raise ProtocolError("A blocked editor package cannot be promoted to PASS")
    if result.get("open_processes") != []:
        raise ProtocolError("Finish task-owned review commands before submitting")
    verify_artifacts(root, packet["artifacts"])
    if candidate(root, packet["spec"]["scope"])["sha256"] != packet["candidate_sha256"]:
        raise ProtocolError("Source/deck/scope changed during review. Review invalid; no approval.")
    checks = result.get("evidence")
    if not isinstance(checks, list) or not checks:
        raise ProtocolError("Independent review evidence paths required")
    if "audit/reviews/carry-forward.md" not in checks:
        raise ProtocolError("Include audit/reviews/carry-forward.md so prior unresolved reviewer work survives rotation")
    own = [artifact(root, x) for x in checks]
    record = {"task": packet["task"], "revision": packet["revision"], "reviewer_session": reviewer,
              "candidate_sha256": packet["candidate_sha256"], **result, "review_artifacts": own,
              "limitations": LIMITATIONS}
    path = root / "audit/reviews" / f"{packet['task']}-r{packet['revision']}.json"
    immutable(path, encoded(record))
    # Reviewer's persistent write lane ends here. The controller consumes this receipt.
    return {"review": relative(root, path), "verdict": result["verdict"]}


def review_path(root: Path, s: dict) -> Path:
    return root / "audit/reviews" / f"{s['task']}-r{s['revision']}.json"


def consume_review(root: Path) -> dict:
    s = state(root)
    r = load(review_path(root, s))
    if r["packet_sha256"] != s["packet_sha256"] or r["task"] != s["task"] or r["revision"] != s["revision"]:
        raise ProtocolError("Review identity mismatch")
    packet = load(inside(root, s["packet"]))
    if digest(inside(root, s["packet"]).read_bytes()) != s["packet_sha256"]:
        raise ProtocolError("Packet changed")
    verify_artifacts(root, packet["artifacts"])
    verify_artifacts(root, r["review_artifacts"])
    if r.get("verdict") not in ("PASS", "FAIL", "BLOCKED") or r.get("open_processes") != []:
        raise ProtocolError("Invalid review verdict/process state")
    if r["verdict"] == "PASS" and (r.get("findings") != [] or packet["result"]["status"] == "BLOCKED"):
        raise ProtocolError("Cannot approve unresolved/blocked work")
    if not r.get("reviewer_session") or r["reviewer_session"] in task_authors(root, s["task"]):
        raise ProtocolError("Self review or missing reviewer identity")
    if candidate(root, packet["spec"]["scope"])["sha256"] != r["candidate_sha256"]:
        raise ProtocolError("Candidate changed since review")
    phase = "editing" if r["verdict"] == "FAIL" and s["revision"] < 2 else "finalizing"
    save_state(root, {**s, "phase": phase, "revision": s["revision"] + (phase == "editing"),
                      "last_review": relative(root, review_path(root, s))})
    return state(root)


def close(root: Path, author: str) -> dict:
    s = state(root)
    if s["phase"] != "finalizing":
        raise ProtocolError("close requires finalizing phase")
    t = load(task_dir(root, s["task"]) / "task.json")
    if author not in task_authors(root, s["task"]):
        raise ProtocolError("Only assigned author may close; after recovery use adopt with a durable reason")
    p = load(inside(root, s["packet"]))
    r = load(inside(root, s["last_review"]))
    # Finalization must rewrite the handoff to name the review, so it cannot also be held
    # byte-frozen as evidence; it is validated directly below (workflow-002).
    verify_artifacts(root, [a for a in p["artifacts"] if a.get("path") != HANDOFF])
    verify_artifacts(root, [a for a in r["review_artifacts"] if a.get("path") != HANDOFF])
    if candidate(root, t["spec"]["scope"])["sha256"] != p["candidate_sha256"]:
        raise ProtocolError("Finalization changed reviewed sources: a new review is required")
    h = (root / "audit/handoff.md").read_bytes()
    check_handoff(h)
    if s["task"] not in h.decode("utf-8-sig") or s["last_review"] not in h.decode("utf-8-sig"):
        raise ProtocolError("Checkpoint must identify this task and its review path before rotation")
    receipt = {"task": s["task"], "verdict": r["verdict"], "review": artifact(root, s["last_review"]),
               "sessions": {"editor": author, "reviewer": r["reviewer_session"]}, "handoff": artifact(root, "audit/handoff.md"), "candidate_sha256": p["candidate_sha256"],
               "release_status": "NOT_ASSESSED", "limitations": LIMITATIONS}
    immutable(task_dir(root, s["task"]) / "closure.json", encoded(receipt))
    save_state(root, {"phase": "closed", "task": s["task"], "closure": relative(root, task_dir(root, s["task"]) / "closure.json")})
    return receipt


def session_identity(root: Path, role: str, supplied: str | None = None) -> str:
    p = runtime(root) / f"{role}.json"
    if not p.exists():
        if supplied:
            return supplied
        raise ProtocolError(f"No {role} session registered; startup integration must run first")
    a = load(p)
    if supplied and supplied != a["session_id"]:
        raise ProtocolError("Session identity differs from registered lane")
    return a["session_id"]


def register(root: Path, role: str, session: str, activity: str):
    if os.environ.get("HERDR_ENV") != "1" or not os.environ.get("HERDR_PANE_ID"):
        return {"registered": False, "reason": "Not a Herdr pane"}
    data = {"session_id": session, "pane_id": os.environ["HERDR_PANE_ID"], "role": role,
            "activity": activity, "updated": time.time()}
    atomic(runtime(root) / f"{role}.json", encoded(data))
    return {"registered": True}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    c = sub.add_parser("checkpoint")
    c.add_argument("--from", dest="source", required=True, type=Path)
    c.add_argument("--expected-sha256", required=True)
    a = sub.add_parser("archive")
    a.add_argument("path")
    for name in ("begin", "seal", "review"):
        p = sub.add_parser(name)
        p.add_argument("--from", dest="source", type=Path, required=True)
        p.add_argument("--session-id")
    p = sub.add_parser("close")
    p.add_argument("--session-id")
    p = sub.add_parser("adopt")
    p.add_argument("--session-id")
    p.add_argument("--reason", required=True)
    r = sub.add_parser("register")
    r.add_argument("--role", choices=["editor", "reviewer"], required=True)
    r.add_argument("--session-id", required=True)
    r.add_argument("--activity", choices=["idle", "working"], default="idle")
    p = sub.add_parser("park")
    p.add_argument("--reason", required=True)
    p = sub.add_parser("unpark")
    p.add_argument("--evidence", required=True, help="New evidence file explaining why safe work can resume")
    args = ap.parse_args()
    root = args.root.resolve()
    try:
        if args.cmd == "status":
            result = {**state(root), "handoff": artifact(root, "audit/handoff.md"), "limitations": LIMITATIONS}
        elif args.cmd == "checkpoint":
            result = checkpoint(root, args.source, args.expected_sha256)
        elif args.cmd == "archive":
            result = archive(root, inside(root, args.path))
        elif args.cmd == "register":
            result = register(root, args.role, args.session_id, args.activity)
        else:
            with lock(runtime(root) / "protocol.lock"):
                if args.cmd == "unpark":
                    old = state(root)
                    if old["phase"] != "parked":
                        raise ProtocolError("unpark requires parked phase")
                    ref = artifact(root, args.evidence)
                    receipt = {"previous": old, "new_evidence": ref, "time": time.time()}
                    immutable(root / "audit/workflow" / f"resume-{uuid.uuid4().hex}.json", encoded(receipt))
                    result = {"phase": "idle", "task": None, "resume_evidence": ref}
                    save_state(root, result)
                elif args.cmd == "park":
                    if state(root)["phase"] not in ("idle", "planning"):
                        raise ProtocolError("Finish/checkpoint the active task before parking")
                    result = {"phase": "parked", "task": None, "reason": args.reason[:2000],
                              "handoff": artifact(root, "audit/handoff.md")}
                    save_state(root, result)
                else:
                    identity = session_identity(root, "reviewer" if args.cmd == "review" else "editor", args.session_id)
                    if args.cmd == "close":
                        result = close(root, identity)
                    elif args.cmd == "adopt":
                        result = adopt(root, identity, args.reason)
                    else:
                        result = globals()[args.cmd](root, read_small(args.source), identity)
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    except (ProtocolError, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        print(json.dumps({"error": str(e), "status": "BLOCKED"}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
