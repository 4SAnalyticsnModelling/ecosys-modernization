## Workflow: Worker/Judge Adversarial Loop (DEEPSEEK works, CLAUDE judges)

This project operates on an adversarial workflow between two models hosted on the **same Herdr tab in multi-pane** (`ADVERSARIAL` tab: `CLAUDE` on left, `DEEPSEEK` on right):
1. **DEEPSEEK** (`local/qwen3.8-35b-a3b-distill`, local llama.cpp via the DeepSeek Harness): **main worker** — investigation, implementation, tests and runs.
2. **CLAUDE** (`claude-opus-5-5`): **reviewer, critic, supervisor, idea generator, and judge**. **CLAUDE's decision is final.**

### Continuous Worker/Judge Loop
- Each round: CLAUDE writes the directive → DEEPSEEK does the work and reports evidence → CLAUDE reviews and rules `APPROVED | REVISE | REJECTED` (final; DEEPSEEK may lodge one evidence-backed objection before the ruling, never after).
- Only APPROVED rounds are committed and pushed. DEEPSEEK reverts REJECTED changes before new work and fixes REVISE points in the next round.
- DEEPSEEK never rules on its own work and never registers intentional deviations; CLAUDE does.
- **Loop guard**: Qwen3.8 is small and can get stuck in loops. Signs include:
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
