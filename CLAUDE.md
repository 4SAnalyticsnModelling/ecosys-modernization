## Project: ecosys-ng Ottawa completion — ONE autonomous agent

This file used to describe a worker/judge adversarial workflow (DEEPSEEK works, CLAUDE judges, pokes, rulings).
**That workflow is retired (2026-10-08).** There is no judge, no second model, no pane pairing, no escalation
queue, and no `APPROVED | REVISE | REJECTED` ruling anywhere in this project anymore.

**Read, in order:** `AGENTS.md` → `.agent/protocol.md` (the protocol of record) → `.agent/state.md` +
`.agent/cycle.json` + `.agent/frontier.json` (where the work actually stands).

### Non-negotiables (summary; `.agent/protocol.md` is authoritative)
- **You are the whole team.** One agent plans, implements Zig, builds, tests, runs, diagnoses, decides, keeps the
  ledgers and reviews its own work against objective gates. Any harness/model may pick the project up; no name
  required. Use a swarm of fresh-context **read-only sub-agents** (`.agent/briefs/`) when it helps — required for
  independent verification (G7) of any science, solver, DEV or architecture change. Sub-agents never edit,
  commit, push, or start full runs.
- **Cycles, forever, until verified**: plan → work → evidence/self-check → independent verification → decide &
  record → **commit & push** → next cycle. No approval step, no stopping hook; multi-month autonomy.
- **Push every completed cycle to GitHub `main`** and verify: `git commit`, `./sync-main.sh push`,
  `git rev-parse HEAD origin/main` (same sha). `./sync-main.sh pull` at cycle start. Never force-push, never
  leave `main` broken — revert a failing diff and record the negative result.
- **Gates decide**: G1 build (**Zig 0.17.x only**), G2 regressions, G3 conservation (water/heat/C/N/P close), G4 legacy traceability
  (`f77src/...:line` + floor parity), G5 output parity, G6 no forbidden diff, G7 independent re-derivation,
  G8 pushed. A reproduced FAIL is fixed or reverted, not argued.
- **Zig 0.17.x compiles `ecosys-ng`; Zig 0.16 is retired** — pin `.agent/toolchain.json`, check
  `uv run ecosys-audit/scripts/preflight.py`, migration work order `.agent/migrations/zig-0.17.md`.
- **Everything stays inside this repository** — sources, builds, caches (`.zig-cache`, `.zig-cache-global`,
  `.uv-cache`, `.tmp`, `.cache`), test output, checkpoints, run output, logs. Nothing a later cycle needs to
  reproduce may live outside the repo (gate G9).
- **Read-only**: `f77src/`, `f77example/`, `ecosys-ng-prod-examples/`. Fortran via
  `uv run ecosys-audit/scripts/f77query.py` (never bulk-read a `.f`); `-r8 -i4`, often 0-based column-major.
- **Legacy never iterates**: the legacy trajectory is the oracle. On non-convergence/balance failure use
  `.agent/playbooks/convergence-and-balance.md` — bugs first (science, translation, binding, duplication,
  floor bounds), then triage, then rungs S1→S9.
- **Forbidden**: loosening tolerances or raising ceilings to pass, post-solve clamps, publishing an unclosed
  ledger, new "publish best-bounded" deviations, silent retries, fabricated evidence.
- **Goal**: full 30-year Ottawa run (262,920 h) with zero science gap vs legacy Fortran and scientifically
  comparable outputs.

`.agent/adversarial/` and `archive/pre-solo-workflow/` are retired history: cite them for the science record,
never as authority.
