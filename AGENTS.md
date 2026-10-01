## Workflow: Worker/Judge Adversarial Loop (DEEPSEEK works, CLAUDE judges)

This project operates on an adversarial workflow between two models hosted on the **same Herdr tab in multi-pane** (`ADVERSARIAL` tab: `CLAUDE` on left, `DEEPSEEK` on right):
1. **DEEPSEEK** (`local/qwen3.5-35b-a3b`, local llama.cpp via the DeepSeek Harness): **does all the work**: plans rounds, investigates, implements, builds, tests, runs, self-checks and keeps the ledgers.
2. **CLAUDE** (`claude-opus-5-5`): handles **only** deep scientific diagnosis, cross-language (Fortran → Zig) reasoning, architecture decisions and the final scientific review. It makes the **final judgement call**, and **directs and guides Qwen when needed**. **CLAUDE's decision is final.**

### Continuous Worker/Judge Loop
- Each round: DEEPSEEK plans → DEEPSEEK works, self-checks and reports evidence → (only if needed) DEEPSEEK escalates a deep-diagnosis, cross-language or architecture question and CLAUDE answers → CLAUDE gives the final scientific review and rules `APPROVED | REVISE | REJECTED` with the next target. The ruling is final; DEEPSEEK may lodge one evidence-backed objection to it.
- Only APPROVED rounds are committed and pushed. DEEPSEEK reverts REJECTED changes before new work and fixes REVISE points in the next round.
- **Convergence & balance failures** (the ReleaseFast run currently stalls on mass/energy balance or Newton/Anderson non-convergence): follow `.agent/playbooks/convergence-and-balance.md`. **CLAUDE leads the strategy** and teaches it to Qwen.
  - Legacy steps explicitly in fixed sub-cycles and never iterates, so the legacy trajectory is the oracle.
  - DEEPSEEK first rules out **science, translation, binding, duplication and floor-bound bugs**. For floor bounds, each guard must match the legacy `0.0` / `ZERO` / `ZERO2` / area-scaled `ZEROS*` / population-scaled, daily-recomputed `ZEROP*`/`ZEROQ` / routine-local `ZEROC` (1e-32 SOLUTE vs 1e-48 STARTE) in value, scale, operator, units and placement (playbook §1b). These checks cover the routines that touch the failing hour (PASS/FAIL each, with `file:line`). Any FAIL is fixed before trying numerical strategies.
  - DEEPSEEK then builds a diagnostic packet, replays the hour in ReleaseSafe/Debug, finite-difference-checks the Jacobian, and classifies the failure.
  - DEEPSEEK applies the simple rungs (residual-based convergence, conservative form, line search/update caps, Δt cut-and-retry, scaling).
  - CLAUDE briefs the hard rungs: phase-change splitting, Picard/L-scheme→Newton with safeguarded Anderson, operator splitting, and the legacy explicit sub-cycling fallback.
  - Never loosen tolerances, clamp after the solve, accept an unclosed ledger, or add new "publish best-bounded" deviations.
- DEEPSEEK never rules on its own work. CLAUDE alone decides intentional deviations (DEV-NNN), legacy-inconsistency claims and architecture; DEEPSEEK records those decisions.
- **Loop guard**: Qwen3.5 is small and can get stuck in loops. Signs include:
  - the same command, edit or error 3+ times;
  - re-reading the same files without new findings;
  - edits that oscillate (applied, reverted, re-applied);
  - repeated output;
  - no new evidence for ~20 min;
  - idle without handoff.

  When CLAUDE sees these, it **pokes** DEEPSEEK: a short guidance file `.agent/pokes/poke_RRRRR_K.md` with the next concrete step, delivered by interrupting the DEEPSEEK pane through Herdr. On a poke, DEEPSEEK drops its current approach, follows the guidance, and notes `Poke K acknowledged` in the round. If the round still makes no progress after a second poke, CLAUDE resets DEEPSEEK (`/clear`) with a narrowed directive; after a third, CLAUDE rules REVISE or REJECTED and splits the target.
- **Goal**: Full 30-year Ottawa run for `ecosys-ng` with **zero science gap** and **scientifically comparable outputs** against legacy Fortran.
- **Continuous Execution**: There are no artificial stopping hooks or early halting gates. The loop proceeds until the finish line is reached.

### Project Rules
- Protected references: `f77src/` (read-only reference), `f77example/`, `ecosys-ng-prod-examples/`.
- Never edit Fortran reference files directly; inspect using `uv run ecosys-audit/scripts/f77query.py` or targeted analysis tools.
- Physics traps: Legacy Fortran is `-r8 -i4` (all implicit reals are f64); column-major array indexing often starting at 0.
- All mass, energy, and nutrient balances (C, N, P, water, heat) must be strictly conserved.
- Active workflow state is tracked in `.agent/state.md` and adversarial records in `.agent/adversarial/`.
