# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Cycle runner for the single-agent ecosys-ng Ottawa mission.

One autonomous agent (any harness, any model, no required name) owns the whole project and works in
**cycles**: plan -> work -> evidence & self-check -> independent verification (G7, fresh-context
read-only sub-agents) -> decide & record -> **commit & push** -> next cycle.

There is no judge and no ruling. Objective gates decide:
    G1 build   G2 regressions   G3 conservation   G4 traceability   G5 parity
    G6 no-forbidden-diff   G7 independent re-derivation   G8 pushed   G9 contained workspace

This tool is the agent's bookkeeping and enforcement helper. It opens the cycle record, tracks gate
results, scans the diff for forbidden changes, commits and pushes the completed cycle to
origin/main and verifies the push, and appends the metrics row. It never blocks a tool call and
never edits source code; it refuses to *close* a cycle whose gates are not recorded, because an
unclosed gate is how a science gap reaches main.

Protocol of record: .agent/protocol.md   Config: .agent/mission.json
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
AGENT_DIR = ROOT / ".agent"
MISSION_FILE = AGENT_DIR / "mission.json"
LEDGER_FILE = AGENT_DIR / "cycle.json"
CYCLES_DIR = AGENT_DIR / "cycles"
TEMPLATE_FILE = AGENT_DIR / "templates" / "cycle.md"
STATE_FILE = AGENT_DIR / "state.md"
FRONTIER_FILE = AGENT_DIR / "frontier.json"
METRICS_FILE = AGENT_DIR / "cycle-metrics.csv"
LOG_DIR = ROOT / "audit" / "runs" / "cycle-runner"
STATE_BEGIN, STATE_END = "<!-- runner:begin -->", "<!-- runner:end -->"
CYCLE_RE = re.compile(r"^cycle_(\d{5})\.md$")
GATE_IDS = ("G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9")
CLOSE_REQUIRED = ("G1", "G2", "G3", "G4", "G5", "G6", "G9")

# G6 candidates: added lines worth a second look. Flags are reviewed by the agent, not auto-fatal.
FORBIDDEN_PATTERNS = (
    (r"\bDEV-\d{3}\b", "DEV reference in the diff: must be registered in audit/intentional-deviations.md this cycle"),
    (r"unreachable\(\)", "new unreachable() (ReleaseFast undefined behaviour risk)"),
    (r"@setRuntimeSafety\s*\(\s*false", "runtime safety disabled"),
    (r"(?i)\b(tol[a-z_0-9]*|eps[a-z_0-9]*|conv_[a-z_0-9]*)\b\s*=\s*[0-9.eE+-]+", "tolerance assignment"),
    (r"(?i)\b(max[a-z_]*(iter|step|substep|attempt|ceiling))\b\s*=\s*[0-9]", "iteration/step ceiling assignment"),
    (r"(?i)\b(silent_retry|retry_count\s*=\s*0)\b", "possible silent retry"),
)


def now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sh(args: list[str], timeout: int | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=None)


def load_mission() -> dict:
    if MISSION_FILE.exists():
        return json.loads(MISSION_FILE.read_text(encoding="utf-8"))
    return {}


def mission_sync(mission: dict) -> tuple[str, str]:
    cfg = mission.get("sync", {})
    return cfg.get("remote", "origin"), cfg.get("branch", "main")


def load_ledger() -> dict:
    if LEDGER_FILE.exists():
        return json.loads(LEDGER_FILE.read_text(encoding="utf-8"))
    return {"schema_version": 1, "cycle": 0, "status": "IDLE", "gates": {}, "steps_done": []}


def save_ledger(ledger: dict) -> None:
    ledger["updated_utc"] = now()
    LEDGER_FILE.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def cycle_files() -> dict[int, Path]:
    out: dict[int, Path] = {}
    if CYCLES_DIR.is_dir():
        for path in CYCLES_DIR.glob("cycle_*.md"):
            m = CYCLE_RE.match(path.name)
            if m:
                out[int(m.group(1))] = path
    return out


def next_cycle_no() -> int:
    files = cycle_files()
    ledger_no = load_ledger().get("cycle") or 0
    return max([max(files), ledger_no] if files else [ledger_no]) + 1


def frontier() -> dict:
    if FRONTIER_FILE.exists():
        try:
            return json.loads(FRONTIER_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
    return {}


def git_state() -> dict:
    ahead = behind = 0
    dirty = len([l for l in sh(["git", "status", "--porcelain"]).stdout.splitlines() if l.strip()])
    branch = sh(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    head = sh(["git", "rev-parse", "HEAD"]).stdout.strip()[:12]
    origin_sha = ""
    out = sh(["git", "rev-parse", "origin/main"]).stdout.strip()
    if out:
        origin_sha = out[:12]
        ahead = int(sh(["git", "rev-list", "--count", "origin/main..HEAD"]).stdout.strip() or 0)
        behind = int(sh(["git", "rev-list", "--count", "HEAD..origin/main"]).stdout.strip() or 0)
    return {"branch": branch, "head": head, "origin_main": origin_sha, "ahead": ahead,
            "behind": behind, "dirty": dirty, "in_sync": bool(out) and ahead == 0 and behind == 0}


def touched_paths(ref: str = "origin/main") -> list[str]:
    out = sh(["git", "diff", "--name-only", ref]).stdout.splitlines()
    if not out:
        # Nothing differs from `ref` — the agent already committed and pushed by hand
        # (`./sync-main.sh push`), which is the protocol's own path. Fall back to the files the
        # last commit touched, best-effort, so the science-touch check still sees the cycle's
        # work instead of silently reading an empty tree. Measured 2026-10-15 (cycle 00001):
        # after the push, `git diff --name-only origin/main` is empty and the G7 requirement
        # would have evaluated against nothing. A cycle split over several commits is still
        # under-reported here — record G7 explicitly in that case.
        out = sh(["git", "show", "--name-only", "--pretty=format:", "HEAD"]).stdout.splitlines()
    untracked = sh(["git", "ls-files", "--others", "--exclude-standard"]).stdout.splitlines()
    kept = {line for line in untracked if line.startswith(("ecosys-ng/", "audit/", ".agent/cycles/"))}
    return sorted(set(out) | kept)


def write_state_block(ledger: dict) -> None:
    """Rewrite only the ledger block of state.md; the prose is curated by the agent."""
    if not STATE_FILE.exists():
        return
    block = (
        f"{STATE_BEGIN}\n"
        f"## Cycle {ledger.get('cycle', 0):05d} · {ledger.get('status', 'IDLE')} · {now()}\n"
        f"- Actor: single autonomous agent (any harness/model). Verification: gates G1-G9 (Zig 0.17.x build, repo-contained work) + read-only sub-agents.\n"
        f"- Target: {ledger.get('target') or '(unset)'}\n"
        "- Gates: " + (", ".join("{}={}".format(k, v.get("result", "-"))
                                 for k, v in sorted(ledger.get("gates", {}).items())) or "none recorded") + "\n"
        f"- Sync: {ledger.get('sync_status', 'unknown')} (push every completed cycle to origin/main)\n"
        f"- Next target: {ledger.get('next_target') or '(unset)'}\n"
        f"{STATE_END}\n"
    )
    text = STATE_FILE.read_text(encoding="utf-8")
    if STATE_BEGIN in text and STATE_END in text:
        head, rest = text.split(STATE_BEGIN, 1)
        tail = rest.split(STATE_END, 1)[1].lstrip("\n")
        text = head + block + "\n" + tail
    else:
        lines = text.splitlines(keepends=True)
        text = "".join(lines[:1]) + "\n" + block + "".join(lines[1:])
    STATE_FILE.write_text(text, encoding="utf-8")


def cmd_open(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    if ledger.get("status") not in (None, "IDLE", "PUSHED", "BLOCKED") and not args.force:
        print(f"[!] Cycle {ledger.get('cycle', 0):05d} is still open ({ledger.get('status')}). "
              f"Finish it, or pass --force after recording why in the cycle file.")
        return 1
    no = max(int(ledger.get("cycle", 0)), max(cycle_files(), default=0)) + 1
    CYCLES_DIR.mkdir(parents=True, exist_ok=True)
    path = CYCLES_DIR / f"cycle_{no:05d}.md"
    template = (TEMPLATE_FILE.read_text(encoding="utf-8") if TEMPLATE_FILE.exists()
                else "# Cycle {{CYCLE_ID}}\n\n- **Target**: {{TARGET}}\n- **Status**: PLANNING\n")
    path.write_text(template.replace("{{CYCLE_ID}}", f"{no:05d}")
                    .replace("{{DATE}}", now()[:10])
                    .replace("{{TARGET}}", args.target or "(fill in §0: one bounded, falsifiable question)"),
                    encoding="utf-8")
    ledger.update({"schema_version": 1, "cycle": no, "status": "PLANNING", "target": args.target or "",
                   "opened_utc": now(), "gates": {}, "steps_done": ["0 plan: record opened"],
                   "record": str(path.relative_to(ROOT)), "sync_status": "unknown",
                   "commit": None, "decisions": [], "metrics": {},
                   "next_target": ledger.get("next_target") or ""})
    save_ledger(ledger)
    write_state_block(ledger)
    print(f"[+] Opened cycle {no:05d}: {path.relative_to(ROOT)}")
    print("    Protocol: .agent/protocol.md §3. Cycle start ritual: ./sync-main.sh pull")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    if args.status:
        ledger["status"] = args.status
    if args.target is not None:
        ledger["target"] = args.target
    if args.next_target is not None:
        ledger["next_target"] = args.next_target
    if args.sync_status:
        ledger["sync_status"] = args.sync_status
    for note in args.note or []:
        ledger.setdefault("steps_done", []).append(f"{now()} {note}")
    for field in args.field or []:
        key, _, value = field.partition("=")
        ledger[key.strip()] = json.loads(value) if value.strip().startswith(("{", "[", '"')) else value
    save_ledger(ledger)
    write_state_block(ledger)
    print(f"[+] Cycle {ledger.get('cycle', 0):05d}: status={ledger.get('status')} "
          f"sync={ledger.get('sync_status')}")
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    gid = args.gate.upper()[:2]
    if gid not in GATE_IDS:
        print(f"[!] Unknown gate {args.gate}; expected G1-G9 (G9 = all work stayed inside the repository).")
        return 1
    if args.result.upper() == "FAIL" and not args.evidence:
        print("[!] A FAIL needs evidence (command + receipt path or file:line) so the fix is targeted.")
        return 1
    ledger.setdefault("gates", {})[gid] = {
        "result": args.result.upper(), "evidence": args.evidence or "", "at": now()}
    if args.result.upper() == "FAIL":
        ledger["status"] = "WORKING"
    save_ledger(ledger)
    write_state_block(ledger)
    print(f"[+] Cycle {ledger.get('cycle', 0):05d} gate {gid} = {args.result.upper()}")
    if args.result.upper() == "FAIL":
        print("    Fix it, or revert the diff and record the negative result (§3 rule). Never merge it.")
    return 0


def scan_diff(ref: str) -> list[str]:
    diff = sh(["git", "diff", "-U0", ref]).stdout + sh(["git", "diff", "-U0", "--staged"]).stdout
    flags: list[str] = []
    for line in diff.splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        body = line[1:]
        for pattern, why in FORBIDDEN_PATTERNS:
            if re.search(pattern, body):
                flags.append(f"    [{why}]\n      {body.strip()[:160]}")
                break
    return flags


def run_logged(name: str, cmd: list[str], timeout: int) -> tuple[int, str]:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        res = sh(cmd, timeout=timeout)
        out = (res.stdout or "") + (res.stderr or "")
    except Exception as e:  # timeout, missing binary
        res, out = type("R", (), {"returncode": 124})(), f"{type(e).__name__}: {e}"
    log = LOG_DIR / f"{name}-{_dt.datetime.now(_dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.log"
    log.write_text(f"$ {' '.join(cmd)}\nexit={getattr(res, 'returncode', '?')}\n\n{out}", encoding="utf-8")
    tail = "\n".join(out.strip().splitlines()[-6:])
    return int(getattr(res, "returncode", 1) or 0), f"{log.relative_to(ROOT)}\n{tail}"


def cmd_gates(args: argparse.Namespace) -> int:
    """Run the automatable part of the gate set; the agent records the judgement gates itself."""
    ledger = load_ledger()
    if args.build:
        code, detail = run_logged("build-tests", ["zig", "build", "test"], args.timeout)
        cmd_gate(argparse.Namespace(gate="G2", result="PASS" if code == 0 else "FAIL",
                                   evidence=f"zig build test exit={code}; log {detail.splitlines()[0]}"))
    if args.tests:
        code, detail = run_logged("pytest", ["uv", "run", "pytest", "ecosys-audit/tests", "-q"], args.timeout)
        print(f"[{'+' if code == 0 else '!'}] pytest exit={code}\n{detail}")
    flags = scan_diff(args.diff_ref)
    print(f"[{'+' if not flags else '!'}] G6 forbidden-diff scan vs {args.diff_ref}: "
          f"{len(flags)} candidate line(s) to justify")
    for flag in flags[:40]:
        print(flag)
    if args.record_g6:
        cmd_gate(argparse.Namespace(gate="G6", result="PASS" if not flags else "FAIL",
                                     evidence=f"cycle_runner gates --diff-ref {args.diff_ref}: "
                                            f"{len(flags)} flagged line(s); see cycle §2 justification"))
    print("\nRemaining gates are evidence gates: record each with "
          "`cycle_runner.py gate G3 --result PASS --evidence audit/runs/.../receipt.json`.")
    print("G7 requires a fresh-context read-only verifier sub-agent (.agent/briefs/verifier.md) for any "
          "science / solver / DEV / architecture change.")
    return 0


def cmd_commit(args: argparse.Namespace) -> int:
    cycle = load_ledger().get("cycle", 0)
    summary = args.message or f"cycle {cycle:05d}: (fill in what + why)"
    paths = args.paths or ["-A"]
    if sh(["git", "add", *paths]).returncode != 0:
        print("[!] git add failed")
        return 1
    status = sh(["git", "diff", "--cached", "--name-only"]).stdout.strip()
    if not status:
        print("[-] Nothing staged: no commit made.")
        return 0
    res = sh(["git", "commit", "-m", f"cycle {cycle:05d}: {summary}"], timeout=180)
    print(res.stdout[-400:] or res.stderr[-400:])
    return res.returncode


def cmd_push(args: argparse.Namespace) -> int:
    remote, branch = mission_sync(load_mission())
    if sh(["git", "status", "--porcelain"]).stdout.strip() and not args.allow_dirty:
        print("[!] Working tree is dirty: commit the cycle first (or pass --allow-dirty to push only "
              "what is already committed).")
        return 1
    pull = sh(["git", "pull", "--rebase", "--autostash", remote, branch], timeout=600)
    if pull.returncode != 0:
        print(f"[!] Rebase onto {remote}/{branch} failed — resolve or `git rebase --abort`, then record "
              f"the conflict in .agent/backlog.md:\n{(pull.stdout + pull.stderr)[-600:]}")
        return 1
    push = sh(["git", "push", remote, branch], timeout=600)
    ledger = load_ledger()
    if push.returncode != 0:
        ledger["sync_status"] = "PENDING"
        save_ledger(ledger)
        write_state_block(ledger)
        print(f"[!] Push failed; commit is kept and flagged PENDING, retry at the next cycle start.\n"
              f"{(push.stdout + push.stderr)[-600:]}")
        return 1
    head = sh(["git", "rev-parse", "HEAD"]).stdout.strip()
    on_remote = sh(["git", "rev-parse", f"{remote}/{branch}"]).stdout.strip()
    synced = head == on_remote
    ledger["sync_status"] = "PUSHED" if synced else "MISMATCH"
    ledger["commit"] = head[:12]
    save_ledger(ledger)
    write_state_block(ledger)
    print(f"[{'+' if synced else '!'}] {remote}/{branch} {'in sync' if synced else 'MISMATCH'}: "
          f"HEAD={head[:12]} {remote}/{branch}={on_remote[:12]}")
    return 0 if synced else 1


def append_metrics(ledger: dict) -> None:
    cols = load_mission().get("metrics_columns") or ["cycle", "date", "status", "frontier_hour"]
    exists = METRICS_FILE.exists()
    metrics = dict(ledger.get("metrics") or {})
    metrics.setdefault("cycle", f"{ledger.get('cycle', 0):05d}")
    metrics.setdefault("date", now()[:10])
    metrics.setdefault("sync_status", ledger.get("sync_status", ""))
    fr = frontier()
    metrics.setdefault("frontier_hour", fr.get("simulation_frontier", ""))
    with METRICS_FILE.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        if not exists:
            writer.writeheader()
        writer.writerow(metrics)


def cmd_metrics(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    metrics = ledger.setdefault("metrics", {})
    for field in args.set or []:
        key, _, value = field.partition("=")
        metrics[key.strip()] = value.strip()
    save_ledger(ledger)
    if args.append:
        append_metrics(ledger)
        print(f"[+] Metrics row appended to {METRICS_FILE.relative_to(ROOT)}")
    else:
        print(json.dumps(metrics, indent=2, sort_keys=True))
    return 0


def cmd_close(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    gates = ledger.get("gates", {})
    missing = [g for g in CLOSE_REQUIRED if g not in gates]
    failed = [g for g in CLOSE_REQUIRED if gates.get(g, {}).get("result") == "FAIL"]
    science_touch = any(p.startswith(("ecosys-ng/src/", "ecosys-ng/build.zig")) for p in touched_paths())
    if science_touch and "G7" not in gates:
        missing.append("G7 (change touches production source: independent verification required)")
    blockers = []
    if missing:
        blockers.append("gates not recorded: " + ", ".join(missing))
    if failed:
        blockers.append("gates FAILED: " + ", ".join(failed))
    if blockers and not args.force:
        print("[!] Cannot close cycle "
              f"{ledger.get('cycle', 0):05d}: " + "; ".join(blockers))
        print("    Record evidence with `cycle_runner.py gate`, or fix/revert the diff. "
              "`--force --reason '...'` is only for a reverted negative result.")
        return 1
    if args.force and not args.reason:
        print("[!] --force requires --reason (recorded in the cycle file and the ledger).")
        return 1
    cycle = ledger.get("cycle", 0)
    summary = args.summary or ledger.get("target") or "work completed"
    ledger["status"] = "DECIDED"
    ledger.setdefault("steps_done", []).append(
        f"{now()} close: {summary}" + (f" (forced: {args.reason})" if args.force else ""))
    if args.force:
        ledger["force_reason"] = args.reason
    save_ledger(ledger)
    if args.dry_run:
        print(f"[dry-run] would commit 'cycle {cycle:05d}: {summary}', push and verify origin/main.")
        return 0
    if cmd_commit(argparse.Namespace(message=summary, paths=args.paths)) != 0:
        return 1
    if cmd_push(argparse.Namespace(allow_dirty=False)) != 0:
        print("[!] Cycle work is committed locally but NOT verified on GitHub. Fix the push before "
              "opening the next cycle (protocol §7); do not stack more than one unpushed cycle.")
        return 1
    append_metrics(ledger)
    ledger["status"] = "PUSHED"
    ledger.setdefault("steps_done", []).append(f"{now()} pushed and metrics appended")
    save_ledger(ledger)
    write_state_block(ledger)
    print(f"[+] Cycle {cycle:05d} closed and pushed. Next target: {ledger.get('next_target') or '(name it in §4)'}")
    print("    Continue: ./sync-main.sh pull && uv run ecosys-audit/scripts/cycle_runner.py open")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    ledger = load_ledger()
    fr = frontier()
    git = git_state()
    print(f"Mission : {load_mission().get('mission', {}).get('goal', 'see .agent/mission.json')}")
    print(f"Cycle   : {ledger.get('cycle', 0):05d} [{ledger.get('status', 'IDLE')}] "
          f"record={ledger.get('record', '-')}")
    print(f"Target  : {ledger.get('target') or '(unset)'}")
    gates = ledger.get("gates", {})
    print("Gates   : " + (", ".join("{}={}".format(g, gates[g].get("result", "-"))
                                    for g in GATE_IDS if g in gates) or "none recorded"))
    print(f"Decisions: {len(ledger.get('decisions', []))} recorded; open threads: .agent/backlog.md")
    print(f"Frontier: sim={fr.get('simulation_frontier')} verified={fr.get('verified_frontier')} "
          f"failure_hour={fr.get('current_failure_hour')}")
    print(f"Git     : branch={git['branch']} head={git['head']} origin/main={git['origin_main']} "
          f"ahead={git['ahead']} behind={git['behind']} dirty={git['dirty']}")
    print(f"Sync    : {ledger.get('sync_status', 'unknown')} — "
          f"{'OK' if git['in_sync'] else 'LOCAL AND GITHUB DIFFER (protocol §7)'}")
    print(f"Next    : {ledger.get('next_target') or '(unset)'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="\n".join(__doc__.splitlines()[2:8]))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status", help="print mission, cycle, gates, frontier and sync state")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("open", help="open the next cycle record")
    p.add_argument("--target", default="", help="one bounded, falsifiable question")
    p.add_argument("--force", action="store_true", help="open even if a cycle is still open")
    p.set_defaults(func=cmd_open)

    p = sub.add_parser("set", help="update the cycle ledger")
    p.add_argument("--status", help="|".join(["PLANNING", "WORKING", "VERIFYING", "DECIDED", "PUSHED", "BLOCKED"]))
    p.add_argument("--target")
    p.add_argument("--next-target", dest="next_target")
    p.add_argument("--sync-status", dest="sync_status")
    p.add_argument("--note", action="append", help="append a step note (repeatable)")
    p.add_argument("--field", action="append", help="key=value raw ledger field")
    p.set_defaults(func=cmd_set)

    p = sub.add_parser("gate", help="record a gate result with evidence")
    p.add_argument("gate", help="G1..G9")
    p.add_argument("--result", required=True, help="PASS | FAIL | NA")
    p.add_argument("--evidence", default="", help="receipt path, command, or file:line")
    p.set_defaults(func=cmd_gate)

    p = sub.add_parser("gates", help="run the automatable gate checks (build/tests/forbidden-diff scan)")
    p.add_argument("--build", action="store_true", help="run `zig build test` and record G2")
    p.add_argument("--tests", action="store_true", help="run the pytest suite")
    p.add_argument("--diff-ref", default="origin/main")
    p.add_argument("--record-g6", dest="record_g6", action="store_true", help="record the scan as G6")
    p.add_argument("--timeout", type=int, default=None, help="Deprecated; autonomous gates have no timeout")
    p.set_defaults(func=cmd_gates)

    p = sub.add_parser("commit", help="stage and commit the cycle")
    p.add_argument("--message", help="one-line what + why (the cycle id is prefixed)")
    p.add_argument("--paths", nargs="*", help="explicit paths to stage (default: -A)")
    p.set_defaults(func=cmd_commit)

    p = sub.add_parser("push", help="rebase onto origin/main, push, and verify the shas match")
    p.add_argument("--allow-dirty", dest="allow_dirty", action="store_true")
    p.set_defaults(func=cmd_push)

    p = sub.add_parser("close", help="check gates, commit, push, verify, append metrics")
    p.add_argument("--summary", help="one-line what + why for the commit")
    p.add_argument("--paths", nargs="*")
    p.add_argument("--dry-run", dest="dry_run", action="store_true")
    p.add_argument("--force", action="store_true", help="close a negative-result cycle")
    p.add_argument("--reason", help="required with --force")
    p.set_defaults(func=cmd_close)

    p = sub.add_parser("metrics", help="show/append the cycle metrics row")
    p.add_argument("--set", action="append", help="column=value (repeatable)")
    p.add_argument("--append", action="store_true", help="append the row to .agent/cycle-metrics.csv")
    p.set_defaults(func=cmd_metrics)

    args = parser.parse_args()
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
