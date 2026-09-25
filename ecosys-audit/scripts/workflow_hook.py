# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code command hooks: no model calls, no Herdr control, no lane registration.

The Claude-lead / Pi-reviewer lane these hooks once served is retired (archive/pre-swarm-workflow/).
They now only (1) point every new session at the swarm control plane, (2) keep the retired
audit/handoff.md read-only, and (3) route verbose builds/tests through run_logged.py.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys

from workflow import ROOT, ProtocolError, inside

SWARM_ROLES = ("sentinel", "pathfinder", "forge", "sage")

PROJECT_BOOTSTRAP = (
    "This project runs the 4-agent Ottawa qualification swarm (SENTINEL, PATHFINDER, FORGE, SAGE). "
    "Current state: .agent/state.md; how it works: .agent/README.md; plan: "
    "ecosys-ng_ottawa_qualification_execution_plan.md. The Claude-lead / Pi-reviewer workflow and "
    "audit/handoff.md are retired (archive/pre-swarm-workflow/); do not resume from them. "
    "Use run_logged.py for builds/tests/verbose commands. No automatic push."
)


def swarm_bootstrap(role: str) -> str:
    return (f"You are the {role.upper()} role of the ecosys-ng 4-agent swarm. Follow .agent/roles/{role}.md and "
            "the task file your prompt names. Write only the result file the task names, then stop. "
            "Use run_logged.py for builds/tests. No push.")


def noisy_command(command: str) -> bool:
    if "run_logged.py" in command:
        return False
    return bool(re.search(r"\b(?:zig(?:\.exe)?\s+(?:build|test)|gfortran(?:\.exe)?\b|pytest\b|ecosys_ng\.exe(?:\s|$))", command, re.I))


def respond(root: Path, event: dict):
    kind = event.get("hook_event_name")
    role = os.environ.get("ECOSYS_SWARM_ROLE", "").strip().lower()
    if kind == "SessionStart":
        text = swarm_bootstrap(role) if role in SWARM_ROLES else PROJECT_BOOTSTRAP
        return {"hookSpecificOutput": {"hookEventName": kind, "additionalContext": text}}
    if kind == "PreToolUse":
        inp, name = event.get("tool_input", {}), event.get("tool_name", "")
        reason = None
        if name in ("Write", "Edit", "MultiEdit"):
            value = inp.get("file_path") or inp.get("path")
            try:  # Out-of-project writes (e.g. the harness memory dir) are not this hook's lane.
                target = inside(root, value) if value else None
            except ProtocolError:
                target = None
            if target == root / "audit/handoff.md":
                reason = "audit/handoff.md is a retired historical pointer. Current state belongs in .agent/state.md."
        if name in ("Bash", "PowerShell") and noisy_command(inp.get("command", "")):
            reason = ("Use `uv run ecosys-audit/scripts/run_logged.py --cwd <cwd> --out audit/runs/<unique-dir> "
                      "--timeout <seconds> -- <executable> <args>`. Full streams stay on disk; bounded receipt returns. "
                      "Set the outer tool timeout >= wrapper timeout + 60s. Do not detach the bounded test/build.")
        if reason:
            return {"hookSpecificOutput": {"hookEventName": kind, "permissionDecision": "deny", "permissionDecisionReason": reason}}
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
