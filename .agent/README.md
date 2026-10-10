# `.agent` — control plane for one autonomous agent

**Protocol of record: [`protocol.md`](protocol.md).** This file is the directory guide.

One agent (any harness, any model, no required name — optional label `ECOSYS-ONE`) runs the whole project alone:
plans, implements Zig, builds, tests, runs, diagnoses, decides, keeps the ledgers, and reviews its own work against
objective gates. The retired two-model worker/judge workflow (worker DEEPSEEK, judge CLAUDE with
`APPROVED|REVISE|REJECTED` rulings, escalations, pokes, Herdr panes) is history; `.agent/adversarial/` remains as the
scientific record, with no authority.

## Objective
Complete 30-year Ottawa run (262,920 h) of `ecosys-ng` with **zero science gap** against legacy Fortran (`f77src/`)
and **scientifically comparable outputs**. No stopping hooks, no approval gate, no artificial budget halt: cycles
continue for months until finish line F1–F7 (`.agent/protocol.md` §1) is met with evidence.

## The cycle
`open` → plan → work → evidence & self-check → independent verification (G7) → decide & record → **commit & push** →
`close` → next cycle. Ledger: `cycle.json` (via `uv run ecosys-audit/scripts/cycle_runner.py`), record:
`cycles/cycle_NNNNN.md` from `templates/cycle.md`.

| Gate | Decides |
| --- | --- |
| G1 | build clean (Debug + ReleaseSafe; ReleaseFast for production runs) |
| G2 | regressions pass and the fix has a discriminating test |
| G3 | water, heat, C, N, P ledgers close at every accepted hour |
| G4 | every physics change traces to `f77src/...:line`, floors match legacy (value, scale, operator, units, placement) |
| G5 | affected outputs match the legacy oracle (units, time semantics) |
| G6 | no forbidden diff: tolerance loosening, post-solve clamp, unregistered DEV, ceiling raise, silent retry |
| G7 | a fresh-context read-only verifier sub-agent re-derives the decisive gates from diff + legacy + receipts |
| G8 | pushed: `git rev-parse HEAD origin/main` match |

G7 is mandatory for any change to process equations/parameters, solver formulation, bounds/floors, acceptance or
rollback logic, restart/output semantics, architecture, any DEV, and before a hard solver rung (S4/S5/S8/S9).
A reproduced FAIL is fixed or reverted — never argued, never outvoted.

## Files
| Live | Purpose |
| --- | --- |
| `protocol.md` | the whole protocol: cycle, gates, decisions, sync, multi-month continuity, recovery |
| `mission.json` | mission, gates, sync policy, lanes, prohibitions, budgets, legacy map |
| `cycle.json` | current cycle ledger (status, gates, target, next target, sync) |
| `cycles/` | cycle records (one file per cycle) |
| `state.md` | current state: frontier, live run, open threads, next target |
| `backlog.md` | ordered open threads and blockers with the condition that clears each |
| `frontier.json` | authoritative simulation frontier (only `update_frontier.py promote` moves `verified_frontier`) |
| `briefs/` | read-only sub-agent briefs: `verifier` (G7), `diagnose`, `legacy-oracle`, `parity-sweep` |
| `roles/agent.md` | role card for whoever is the agent this session |
| `templates/cycle.md` | cycle record template |
| `playbooks/convergence-and-balance.md` | the solver/balance ladder (bugs → triage → S1–S9) and the Lessons log |
| `cycle-metrics.csv` | per-cycle metrics (appended by `cycle_runner.py close`) |
| `locks/` | run locks — stale ones get removed with a note |

| Legacy (do not update) | Was |
| --- | --- |
| `adversarial/` | worker/judge round records r1–r57 — science history only |
| `roster.json` | two-model roster → superseded by `mission.json` |
| `workflow.json`, `dispatch.json`, `current_task.md`, `tasks/`, `results/`, `failures/` | retired swarm-controller ledgers |
| `roles/claude.md`, `roles/deepseek.md`, `roles/forge.md`, `roles/pathfinder.md`, `roles/sage.md`, `roles/sentinel.md` | retired personas (archived) |
| `archive/` | older task history |
| `../archive/pre-solo-workflow/` | retired launchers + judge-gated runner + poke tooling |

## Sub-agents (optional swarm)
Fan out fresh-context **read-only** helpers from `briefs/` when wall-clock time or self-blindness is the limit.
They never edit, commit, push, or start full runs, and their verdicts are evidence to reproduce, not authority to
follow. See `briefs/README.md` for how to spawn them in any harness.

## Git: never lose work
`./sync-main.sh pull` at cycle start; **every completed cycle committed and pushed to `origin/main`**, then verified
(`git rev-parse HEAD origin/main`). Never force-push, never rewrite pushed history, never commit ignored run
artifacts, never leave `main` broken — revert a gate-failing diff and record the negative result instead.

## Token frugality
Never paste logs or whole files into prompts, cycle records or sub-agent briefs; cite `file:line`, short sha and
`receipt.json` paths; use `f77query.py`/`bindcheck.py` and narrow ripgrep; keep a cycle record ≤ 600 words; route
heavy commands through `run_logged.py` so output stays on disk.
