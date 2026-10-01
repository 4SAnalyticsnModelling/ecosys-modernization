# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Claude Code command hooks: adversarial workflow bootstrap.

Provides role bootstrap and guidance for the worker/judge adversarial workflow:
DEEPSEEK (local Qwen3.8-27B via llama.cpp) does all the work; CLAUDE (Claude Opus 5.5) handles
deep diagnosis, cross-language reasoning, architecture, final scientific review and the final ruling.
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
    "This project runs a worker/judge adversarial workflow: DEEPSEEK (local Qwen3.8-27B "
    "via llama.cpp) does all the work; CLAUDE (Claude Opus 5.5) handles only deep scientific diagnosis, "
    "cross-language reasoning, architecture decisions and final scientific review, guides Qwen when needed, "
    "and makes the final call. The target is the complete 30-year Ottawa run "
    "with zero ecosys-ng science gap against legacy Fortran and rigorous output comparability. "
    "The loop continues without stopping until the goal is achieved. "
    "Current state: .agent/state.md; control plane: .agent/README.md; roster: .agent/roster.json."
)


def role_bootstrap(role: str) -> str:
    return (
        f"You are operating as {role.upper()} in the adversarial ecosys-ng qualification workflow. "
        f"Follow .agent/roles/{role}.md and your active adversarial task. "
        + (
            "Handle only DEEPSEEK escalations (deep diagnosis, cross-language, architecture) and the final "
            "scientific review; end each round with a final APPROVED / REVISE / REJECTED ruling; guide Qwen when needed. "
            if role == "claude"
            else "You do all the work: plan each round, implement, self-check and report; escalate only deep diagnosis, "
            "cross-language or architecture questions to CLAUDE; follow CLAUDE's final ruling. "
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
