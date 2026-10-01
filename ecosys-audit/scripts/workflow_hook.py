# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code command hooks: adversarial workflow bootstrap.

Provides role bootstrap and guidance for the worker/judge adversarial workflow:
DEEPSEEK (local Qwen3.8-35B-A3B-Distill via llama.cpp) is the main worker and
CLAUDE (Claude Opus 5.5) is the reviewer, critic, supervisor and judge whose ruling is final.
Never denies operations or halts progress towards the full Ottawa qualification goal.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys

from workflow import ROOT, ProtocolError

ROLES = ("claude", "deepseek")

PROJECT_BOOTSTRAP = (
    "This project runs a worker/judge adversarial workflow: DEEPSEEK (local Qwen3.8-35B-A3B-Distill "
    "via llama.cpp) is the main worker; CLAUDE (Claude Opus 5.5) is the reviewer, critic, supervisor, "
    "idea generator and judge, and CLAUDE's ruling is final. The target is the complete 30-year Ottawa run "
    "with zero ecosys-ng science gap against legacy Fortran and rigorous output comparability. "
    "The loop continues without stopping until the goal is achieved. "
    "Current state: .agent/state.md; control plane: .agent/README.md; roster: .agent/roster.json."
)


def role_bootstrap(role: str) -> str:
    return (
        f"You are operating as {role.upper()} in the adversarial ecosys-ng qualification workflow. "
        f"Follow .agent/roles/{role}.md and your active adversarial task. "
        + (
            "You are the judge: write directives, review DEEPSEEK's work, and end each round with a final "
            "APPROVED / REVISE / REJECTED ruling. "
            if role == "claude"
            else "You are the main worker: execute CLAUDE's directive, report evidence, and follow CLAUDE's final ruling. "
        )
        + "Keep physics validation, conservation and legacy traceability rigorous. "
        "No stopping hooks: proceed persistently until the complete 30-year Ottawa run is scientifically verified."
    )


def respond(root: Path, event: dict):
    kind = event.get("hook_event_name")
    role = os.environ.get("ECOSYS_ROLE", os.environ.get("ECOSYS_SWARM_ROLE", "")).strip().lower()
    if kind == "SessionStart":
        text = role_bootstrap(role) if role in ROLES else PROJECT_BOOTSTRAP
        return {"hookSpecificOutput": {"hookEventName": kind, "additionalContext": text}}
    # PreToolUse returns empty to ensure no tool invocation is blocked by hooks
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
