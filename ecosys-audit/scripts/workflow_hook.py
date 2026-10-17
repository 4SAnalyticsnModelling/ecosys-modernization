# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code command hooks for the single-agent ecosys-ng mission.

SessionStart injects a compact pickup briefing for the one agent that owns the whole loop. The former
worker/judge roles (DEEPSEEK / CLAUDE, pokes, rulings) were retired on 2026-10-08; two mandates are restated
because habit breaks them most often: **Zig 0.17.x** builds `ecosys-ng` (protocol.md §8, gate G1) and **all work
stays inside this repository** (protocol.md §8a, gate G9).

Hooks inform and never halt the mission, with one narrow exception kept from the earlier protocol: writing the
retired `audit/handoff.md` by hand is denied, because that artifact belongs to the old two-model workflow and a
fabricated handoff is fake evidence.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys

from workflow import ROOT, ProtocolError

PICKUP = (
    "ecosys-ng mission: the full 30-year Ottawa run (262,920 h) with zero science gap against legacy Fortran. "
    "ONE agent owns every cycle - plan, work, evidence/self-check, independent verification (G7), decide & record, "
    "commit & push, next cycle - until F1-F7 in .agent/protocol.md. No roles, pokes, rulings or approval gates.\n"
    "Pick up: ./sync-main.sh pull -> uv run ecosys-audit/scripts/preflight.py -> .agent/protocol.md -> "
    ".agent/state.md, .agent/cycle.json, .agent/frontier.json, .agent/backlog.md, the open cycle in .agent/cycles/.\n"
    "G1 TOOLCHAIN: Zig 0.17.x builds, tests and measures ecosys-ng; 0.16 is retired, so a 0.16 receipt is dated "
    "history, never current evidence. Pin .agent/toolchain.json; record `zig version`; work order "
    ".agent/migrations/zig-0.17.md.\n"
    "G9 CONTAINMENT: every read, write, build, test, run, cache, checkpoint, download and log stays inside this "
    "repository. Pin per command: TMPDIR=$PWD/.tmp XDG_CACHE_HOME=$PWD/.cache UV_CACHE_DIR=$PWD/.uv-cache "
    "ZIG_GLOBAL_CACHE_DIR=$PWD/ecosys-ng/.zig-cache-global, and pass zig build|test --cache-dir .zig-cache "
    "(Zig 0.17 rejects --global-cache-dir on zig build; the env var moves the global cache). Nothing outside; "
    "evidence lands in audit/runs/ via run_logged.py.\n"
    "Close a cycle: git commit, ./sync-main.sh push, then `git rev-parse HEAD origin/main` must match. "
    "NO EXECUTION TIMEOUTS: .agent/continuous-autonomy.md applies to every stage; poll and resume. "
    "Optional read-only sub-agents come from .agent/briefs/ (verifier = G7, diagnose, legacy-oracle, parity-sweep)."
)

# ---------------------------------------------------------------- gate G9: containment advisor
_PATH_TOKEN = r"""[^\s;'"]+"""
_FLAG_WITH_PATH = re.compile(
    r"(?:--cache-dir|--global-cache-dir|--cache-base|--output-dir|--out-dir|--output-path|--output|--out"
    r"|--dir|--directory|--target-dir|--build-dir|--scratch-dir|--checkpoint-dir|--root|--extract|--prefix"
    r"|--install-dir|--home|--venv|[ ]-o)[= ](" + _PATH_TOKEN + r")",
    re.IGNORECASE,
)
_REDIRECT = re.compile(r"""(?<![0-9&])>{1,2}\s*((?:/|~|\$)[^\s;']*)""")
_BARE_PATH = re.compile(
    r"""(?:~[/\\]\S*|\$\{?HOME\}?\S*|\$\{?TMPDIR\}?\S*"""
    r"""|/(?:tmp|var/tmp|private|Users|home|Volumes|opt|Applications|System|Library|usr/local)\S*"""
    r"""|[A-Za-z]:[/\\]\S*|\\\\\S+)"""
)
# Reading the installed toolchain or system files outside the repo is allowed; writing there is not.
_READ_ROOTS = re.compile(r"^/(?:opt|usr|bin|sbin|etc|private/etc|Library|System|Applications|dev|proc|sys)\b")
# Plain lookups never write anything, so their read paths are not worth a reminder.
_READONLY_FIRST_WORD = {"grep", "rg", "cat", "head", "tail", "ls", "find", "fd", "stat", "file", "wc", "which"}


def _under_root(path: str) -> bool:
    root = ROOT.as_posix().rstrip("/")
    try:
        normalized = os.path.normpath(path)
    except ValueError:
        return True  # unparseable: stay quiet rather than nag
    return normalized == root or normalized.startswith(root + "/")


def _looks_external(token: str, writable: bool = True) -> bool:
    """True when a path token clearly points outside this repository."""
    token = token.strip("\"'`()[]{}<>,;")
    if not token or token.startswith("-"):
        return False
    if re.match(r"^[A-Za-z]:[/\\]", token) or token.startswith("\\\\"):
        return True  # Windows drive letter or UNC path: never this working tree
    if not (token.startswith("/") or token.startswith("~") or token.startswith("$")):
        return False  # relative paths are contained by construction
    expanded = os.path.expandvars(os.path.expanduser(token))
    if "$" in expanded:  # unresolvable variable (unset TMPDIR, ...): judge by its literal prefix
        return bool(re.match(r"^/(?:tmp|var|private|Users|home|Volumes|opt|Applications|System|Library|usr)\b",
                             expanded))
    if _under_root(expanded):
        return False
    return not (not writable and _READ_ROOTS.match(expanded))


def containment_warning(command: str) -> str:
    """Advisory text when a command looks like it writes outside the repository (never a block)."""
    stripped = command.strip()
    if not stripped:
        return ""
    read_only = stripped.split(maxsplit=1)[0] in _READONLY_FIRST_WORD
    tokens = [m.group(1) for m in _FLAG_WITH_PATH.finditer(command)]
    tokens += [m.group(1) for m in _REDIRECT.finditer(command)]
    if not read_only:
        tokens += [(m.group(0), False) for m in _BARE_PATH.finditer(command)]
    offenders = []
    for token in tokens:
        path, writable = token if isinstance(token, tuple) else (token, True)
        if _looks_external(path, writable=writable):
            offenders.append(path)
    if not offenders:
        return ""
    shown = ", ".join(sorted(set(offenders))[:4])
    return (
        "Containment check (gate G9, .agent/protocol.md §8a): this command touches a path outside the repository "
        f"-> {shown}. Only the installed toolchain and read-only system files may be read outside; nothing may be "
        "written outside. Keep caches and outputs in the repo (`.tmp/`, `.cache/`, `.uv-cache/`, "
        "`ecosys-ng/.zig-cache-global/`, evidence under `audit/runs/`) and re-run. If the command is actually "
        "safe, proceed - this hook never blocks."
    )


# ------------------------------------------------------- evidence discipline (kept from the earlier protocol)
_NOISY = re.compile(r"\bzig\s+(build|test)\b|\bctest\b|\bmake\b|\bcmake\s+--build\b|\bf77index\.py\s+audit\b")
_WRAPPED = re.compile(r"run_logged\.py")


def noisy_command(command: str) -> bool:
    """True for a heavy build/test command run directly instead of through run_logged.py."""
    if _WRAPPED.search(command):
        return False
    return bool(_NOISY.search(command))


# Retired two-model artifact: a hand-written handoff would be fabricated evidence.
_RETIRED_HANDOFF = re.compile(r"(?:^|/)(?:audit/)?handoff\.md$")


def respond(root: Path, event: dict):
    kind = event.get("hook_event_name")
    if kind == "SessionStart":
        return {"hookSpecificOutput": {"hookEventName": kind, "additionalContext": PICKUP}}
    if kind == "PreToolUse":
        tool = event.get("tool_name")
        tool_input = event.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            return {}
        if tool in ("Write", "Edit", "MultiEdit", "write", "edit"):
            target = str(tool_input.get("file_path") or tool_input.get("path") or "")
            if target and _RETIRED_HANDOFF.search(target.replace("\\", "/").split(":")[-1].lstrip("/")):
                return {"hookSpecificOutput": {"hookEventName": kind, "permissionDecision": "deny",
                                               "permissionDecisionReason": ("audit/handoff.md belonged to the "
                                                                            "retired worker/judge workflow; the "
                                                                            "cycle record in .agent/cycles/ is the "
                                                                            "only place work is recorded.")}}
        if tool in ("Bash", "bash"):
            command = str(tool_input.get("command") or tool_input.get("cmd") or "")
            if command:
                warning = containment_warning(command)
                if warning:
                    return {"hookSpecificOutput": {"hookEventName": kind, "additionalContext": warning}}
                if noisy_command(command):
                    return {"hookSpecificOutput": {"hookEventName": kind, "additionalContext": (
                        "Evidence check: heavy build/test detected. Run it through the receipt wrapper so the log "
                        "lands in audit/runs/ (gate G1/G2): uv run ecosys-audit/scripts/run_logged.py "
                        "--out audit/runs/<unique-name> -- <the command>. "
                        "Advisory only - the hook never blocks.")}}
    # Everything else stays silent: hooks inform, they never halt the mission.
    return {}


def main():
    try:
        event = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        root = Path(os.environ.get("CLAUDE_PROJECT_DIR", str(ROOT))).resolve()
        if root != ROOT:
            return 0
        print(json.dumps(respond(root, event), separators=(",", ":")))
        return 0
    except (OSError, ValueError, KeyError, ProtocolError) as e:
        print(f"Ecosys workflow hook: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
