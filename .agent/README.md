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
| `state.md` | controller (from SENTINEL's dispatch) and SAGE (<=1,500 words, replace not append) | current objective, blockers, next operation |
| `frontier.json` | `update_frontier.py` only | simulation vs verified frontier + evidence binding |
| `workflow.json` | wrapper (user sets approval) | durable process state; `autonomy_approved` gate |
| `dispatch.json` | SENTINEL (wrapper marks COMPLETE) | the one pending task |
| `current_task.md` | SENTINEL | one line |
| `tasks/T-NNNNN.md` | SENTINEL (wrapper for auto SAGE reviews) | task contract (`templates/task.md`) |
| `tasks/T-NNNNN.hypothesis.md` | FORGE | required before any production-science edit |
| `results/T-NNNNN.md` | the worker | result contract (`templates/result.md`) |
| `failures/F-NNNNN/` | `make_failure_packet.py` | spec section 18 packet |
| `failures/Q-<task>/` | wrapper | quarantined out-of-lane edit: the agent's files + `quarantine.json` |
| `archive/T-NNNNN.json` | wrapper | dispatch, changed paths, violations, hooks, review binding |
| `metrics.csv` | wrapper | per-turn wall time vs budget; tokens when the harness reports them |
| `locks/`, `runtime/` | wrapper (git-ignored) | swarm/machine locks, inflight intent, frozen task copy |

## Operating

All commands are run from the project root, inside a Herdr pane (any session; the wrapper targets `ecosys-ng`).

```
uv run ecosys-audit/scripts/swarm_wrapper.py status
uv run ecosys-audit/scripts/swarm_wrapper.py ensure-agents [--start]   # check/rename/start the 4 agents
uv run ecosys-audit/scripts/swarm_wrapper.py relaunch FORGE            # restart one role with roster args
uv run ecosys-audit/scripts/swarm_wrapper.py approve --by <user>       # GP1 launch approval (given 2026-09-25)
uv run ecosys-audit/scripts/swarm_wrapper.py step [--manual]           # one agent turn
uv run ecosys-audit/scripts/swarm_wrapper.py run [--max-steps N]       # default: until SAGE-confirmed IDLE
uv run ecosys-audit/scripts/swarm_wrapper.py precommit                 # SAGE APPROVE bound to current diff?
uv run ecosys-audit/scripts/swarm_wrapper.py cost                      # tokens/cost by role, per frontier advance
uv run ecosys-audit/scripts/swarm_wrapper.py clear-review --by <name> --note "..."  # optional; run clears halts itself
```

`scripts/start-swarm.sh` = ensure-agents --start, then run.

One `step` = one fresh-session turn: SENTINEL routes when nothing is pending; otherwise the named role runs
its task. Then deterministic hooks: scope check, `zig fmt` + T1 (FORGE), failure packet (FAIL/STAGNATED),
automatic SAGE review of any production-source change, archive and metrics.

## No human in the loop (decision D9, user, 2026-09-25)
SAGE makes every decision. The controller never stops for a person; each former halt is handled in place:

| Event | Automatic response |
|---|---|
| ALLOWED FILES outside the role's lane (or protected) | dispatch refused before delivery; errors go to SENTINEL's next brief |
| Agent edits outside its lane / protected path / source without hypothesis / widens its task | files copied to `failures/Q-<task>/`, restored to pre-turn content; task FAIL; SENTINEL re-routes |
| SAGE CHAIN into a file the chained role cannot write | chain ignored; SENTINEL routes (SAGE writes its own ledger files) |
| Agent at a permission/question dialog | declined with esc (never approved); if it persists, the role is relaunched |
| Agent missing, wrong kind, or ignores its reset | role relaunched with backoff; a never-sent task stays PENDING |
| SENTINEL writes HUMAN_REVIEW_REQUIRED, or a result asks for a human | SAGE decision task (`DECISION:` line required) |
| SENTINEL fails to route twice | SAGE decision task names the next task |
| SENTINEL reports IDLE | SAGE confirms or names work; only a second IDLE after that ends `run` |
| git add/commit/push failure | recorded; retried next cycle |
| Controller error (Herdr, I/O) | `run` retries with backoff (max 15 min) |
| A halt left by the pre-D9 controller | cleared automatically on the next step, leftovers committed |

`run` exits only on SAGE-confirmed IDLE, missing autonomy approval, or another controller holding the lock.
A machine outage (e.g. a faulted D: drive) still stops everything; that is not a decision.

## Commit and push (decision D8, user, 2026-09-25)
After every successfully collected cycle, the controller commits exactly the paths that cycle changed
(message `swarm: <task> <status>`) and pushes `HEAD:main` to `origin` (settings: `roster.json` `git`).
- Production source is withheld from commits until a SAGE APPROVE matches the current diff
  (`precommit` PASS); it is then committed in the SAGE cycle.
- Quarantined edits are restored before the commit, so an out-of-lane change is never committed
  (its copy under `failures/Q-<task>/` is).
- Plain fast-forward push only: never force, pull, rebase or merge. A failed push keeps the commit local
  and is retried every cycle; it never stops the swarm.
- Agents themselves still never commit or push.

## Token economy (2026-09-25)
- SENTINEL reads one controller-built brief (`.agent/runtime/sentinel-brief.md`) instead of ~8 files:
  3 model calls / 42k tokens per route, measured, versus 7-12 calls / 115-175k before.
- A SAGE result may carry a `## CHAIN` block with one mechanical follow-up (no production source, no
  reference data). The controller dispatches it directly, skipping a routing turn. Chains never chain.
- Every turn's tokens are read from the harness's own records (OpenCode session export; Claude
  session log) into `metrics.csv` (`input_tokens` = fresh + cache read + cache write).
  `swarm_wrapper.py cost` reports totals and tokens per verified-frontier advance.
- SAGE runs with `--strict-mcp-config` (no MCP servers). Do NOT add `--disable-slash-commands`:
  it breaks `/clear`, the reset between tasks. FORGE uses Gemini 3.8 Flash in the `high` variant
  (set with OpenCode's `/variants`).
- Keep interactive supervisor sessions short. Watch with `status` / `cost`, not a long chat.

## What the wrapper never does
Approve a permission dialog (it only declines); re-prompt a task whose delivery was interrupted; discard an
agent's edit without keeping a copy; force-push; promote the frontier.

## Resume after a crash
Run `scripts/start-swarm.sh` again. An inflight task is collected from its result file if one exists, else
closed STAGNATED with a failure packet. It is never re-sent. While an agent is still `working`, `run` waits.
