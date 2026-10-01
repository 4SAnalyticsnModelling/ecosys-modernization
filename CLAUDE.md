## Workflow: Worker/Judge Adversarial Loop (DEEPSEEK works, CLAUDE judges)

This project operates on an adversarial workflow between two models hosted on the **same Herdr tab in multi-pane** (`ADVERSARIAL` tab: `CLAUDE` on left, `DEEPSEEK` on right):
1. **DEEPSEEK** (`local/qwen3.8-27b`, local llama.cpp at `127.0.0.1:8090` via the DeepSeek Harness): **does all the work**.
   - Plans each round.
   - Investigates, implements Zig, builds, tests and runs.
   - Self-checks conservation and traceability.
   - Keeps `.agent/state.md` and the `audit/` ledgers.
2. **CLAUDE** (`claude-opus-5-5`) does **only** the following:
   - **deep scientific diagnosis**;
   - **cross-language reasoning** (Fortran → Zig);
   - **architecture decisions**;
   - **final scientific review**.

   It also makes the **final judgement call** (`**Final Ruling (CLAUDE)**: APPROVED | REVISE | REJECTED`) and **directs and guides Qwen when needed**. **CLAUDE's decision is final.** CLAUDE does not write routine plans, implement, run routine tests, keep the books, or edit production source.

### Autonomous Adversarial Loop
- **Round cycle**:
  1. DEEPSEEK plan (§0);
  2. DEEPSEEK work, evidence and self-check (§1–§2);
  3. *if needed*, an escalation to CLAUDE with status `ESCALATED` (§3), which CLAUDE answers with guidance;
  4. CLAUDE final scientific review and ruling, with the next target (§4).
- **Escalate only for**:
  - deep diagnosis: a divergence or conservation failure still unexplained after 2 serious hypotheses;
  - cross-language semantics: COMMON/EQUIVALENCE, implicit `-r8 -i4`, indexing, SAVE/DATA, GOTO flow, intrinsic precision;
  - architecture: solver design, module boundaries, state ownership, any DEV-NNN or legacy-inconsistency claim;
  - being stuck in a loop.

  Builds, readable test failures, refactors, bookkeeping and tooling are never escalated.
- Only APPROVED rounds are committed and pushed; REJECTED changes are reverted by DEEPSEEK before new work; REVISE points are fixed in the next round.
- Intentional deviations (DEV-NNN), "legacy is inconsistent" declarations, architecture changes and science acceptance are decided by CLAUDE alone; DEEPSEEK records them.

### Convergence & Balance Failures: CLAUDE leads the strategy
The ReleaseFast Ottawa run currently cannot progress further because of convergence failures: either the mass/energy balance does not close, or the Newton/Anderson solve does not converge. Recent examples are frozen-topsoil and phase stagnation, and stiff high-pH solute chemistry. **CLAUDE leads here as supervisor**: it diagnoses the failure, picks the strategy, and teaches Qwen to apply it. The full playbook, built from how SUMMA, CLM5, PFLOTRAN/ATS, HYDRUS, GEOtop and SUNDIALS handle these failures, is `.agent/playbooks/convergence-and-balance.md`. Its core rules:
- **Legacy never iterates.** Legacy ecosys steps each hour explicitly through fixed sub-cycles (`NPH=NPX` per hour, plus nested gas/litter/snow cycles; `wthr.f:589-611`). Our Newton/Anderson solves are intentional numerics, so a non-converging hour is a defect in our formulation. The legacy trajectory is the oracle.
- **Rule out bugs before any solver strategy (DEEPSEEK).** For the routines that touch the failing hour, check in order, and record each check as PASS or FAIL with `file:line`:
  1. **science**: the equation differs from legacy;
  2. **translation**: indexing, loop bounds, implicit typing, GOTO flow, SAVE/DATA, update order;
  3. **binding**: a COMMON variable mapped to stale, uninitialized or zero Zig state, or the solver and the ledger reading different state;
  4. **duplication**: the same flux, source, sink, transfer or conversion applied twice, or state copies out of sync;
  5. **floor bounds**: every guard must use the legacy floor. The legacy floors are:
     - `0.0`;
     - `ZERO`=1e-15 and `ZERO2`=1e-6;
     - cell-area-scaled `ZEROS`/`ZEROS2`=`ZERO*DH*DV`/`ZERO2*DH*DV`;
     - plant-population-scaled `ZEROP`/`ZEROQ`/`ZEROP2`, which are **recomputed daily** from PP;
     - routine-local `ZEROC`, which is **1e-32 in SOLUTE but 1e-48 in STARTE**.

     For each guard, check:
     - the comparison operator and compared variable (`AMAX1(ZERO,X)` is not `IF(X.GT.ZERO)`);
     - the units;
     - the placement: no floor moved into an implicit residual or Jacobian, and no unbooked clip.

     At Ottawa the cell area is 1 m², so a literal `1e-15` matching `ZEROS` is a coincidence, not parity. The Zig code hard-codes ~1,470 `1e-15` and ~500 `1e-6` literals, so map each guard on the failing path to its legacy line (playbook §1b).

  A FAIL is fixed first. Numerical strategies start only after all four pass.
- **Triage first (DEEPSEEK)**:
  - build a diagnostic packet: hour, substep, solver, layers, state and thresholds, residual/increment history, NaN, smallest pivot;
  - replay the failing hour in **ReleaseSafe and Debug** (ReleaseFast hides out-of-bounds/overflow/`unreachable` as undefined behaviour, so a difference means a bug);
  - finite-difference-check the Jacobian;
  - classify as A bug / B threshold crossing / C degenerate-stiff / D oscillation / E balance leak.
- **Strategy ladder**:
  - S1 converge on the mass/energy residual, with scaled tolerances;
  - S2 conservative mixed form with chord-slope capacities and enthalpy;
  - S3 Newton line search and per-iteration update caps;
  - S4 split the step at the freezing point T*, use maximum heat capacity (C-max), freezing = drying;
  - S5 Picard/L-scheme first, then Newton; Anderson with small depth, restarted when the residual rises, safeguarded;
  - S6 reject the step, cut Δt ×0.25–0.5, retry, regrow slowly, align substeps with forcing events;
  - S7 per-layer scaling, no single absolute tolerance on slivers or frozen-dry layers;
  - S8 split the heat–water solve in legacy order;
  - S9 last rung: run that hour with the legacy explicit sub-cycles, and count those hours as a metric to drive to zero.
- **Who does what**: DEEPSEEK applies S1–S3, S6 and S7 itself. CLAUDE chooses S4, S5, S8 and S9, and any DEV, and briefs it as a **Strategy Brief** in §3, with these parts:
  1. class and evidence;
  2. chosen rung and why;
  3. exact steps;
  4. acceptance test;
  5. what not to do.

  CLAUDE then appends a one-line **Lesson** to the playbook.
- **Forbidden**:
  - loosening tolerances or raising iteration/step ceilings to pass (except a ceiling justified from legacy);
  - post-solve clamps;
  - accepting a non-converged state whose ledger does not close;
  - new "publish best-bounded endpoint" deviations (DEV-009/011/014/015 style; existing ones are debt to retire);
  - silent retries.
- **Metrics in every solver round**: iterations per hour, substep cuts, S9 fallback hours, max balance residual, ReleaseFast wall time per simulated day.

### Loop Guard: CLAUDE pokes DEEPSEEK when it gets stuck
Qwen3.8 is a small local model and can get stuck in loops. While a round is in progress, CLAUDE checks the DEEPSEEK pane (about every 10–15 min, and whenever the round stops moving) and **pokes** it with a new direction when it is stuck.
- **Loop signs**:
  - the same command, edit or error 3+ times;
  - re-reading the same files without new findings;
  - edits that oscillate (applied, reverted, re-applied);
  - repeated text in the pane or the round file;
  - no new evidence or file change for ~20 min;
  - idle without setting `AWAITING_RULING`.
- **Check**: `herdr --session ecosys-adversarial pane read <DEEPSEEK pane> --source recent --lines 80` (pane id from `herdr --session ecosys-adversarial pane list`, label `DEEPSEEK`; DEEPSEEK must be started with `scripts/start-deepseek.sh` so Herdr lists it as agent `deepseek`). Use the `pane` commands below, not `herdr agent prompt deepseek`, which Herdr refuses because it cannot see dsh as the pane's foreground process.
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
