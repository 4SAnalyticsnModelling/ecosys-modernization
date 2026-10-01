# .agent — Worker/Judge Adversarial Control Plane

Continuous, token-frugal workflow between two models:
1. **DEEPSEEK** (`local/qwen3.8-35b-a3b-distill`, local llama.cpp at `http://127.0.0.1:8090/v1` via the DeepSeek Harness `local` provider): **main worker** — investigation, implementation, tests and runs.
2. **CLAUDE** (`claude-opus-5-5`): **reviewer, critic, supervisor, idea generator, and judge**. **CLAUDE's decision is final.**

## Herdr Layout: Single Tab Multi-Pane
Both agents operate side-by-side in **the same Herdr tab** (`ADVERSARIAL`):
- **Tab Label**: `ADVERSARIAL`
- **Left Pane (`CLAUDE`)**: Claude Opus 5.5 — judge
- **Right Pane (`DEEPSEEK`)**: Qwen3.8-35B-A3B-Distill (local llama.cpp, DeepSeek Harness) — worker

Layout setup script: `scripts/setup-adversarial-layout.ps1` (or `.sh`).
Runner script: `scripts/start-adversarial.ps1` (or `.sh`). `-Status` shows the latest round, its ruling, and whether the local model is served.

## Round Cycle (`templates/adversarial-round.md`)
1. **§0 Directive — CLAUDE**: one bounded, falsifiable target, ranked hypotheses, legacy ranges, required evidence, done condition.
2. **§1–§2 Work & Evidence — DEEPSEEK**: implementation, tests, `receipt.json` citations; status `AWAITING_RULING`.
3. **§3 Objection — DEEPSEEK (optional)**: one evidence-backed objection, before the ruling only.
4. **§4 Review & Final Ruling — CLAUDE**: `**Final Ruling (CLAUDE)**: APPROVED | REVISE | REJECTED`, reasons, next directive.

The runner polls the latest round for the ruling. **APPROVED** → commit and push, open the next round.
**REVISE** → no commit; DEEPSEEK fixes the listed points next round. **REJECTED** → no commit; DEEPSEEK reverts the
rejected change before new work. Rulings are not appealed; a closed point is reopened only with new evidence.

## Authority
- CLAUDE alone rules on rounds, registers intentional deviations (`audit/intentional-deviations.md`), declares legacy
  inconsistencies, and accepts science. CLAUDE does not edit production source; it directs DEEPSEEK.
- DEEPSEEK never rules on, approves, or commits its own work.
- **Loop guard**: Qwen3.8 can get stuck in loops. CLAUDE watches the DEEPSEEK pane and pokes it with a new direction
  (`pokes/poke_RRRRR_K.md` + Esc + a one-line pointer via Herdr). Escalation: 2nd poke → `/clear` reset and a
  narrowed directive; 3rd → REVISE/REJECTED. Rule and commands: `CLAUDE.md` (Loop Guard); settings: `roster.json` `loop_guard`.
- Write lanes are listed per role in `roster.json`.

## Objective
Achieve the complete 30-year Ottawa run for `ecosys-ng` with **zero science gap** against legacy Fortran (`f77src/`) and **scientifically comparable outputs**.
The loop continues without stopping hooks until this finish line is reached.

## Token Frugality Policy (Strict)
- Never paste raw simulation logs or whole source files into prompts or rounds.
- Use pointer citations (`file:line` and short sha256).
- Use `f77query.py` and targeted ripgrep rather than bulk file reading.
- Limit round reports to <= 500 concise words.
- All heavy builds/tests write logs to disk via `run_logged.py`, citing only `receipt.json`.

## Key Files
- `roster.json`: Model configuration, authority rules, write lanes, layout and token frugality settings.
- `state.md`: Current state and milestone tracking (curated by CLAUDE; the runner only rewrites its `runner:begin/end` block).
- `adversarial/`: Round files (directive, work, evidence, objection, ruling).
- `roles/claude.md`: Role guidance for CLAUDE (reviewer/judge).
- `roles/deepseek.md`: Role guidance for DEEPSEEK (main worker).
