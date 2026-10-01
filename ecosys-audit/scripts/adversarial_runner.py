# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Worker/judge adversarial workflow orchestrator for ecosys-modernization.

- DEEPSEEK (local Qwen3.8-27B on llama.cpp via the DeepSeek Harness): does all the work.
- CLAUDE (Claude Opus 5.5): deep scientific diagnosis, cross-language reasoning, architecture decisions,
  final scientific review and final judgement; guides Qwen when needed. Its ruling is final.

Each round: DEEPSEEK plans, works, self-checks and reports (escalating to CLAUDE only when needed), CLAUDE rules
APPROVED / REVISE / REJECTED in the round file. Only APPROVED rounds are committed and pushed.

Objective: Complete 30-year Ottawa run with zero ecosys-ng science gap against legacy Fortran
and scientifically comparable outputs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ROUNDS_DIR = ROOT / ".agent" / "adversarial"
RUNTIME_FILE = ROOT / ".agent" / "runtime" / "adversarial_runner.json"
STATE_FILE = ROOT / ".agent" / "state.md"
STATE_BEGIN = "<!-- runner:begin -->"
STATE_END = "<!-- runner:end -->"
ROUND_RE = re.compile(r"^round_(\d{5})(?:_[a-z]+)?\.md$")
RULING_RE = re.compile(r"\*\*Final Ruling \(CLAUDE\)\*\*:\s*\**\s*(APPROVED|REVISE|REJECTED)\b")
RULINGS = ("APPROVED", "REVISE", "REJECTED")


def load_roster() -> dict:
    roster_path = ROOT / ".agent" / "roster.json"
    if roster_path.exists():
        return json.loads(roster_path.read_text(encoding="utf-8"))
    return {}


def worker_and_judge(roster: dict) -> tuple[str, str]:
    authority = roster.get("authority", {})
    return authority.get("worker", "DEEPSEEK"), authority.get("judge", "CLAUDE")


def check_local_model(roster: dict) -> bool:
    """Warn (never fail) when the worker's local llama.cpp model is not being served."""
    worker = roster.get("roles", {}).get("DEEPSEEK", {})
    provider = worker.get("provider", {})
    base_url = provider.get("baseURL")
    model = worker.get("model", "").split("/", 1)[-1]
    if not base_url:
        return True
    try:
        with urllib.request.urlopen(f"{base_url.rstrip('/')}/models", timeout=5) as resp:
            served = [m.get("id") for m in json.load(resp).get("data", [])]
    except Exception as e:
        print(f"[!] Local llama.cpp server {base_url} unreachable ({e}); DEEPSEEK cannot work until it is up.")
        return False
    if model not in served:
        print(f"[!] {model} is not served by {base_url} (served: {', '.join(served) or 'none'}).")
        return False
    print(f"[+] DEEPSEEK model {model} is served by {base_url}.")
    return True


def round_files() -> dict[int, Path]:
    files: dict[int, Path] = {}
    for path in ROUNDS_DIR.glob("round_*.md"):
        m = ROUND_RE.match(path.name)
        if m:
            files.setdefault(int(m.group(1)), path)
    return files


def read_ruling(path: Path) -> str | None:
    text = re.sub(r"<!--.*?-->", "", path.read_text(encoding="utf-8"), flags=re.S)
    m = RULING_RE.search(text)
    return m.group(1) if m else None


def load_runtime() -> dict:
    if RUNTIME_FILE.exists():
        return json.loads(RUNTIME_FILE.read_text(encoding="utf-8"))
    return {"processed_rounds": []}


def save_runtime(runtime: dict) -> None:
    RUNTIME_FILE.parent.mkdir(parents=True, exist_ok=True)
    RUNTIME_FILE.write_text(json.dumps(runtime, indent=2) + "\n", encoding="utf-8")


def update_state(round_num: int, worker: str, judge: str, status: str) -> None:
    """Rewrite only the runner block of state.md; the rest is curated by CLAUDE."""
    block = (
        f"{STATE_BEGIN}\n"
        f"## Runner: round {round_num:05d} ({time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime())})\n"
        f"- Worker: {worker} (local Qwen3.8-27B). Judge: {judge} (Claude Opus 5.5, final say).\n"
        f"- Round status: {status}\n"
        f"{STATE_END}\n"
    )
    text = STATE_FILE.read_text(encoding="utf-8") if STATE_FILE.exists() else "# Adversarial Workflow State\n"
    if STATE_BEGIN in text and STATE_END in text:
        head, rest = text.split(STATE_BEGIN, 1)
        tail = rest.split(STATE_END, 1)[1].lstrip("\n")
        text = head + block + "\n" + tail
    else:
        lines = text.splitlines(keepends=True)
        text = "".join(lines[:1]) + "\n" + block + "".join(lines[1:])
    STATE_FILE.write_text(text, encoding="utf-8")


def git_commit_and_push(round_num: int, summary: str, roster: dict) -> None:
    """Commit and push an APPROVED round."""
    git_cfg = roster.get("git", {})
    try:
        status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=True)
        if not status.stdout.strip():
            print("[-] No changes to commit for this round.")
            return
        commit_msg = f"adversarial r{round_num:05d} (APPROVED by CLAUDE): {summary}"
        subprocess.run(["git", "add", "-A"], cwd=ROOT, check=True)
        subprocess.run(["git", "commit", "-m", commit_msg], cwd=ROOT, check=True)
        print(f"[+] Committed: {commit_msg}")
        if not git_cfg.get("push", True):
            return
        remote, branch = git_cfg.get("remote", "origin"), git_cfg.get("branch", "main")
        push_res = subprocess.run(["git", "push", remote, branch], cwd=ROOT, capture_output=True, text=True)
        if push_res.returncode == 0:
            print(f"[+] Pushed to {remote} {branch}.")
        else:
            print(f"[!] Push failed (will retry next round): {push_res.stderr.strip()[:200]}")
    except Exception as e:
        print(f"[!] Git commit/push error: {e}")


def round_title(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return line[2:].strip()[:120]
    return path.stem


def open_round(round_num: int, worker: str, judge: str) -> Path:
    path = ROUNDS_DIR / f"round_{round_num:05d}.md"
    template = (ROOT / ".agent" / "templates" / "adversarial-round.md").read_text(encoding="utf-8")
    path.write_text(
        template.replace("{{ROUND_ID}}", f"{round_num:05d}")
        .replace("{{WORKER}}", worker)
        .replace("{{JUDGE}}", judge)
        .replace("{{STATUS}}", "PLANNING"),
        encoding="utf-8",
    )
    print(f"[*] Opened round {round_num:05d}: {worker} plans and works, {judge} reviews and rules.")
    return path


def step(roster: dict, dry_run: bool) -> bool:
    """Advance the loop by at most one round. Returns True when a ruling was processed."""
    worker, judge = worker_and_judge(roster)
    files = round_files()
    if not files:
        if dry_run:
            print("[dry-run] would open round 00001.")
            return False
        open_round(1, worker, judge)
        update_state(1, worker, judge, "PLANNING")
        return False

    latest = max(files)
    path = files[latest]
    runtime = load_runtime()
    ruling = read_ruling(path)
    if ruling is None or latest in runtime["processed_rounds"]:
        if latest in runtime["processed_rounds"]:
            # Ruled and processed but the next round was not opened (e.g. interrupted run).
            ruling = None
        else:
            if not dry_run:
                update_state(latest, worker, judge, "AWAITING_RULING (no final CLAUDE ruling yet)")
            print(f"[.] Round {latest:05d} has no final CLAUDE ruling yet ({path.name}).")
            return False

    if ruling is not None:
        print(f"[*] Round {latest:05d} ruled {ruling} by {judge}.")
        if ruling == "APPROVED" and not dry_run:
            git_commit_and_push(latest, round_title(path), roster)
        elif ruling == "REJECTED":
            print(f"[!] {worker} must revert the rejected change before new work (see round {latest:05d} §4).")
        if not dry_run:
            runtime["processed_rounds"].append(latest)
            save_runtime(runtime)

    nxt = latest + 1
    if dry_run:
        print(f"[dry-run] would open round {nxt:05d}.")
    else:
        open_round(nxt, worker, judge)
        update_state(nxt, worker, judge, f"PLANNING (previous round {latest:05d}: {ruling or 'processed'})")
    return True


def main():
    parser = argparse.ArgumentParser(description="Ecosys worker/judge adversarial runner (DEEPSEEK works, CLAUDE rules)")
    parser.add_argument("--rounds", type=int, default=1, help="Number of rulings to process before exiting (default: 1)")
    parser.add_argument("--continuous", action="store_true", help="Keep polling for CLAUDE rulings without stopping")
    parser.add_argument("--poll-seconds", type=int, default=60, help="Seconds between ruling checks (default: 60)")
    parser.add_argument("--dry-run", action="store_true", help="Report actions without writing rounds, committing or pushing")
    parser.add_argument("--status", action="store_true", help="Print the latest round and its ruling, then exit")
    args = parser.parse_args()

    roster = load_roster()
    if args.status:
        files = round_files()
        if not files:
            print("No rounds yet.")
        else:
            latest = max(files)
            print(f"Latest round {latest:05d} ({files[latest].name}): ruling={read_ruling(files[latest]) or 'pending'}")
        check_local_model(roster)
        return 0

    check_local_model(roster)
    processed = 0
    while True:
        if step(roster, args.dry_run):
            processed += 1
            if not args.continuous and processed >= args.rounds:
                break
        elif not args.continuous:
            break
        time.sleep(args.poll_seconds)

    print("[+] Adversarial runner finished.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
