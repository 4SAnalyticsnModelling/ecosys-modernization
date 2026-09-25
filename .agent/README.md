# .agent — 4-agent swarm control plane

Plan: `ecosys-ng_ottawa_qualification_execution_plan.md` (v4, reviewed). Spec: `ecosys-ng_ottawa_autonomous_qualification_plan.md`.
Everything the swarm needs lives in this repository: state here, large evidence in `evidence/` (git-ignored,
manifests committed), tools in `ecosys-audit/scripts/`.

## Herdr session `ecosys-ng` (workspace w1, five tabs, one pane each)

Tabs, in order: CONTROLLER, SAGE, FORGE, SENTINEL, PATHFINDER. (Herdr cannot reorder tabs; a pane
moved with `pane move --new-tab` is appended last.) Tab label = pane label = role.
Herdr agent names follow the pane, so moving panes between tabs does not break the wrapper.

| Pane / tab label | Herdr agent name | Harness / model | Role file |
|---|---|---|---|
| SAGE | `sage` | Claude Code, Opus 5.5 (`--dangerously-skip-permissions`) | `roles/sage.md` |
| FORGE | `forge` | OpenCode `--agent forge`, `github-copilot/gemini-3.8-flash`, `--auto` | `roles/forge.md` |
| PATHFINDER | `pathfinder` | OpenCode `--agent pathfinder`, `github-copilot/mai-code-1.1-flash`, `--auto` | `roles/pathfinder.md` |
| SENTINEL | `sentinel` | OpenCode `--agent sentinel`, `github-copilot/mai-code-1.1-flash`, `--auto` | `roles/sentinel.md` |

The `CONTROLLER` tab runs the deterministic controller (`scripts/start-swarm.sh`); the four agent
tabs are only driven by it.

Each pane's shell exports `ECOSYS_SWARM_ROLE=<role>` before the harness starts. For SAGE, the project
Claude hook then injects the SAGE role bootstrap. The former Claude-lead / Pi-reviewer workflow is
retired and archived in `archive/pre-swarm-workflow/`. OpenCode per-role permissions (edit/bash allowlists, no webfetch, no git mutation)
are in `.opencode/agents/*.md`; MCP is off (`opencode.json`). `roster.json` is the single source of
truth for names, models, launch args, budgets and write lanes.

## Files

| Path | Writer | Purpose |
|---|---|---|
| `state.md` | SAGE/user (<=1,500 words, replace not append) | current objective, blockers, next operation |
| `frontier.json` | `update_frontier.py` only | simulation vs verified frontier + evidence binding |
| `workflow.json` | wrapper (user sets approval) | durable process state; `autonomy_approved` gate |
| `dispatch.json` | SENTINEL (wrapper marks COMPLETE) | the one pending task |
| `current_task.md` | SENTINEL | one line |
| `tasks/T-NNNNN.md` | SENTINEL (wrapper for auto SAGE reviews) | task contract (`templates/task.md`) |
| `tasks/T-NNNNN.hypothesis.md` | FORGE | required before any production-science edit |
| `results/T-NNNNN.md` | the worker | result contract (`templates/result.md`) |
| `failures/F-NNNNN/` | `make_failure_packet.py` | spec section 18 packet |
| `archive/T-NNNNN.json` | wrapper | dispatch, changed paths, violations, hooks, review binding |
| `metrics.csv` | wrapper | per-turn wall time vs budget; tokens when the harness reports them |
| `locks/`, `runtime/` | wrapper (git-ignored) | swarm/machine locks, inflight intent, frozen task copy |

## Operating

All commands are run from the project root, inside a Herdr pane (any session; the wrapper targets `ecosys-ng`).

```
uv run ecosys-audit/scripts/swarm_wrapper.py status
uv run ecosys-audit/scripts/swarm_wrapper.py ensure-agents [--start]   # check/rename/start the 4 agents
uv run ecosys-audit/scripts/swarm_wrapper.py relaunch FORGE            # restart one role with roster args
uv run ecosys-audit/scripts/swarm_wrapper.py approve --by <user>       # USER ONLY: GP1 launch approval
uv run ecosys-audit/scripts/swarm_wrapper.py step [--manual]           # one agent turn
uv run ecosys-audit/scripts/swarm_wrapper.py run [--resume] [--max-steps N]
uv run ecosys-audit/scripts/swarm_wrapper.py precommit                 # SAGE APPROVE bound to current diff?
```

`scripts/start-swarm.sh [--resume]` = ensure-agents --start, then run.

One `step` = one fresh-session turn: SENTINEL routes when nothing is pending; otherwise the named role runs
its task. Then deterministic hooks: scope check, `zig fmt` + T1 (FORGE), failure packet (FAIL/STAGNATED),
automatic SAGE review of any production-source change, archive and metrics. The loop stops on IDLE,
HUMAN_REVIEW_REQUIRED, WAITING, or a refused approval.

## What the wrapper never does
Answer a permission dialog; re-prompt a task whose delivery was interrupted; revert an agent's edit
(scope violations are left in place and escalated); commit; push; promote the frontier.

## Resume after a crash
Run `swarm_wrapper.py run --resume`. An inflight task is collected from its result file if one exists, else
closed STAGNATED with a failure packet. It is never re-sent. An agent still `working` returns WAITING.
