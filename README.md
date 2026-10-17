**Continuous autonomy:** No elapsed-time timeout at any stage of autonomous work. Follow
`.agent/continuous-autonomy.md` and `.agent/protocol.md`; older time/session/tool budgets
and timeout examples are superseded. Poll limits yield control; preserve and resume work.

# ecosys-modernization

## Overview
Modernization of the ECOSYS biogeochemical model from legacy Fortran 77 (`f77src/`) into Zig (`ecosys-ng/`).

## Project Goal
Complete the 30-year Ottawa simulation (262,920 h) in `ecosys-ng` with **zero science gap** against the legacy
Fortran reference and **scientifically comparable outputs**.

## How the project is run: one autonomous agent
Since 2026-10-08 the project is run by **a single autonomous agent** — any harness, any model, no required agent
name (optional label `ECOSYS-ONE`). The earlier multi-model arrangements (a 4-agent swarm, then a worker/judge
"adversarial" pair with rulings and pokes) are retired; their records stay in the repo as history, not authority.

- **One owner of everything**: planning, investigation, Zig implementation, builds, tests, long runs, diagnosis,
  decisions, the ledgers, and the final scientific review of each unit of work.
- **Work proceeds in cycles**: plan → work → evidence & self-check → independent verification → decide & record →
  **commit & push** → next cycle. No approval step, no stopping hook — the mission is expected to run
  autonomously for months until the goal is verified.
- **Objective gates decide, not opinions**: G1 build, G2 regressions, G3 conservation (water, heat, C, N, P close),
  G4 legacy traceability + floor parity, G5 output parity vs the legacy oracle, G6 no forbidden diff,
  G7 independent re-derivation by a **fresh-context read-only sub-agent**, G8 pushed.
- **Optional swarm of sub-agents**: the agent may fan out fresh-context read-only helpers
  (`.agent/briefs/`: verifier, diagnose, legacy-oracle, parity-sweep) for verification, parallel diagnosis, legacy
  oracle work and parity measurement. Sub-agents never edit, commit, push, or start runs.

Protocol of record: **`.agent/protocol.md`**. Entry point for any agent: `AGENTS.md` (and `CLAUDE.md`, which points
to the same place).

## Git & continuity
- **Every completed cycle is committed and pushed to GitHub `main`**, then verified
  (`git rev-parse HEAD origin/main`) — local and online stay in sync so no work is ever lost.
- `./sync-main.sh pull` at cycle start; `./sync-main.sh push` at cycle end. No force-push, no rewritten history,
  no commit of ignored run artifacts.
- Durable memory is the repository: `.agent/state.md` (current state), `.agent/cycle.json` (cycle ledger),
  `.agent/frontier.json` (simulation frontier), `.agent/backlog.md` (open threads and blockers), `audit/` (evidence).

## Pick up the project (any new session)
```bash
./sync-main.sh pull
sed -n 1,60p .agent/state.md      # frontier, live run, open threads
cat .agent/cycle.json             # current cycle, gates, sync status
cat .agent/frontier.json          # authoritative simulation frontier
git status -sb
bash scripts/start-agent.sh       # environment + mission + cycle status
```
Then continue the open cycle, or `uv run ecosys-audit/scripts/cycle_runner.py open --target "<one bounded question>"`.

## Token frugality (strict)
Pointer citations (`file:line` + short sha) instead of pasted source or diffs; simulation logs stay on disk via
`run_logged.py` with only `receipt.json` cited; Fortran is navigated with `f77query.py` (units run to 13,179 lines);
cycle records stay ≤ 600 words.

## Layout
| Path | Contents |
| --- | --- |
| `AGENTS.md` / `CLAUDE.md` | entry point for any agent |
| `.agent/protocol.md` | the operating protocol (cycles, gates, sync, multi-month continuity) |
| `.agent/` | control plane: mission, cycle ledger, state, frontier, backlog, briefs, playbooks |
| `ecosys-ng/` | Zig implementation (production source) |
| `f77src/` | legacy Fortran 77 reference — **read-only** |
| `ecosys-audit/` | audit tooling, evidence guide, project contract, skills index |
| `.agents/skills/` | the `ecosys-*` skills (mirrored in `.claude/skills/`) |
| `audit/` | evidence ledgers: gaps, provenance, invariants, deviations, reviews, runs |
| `archive/pre-solo-workflow/` | retired two-model launcher, judge-gated runner and poke tooling |
