# .agent — Worker/Judge Adversarial Control Plane

Continuous, token-frugal workflow between two models:
1. **DEEPSEEK** (`local/qwen3.5-35b-a3b`, local llama.cpp at `http://127.0.0.1:8090/v1` via the DeepSeek Harness `local` provider): **does all the work** — plans rounds, investigates, implements, builds, tests, runs, self-checks and keeps the ledgers.
2. **CLAUDE** (`claude-opus-5-5`): only **deep scientific diagnosis, cross-language reasoning, architecture decisions and the final scientific review**; makes the **final judgement call** and **directs and guides Qwen when needed**. **CLAUDE's decision is final.**

## Herdr Layout: Single Tab Multi-Pane
Both agents operate side-by-side in **the same Herdr tab** (`ADVERSARIAL`):
- **Tab Label**: `ADVERSARIAL`
- **Left Pane (`CLAUDE`)**: Claude Opus 5.5 — specialist, final reviewer and judge
- **Right Pane (`DEEPSEEK`)**: Qwen3.5-35B-A3B (local llama.cpp, DeepSeek Harness) — does all the work

Layout setup script: `scripts/setup-adversarial-layout.ps1` (or `.sh`).
Start DEEPSEEK in its pane with `scripts/start-deepseek.sh`. Herdr has no dsh integration, so the launcher also
runs `scripts/herdr-deepseek-status.ps1` in the pane. It registers the pane as Herdr kind `pi` (dsh is built on Pi;
Herdr drops custom kinds within ~3 s) under the name `deepseek`, with idle/working state. Starting `dsh` directly
leaves the pane unrecognized. Herdr cannot see dsh as the foreground process, so `herdr agent prompt deepseek` is
refused (`agent_not_ready`). Send input with `herdr pane send-keys` / `pane run` on the DEEPSEEK pane instead.
Runner script: `scripts/start-adversarial.ps1` (or `.sh`). `-Status` shows the latest round, its ruling, and whether the local model is served.

## Round Cycle (`templates/adversarial-round.md`)
1. **§0 Plan — DEEPSEEK**: picks the target (CLAUDE's last next target, the `state.md` frontier, or the execution plan); one bounded, falsifiable question, hypotheses, legacy ranges, done condition.
2. **§1–§2 Work, Evidence & Self-Check — DEEPSEEK**: implementation, tests, `receipt.json` citations, self-check (regressions, conservation, no tolerance/clamp change, traceability), ledgers updated; status `AWAITING_RULING`.
3. **§3 Escalation & Guidance — only when needed**: DEEPSEEK sets `ESCALATED` for deep diagnosis, cross-language semantics, architecture or DEV questions (or lodges one objection to a ruling); CLAUDE answers with guidance.
4. **§4 Final Scientific Review & Ruling — CLAUDE**: `**Final Ruling (CLAUDE)**: APPROVED | REVISE | REJECTED`, decisions, reasons, next target / guidance.
The runner polls the latest round for the ruling. **APPROVED** → commit and push, open the next round.
**REVISE** → no commit; DEEPSEEK fixes the listed points next round. **REJECTED** → no commit; DEEPSEEK reverts the
rejected change before new work. Rulings are not appealed; a closed point is reopened only with new evidence.

## Authority
- CLAUDE alone rules on rounds and decides intentional deviations, legacy inconsistencies, architecture and science
  acceptance. DEEPSEEK records those decisions (`audit/intentional-deviations.md`). CLAUDE does not write routine plans,
  implement, run routine tests, keep the books or edit production source; it guides DEEPSEEK when needed.
- DEEPSEEK never rules on, approves, or commits its own work.
- **Loop guard**: Qwen3.5 can get stuck in loops. CLAUDE watches the DEEPSEEK pane and pokes it with a new direction
  (`pokes/poke_RRRRR_K.md` + Esc + a one-line pointer via Herdr). Escalation: 2nd poke → `/clear` reset and a
  narrowed target; 3rd → REVISE/REJECTED. Rule and commands: `CLAUDE.md` (Loop Guard); settings: `roster.json` `loop_guard`.
- **Convergence & balance failures** (ReleaseFast run stalls): `playbooks/convergence-and-balance.md`. CLAUDE leads the
  strategy and teaches it to Qwen through Strategy Briefs. DEEPSEEK triages, applies the simple rungs, and escalates.
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
- `adversarial/`: Round files (plan, work, evidence, escalation/guidance, ruling).
- `roles/claude.md`: Role guidance for CLAUDE (specialist, final reviewer and judge).
- `roles/deepseek.md`: Role guidance for DEEPSEEK (does all the work).
