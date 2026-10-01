## Workflow: Worker/Judge Adversarial Loop (DEEPSEEK works, CLAUDE judges)

This project operates on an adversarial workflow between two models hosted on the **same Herdr tab in multi-pane** (`ADVERSARIAL` tab: `CLAUDE` on left, `DEEPSEEK` on right):
1. **DEEPSEEK** (`local/qwen3.8-35b-a3b-distill`, local llama.cpp at `127.0.0.1:8090` via the DeepSeek Harness): **main worker** — investigation, Zig implementation, tests and runs.
2. **CLAUDE** (`claude-opus-5-5`): **reviewer, critic, supervisor, idea generator, and judge**. CLAUDE writes each round's directive, reviews DEEPSEEK's work, and ends the round with `**Final Ruling (CLAUDE)**: APPROVED | REVISE | REJECTED`. **CLAUDE's decision is final.** CLAUDE does not edit production source.

### Autonomous Adversarial Loop
- Round cycle: CLAUDE directive (§0) → DEEPSEEK work + evidence (§1–§2, optional one-time objection §3) → CLAUDE review & final ruling (§4).
- Only APPROVED rounds are committed and pushed; REJECTED changes are reverted by DEEPSEEK before new work; REVISE points are fixed in the next round.
- Intentional deviations (DEV-NNN), "legacy is inconsistent" declarations, and science acceptance are decided by CLAUDE alone.

### Loop Guard: CLAUDE pokes DEEPSEEK when it gets stuck
Qwen3.8 is a small local model and can get stuck in loops. While a round is in progress, CLAUDE checks the DEEPSEEK pane (about every 10–15 min, and whenever the round stops moving) and **pokes** it with a new direction when it is stuck.
- **Loop signs**:
  - the same command, edit or error 3+ times;
  - re-reading the same files without new findings;
  - edits that oscillate (applied, reverted, re-applied);
  - repeated text in the pane or the round file;
  - no new evidence or file change for ~20 min;
  - idle without setting `AWAITING_RULING`.
- **Check**: `herdr --session ecosys-adversarial pane read <DEEPSEEK pane> --source recent --lines 80` (pane id from `herdr --session ecosys-adversarial pane list`, label `DEEPSEEK`).
- **Poke**: write `.agent/pokes/poke_RRRRR_K.md` (round R, poke K). Keep it short:
  - what loop was seen;
  - what to stop doing;
  - the single next concrete step, with the exact `file:line` or command;
  - when to hand off.

  Then interrupt and point DEEPSEEK at it:
  `herdr --session ecosys-adversarial pane send-keys <pane> esc` and
  `herdr --session ecosys-adversarial pane run <pane> "CLAUDE POKE: stop the current approach. Read .agent/pokes/poke_RRRRR_K.md and follow it."`
- **Escalation**:
  - 2nd poke in the same round without progress: reset DEEPSEEK (`/clear`), then send a narrowed directive.
  - 3rd: rule REVISE or REJECTED and split the target into smaller directives.
  - Context: Qwen has a 131k window (DEEPSEEK input budget ~96k, directives/pokes ≤ ~6k tokens). When the pane footer shows `ctx` ≥ 75%, reset with `/clear` and restate the directive.
- **Rules**: DEEPSEEK drops its current approach on a poke, follows the guidance, and notes `Poke K acknowledged` in §1. Pokes are guidance under CLAUDE's authority (final, like rulings). CLAUDE lists the pokes it sent in §4 of the round.
- Current state: `.agent/state.md`.
- Roster and roles: `.agent/roster.json`, `.agent/roles/claude.md`, `.agent/roles/deepseek.md`.
- Execution plan: `ecosys-ng_ottawa_qualification_execution_plan.md`.
- Adversarial rounds: recorded in `.agent/adversarial/round_NNNNN.md`.
- Orchestrator: `scripts/start-adversarial.sh` / `ecosys-audit/scripts/adversarial_runner.py`.

### Project Mission & Rules
- **Goal**: Full 30-year Ottawa run for `ecosys-ng` with zero science gap against legacy Fortran (`f77src/`) and outputs scientifically comparable to legacy Fortran outputs.
- **Continuous Dance**: No stopping hooks or artificial budget halts; the models iterate and challenge each other continuously until verified completion.
- **Protected directories**: `f77src/` (read-only reference), `f77example/`, `ecosys-ng-prod-examples/`.
- **Dialect facts**: Fortran legacy is `-r8 -i4` (all implicit reals are f64); arrays often 0-indexed and column-major.
- Strict conservation of mass, energy, and biogeochemical pools across all solvers and timesteps.
