# ecosys-ng Ottawa Qualification — Concrete Execution Plan

Status: v4, REVIEWED — GPT-6 Astra verdict PASS (`audit/reviews/plan-ottawa-qualification-r4.md`), after
`-r1.md`, `-r2.md` and `-r3.md` (all REVISE). The PASS approves the plan only; it is not implementation or
release evidence. Awaiting user approval to execute. All findings accepted;
resolution map in §9.
Nothing in this plan is executed until the user says so.
Derived from `ecosys-ng_ottawa_autonomous_qualification_plan.md` (the "spec"; §N refers to it where
marked "spec §N"). Where this plan is silent, the spec governs. Date: 2026-09-25.

> **Addendum 2026-09-25 (user: the repository must be standalone).** Every `D:\ecosys-evidence\X` below
> means `evidence/X` inside this repository (git-ignored; manifests and schemas committed). See
> `evidence/README.md`. The P1 control plane and the P2 tool scaffolds are installed (`.agent/README.md`);
> this is preparation, not gate evidence. No phase gate has passed.
>
> **Addendum 2026-09-25 (user decision D9: "SAGE will make the decision for everything, no human
> intervention at all").** Every "user approves / user signs / HUMAN_REVIEW_REQUIRED / user replan" in this
> plan now reads "SAGE decides". §8 lists the former human review points and who decides each now. The
> controller never stops for a person (`.agent/README.md`). Qualification is **agent-qualified**, not
> human-signed; release notes must say so.

---

## 0. Why the current loop stalls

Every figure in this table is a **provisional inventory reading** that P0 re-verifies. This includes the
claim that the legacy 30-yr output is complete, which P0.3 checks by hash and horizon inventory before
it is used as evidence.

| Fact | Value | Source |
|---|---|---|
| Commits since 2026-09-01 | 375 | git log |
| Commits that moved the production frontier | 3 (b54e461, d25b327, c37e56d) | git log |
| Frontier | 3,288 accepted of 262,920 h (1.25%) | `audit/handoff.md` |
| One iteration | build 864–1,027 s + module suite ~2,350 s + run from hour 0 ~2,100 s ≈ 90 min | run-030, run-033..038 |
| Per production run | the first fatal event only (the run aborts) | run-0NN records |
| Production checkpoints | off, although whole-state day-granular checkpoint/restart exists and is unit-tested | run-033:17; `ecosys-ng/src/io/checkpoint/` |
| Survey (record-and-continue) mode | conservation breaches only; downstream values are contaminated | `conservation_survey.zig:1-22` |
| Legacy state for diagnosis | output files, plus `kernelgen.py` for one routine at a time | inventory |
| Static trace mapping | 31,095 / 46,739 statements mapped (66.5%); 80 / 367 rows unresolved; hashes stale (issue-081). Mapping ≠ correctness (`tracecov.py:300-303`) | `audit/traceability/coverage-2026-09-21.json` |
| Issues | 108 files; ~39 open; ~15 without a clear Status line (provisional count) | `audit/issues/` |
| Speed (provisional; P0 re-measures) | Zig ReleaseSafe 88–121 ms/h, ReleaseFast best 103 ms/h; gfortran 51 ms/h | run-021 |
| Legacy oracle binary and 30-yr output | exist only in a session scratchpad; not hashed | run-002:47 |

Root cause: **discovery is serial and crash-driven**, and each cycle runs inside one long, expensive
session. The plan changes three things:
- **Discover in batches**: an execution-path audit, one hourly legacy state oracle with a first-divergence
  diff, and survey ranking.
- **Test hypotheses on short replays**; the frontier is promoted only by a strict run.
- **Give mechanical work to cheap agents.**

---

## 1. Decisions recorded (user, 2026-09-25) — fixed

| ID | Decision |
|---|---|
| D1 | Science bar = **explained comparability**: every Ottawa-used legacy pathway accounted for with semantic evidence; outputs within per-variable rules fixed *before* comparison; every material deviation explained. Not bit-identity. |
| D2 | Intentional numerics (Newton/Anderson, Dall'Amico freeze-thaw, Mualem–van Genuchten) are **kept and attributed** by A/B runs. |
| D3 | Execution uses the **spec's 4-agent Herdr workflow** (SENTINEL, PATHFINDER, FORGE, SAGE). Claude and GPT only author and review this plan. |
| D4 | Performance = **full 30-yr Ottawa wall time**: ecosys-ng ReleaseFast < legacy gfortran `-O2`, same machine, median of 3 each side, outputs still passing parity. |
| D5 | Scope = **Ottawa milestone first**; remaining v1 gate-matrix items move to P8. |
| D6 | Deck edits (`9253d3b` runtime ceiling 100→200; `5add7de` starte.f:189) and the Zig solute iteration ceiling 60→200 (issue-015) are **kept only if justified from legacy**; otherwise reverted and root-caused. ~~The user signs the final list.~~ SAGE signs the final list (D9). |
| D7 | Build an **hourly legacy state oracle** (instrumented copy outside `f77src/`). |
| D8 | Push policy (user, 2026-09-25): **autonomous commit and push after every cycle** by the controller; production source only after a diff-bound SAGE APPROVE; never force. |
| D9 | Authority (user, 2026-09-25): **SAGE makes every decision; no human intervention at all.** Former human review points (§8) are SAGE decision tasks, decided by the rules D1–D8. A decision that changes accepted science or declares legacy inconsistent is final only after a second, independent SAGE session confirms it. |

---

## 2. Agent roster, routing, budgets

| Role | Harness / model | Owns | Never | Budget per task |
|---|---|---|---|---|
| SENTINEL | OpenCode, MAI-Code Flash | reads `.agent/state.md`, `frontier.json`, the latest result; writes one `dispatch.json` + task; escalation to SAGE (D9) | reads source, edits, runs jobs | ≤8 tool calls, ≤40k input tokens, 5 min |
| PATHFINDER | OpenCode, MAI-Code Flash | localization, `f77query.py`, divcheck reports, failure packets, trace triage, mechanical-change review | edits production source | ≤20 calls, ≤150k tokens, 30 min |
| FORGE | OpenCode, Gemini Flash | one bounded Zig change with a recorded hypothesis; T0–T1 | alters science semantics without SAGE; runs full Ottawa | one fix + targeted tests, ≤250k tokens, 60 min |
| SAGE | Claude Code, Claude Opus | science/numerics adjudication; **review gate for every production-science change before commit**; approves deviations, D6, rule table | broad repo search, builds, raw-log summarizing | one question; packet ≤25k tokens + targeted source/raw-evidence reads (spec §8); ≤200k total |

- **Budget enforcement.** The wrapper enforces time limits and records tokens when the harness reports
  them (`.agent/metrics.csv`). A task over its budget ends as STAGNATED, and the spec §11/§33 rules
  apply (3 rejected hypotheses or 2 failed implementations → stop and escalate).
- **Science review.** SAGE reviews each FORGE science change against its hypothesis file and packet, and
  may read the specific source ranges and raw evidence it names.
- **Mechanical review.** Tooling, tests and bookkeeping changes are reviewed by a fresh PATHFINDER
  session.
- **Deterministic gates** must also pass: `check_gate.py --gate <json>`, tests, and replay.
- **Cost reporting.** Headline metric = **cost per verified-frontier advance** (tokens and wall time).
  SENTINEL flags when SAGE handles more than 25% of tasks, or when cost per advance rises over two
  consecutive campaigns.

---

## 3. Reuse map — adapt, do not duplicate

| Spec item | Already exists | Action |
|---|---|---|
| Logging (spec §17) | `run_logged.py` (receipt.json, raw streams on disk, hook-enforced) | Keep; add the spec §17 `summary.json` fields |
| Gate bookkeeping | `check_gate.py --gate <JSON>` | Keep; register Ottawa gate schemas G0, G1, G2, GP, GQ |
| Task/seal protocol | `workflow.py` | Adapt so it writes `.agent/state.md`, `frontier.json`, `workflow.json` |
| Deterministic Herdr controller | `herdr_cycle.py` (file-backed, no model calls, fail-closed) | Evolve into `swarm-wrapper.py` |
| Output comparison (spec §26) | `outcompare.py` (hourly streams; does not prove completeness), `compare_outputs.py` (normalized input only) | Keep as cores; add raw adapters and completeness validator (P2) |
| Conservation (spec §27) | `conservation_survey.zig`, `hourly_cell_conservation.zig` | Keep; add positive controls (P2); extend survey to solver failures |
| Checkpoint/restart (spec §24) | `io/checkpoint/` (11 sections; counters `manifest.zig:29-38`; output-tree binding `:56-63`) | Enable in strict runs; add bundle-diff restart validator |
| Navigation | `f77query.py`, `tracecov.py`, `bindcheck.py`, `kernelgen.py` | Keep (PATHFINDER tools) |
| Skill pack | 16 `ecosys-*` skills in `.agents/skills/` (mirrored in `.claude/skills/`) | Keep; add the role→skill map |
| Handoff | `audit/handoff.md` | Migrate to `.agent/state.md` (P1.6) |
| `tools/*.sh` | — | Not created: the host is Windows/PowerShell. All tools are `uv run ecosys-audit/scripts/<tool>.py`, registered in `audit/manifest/command_registry.json` |
| Failure packet, divcheck, legacy state oracle, restart validator, frontier updater, output-completeness validator | missing | Build (P1/P2) |
| Ledgers (spec §20, §25) | traceability CSV (367 rows), issues/, runs/ | Adapt. Translation matrix = traceability CSV + spec §20 status column. Add `output-provenance.csv`, `intentional-deviations.md`, `unresolved-gaps.md` |

---

## 4. Phases and exit gates

- **Ordering.** No phase starts expensive work before the previous gate passes. ▲ marks a full 30-yr run;
  every ▲ is counted in §5.
- **Evidence binding.** Every run and checkpoint is bound to (source commit + dirty-diff hash, deck hash,
  build mode and options, checkpoint schema version, composite time key). Evidence produced under
  another binding is **provisional**.
- **Cross-revision diagnostic replay (the one exception).** A patched candidate may resume from a
  *strict* checkpoint of its parent binding, but only when all three hold:
  - the checkpoint schema version is unchanged;
  - the replay record names both the parent-checkpoint hash and the candidate hash;
  - the result is marked provisional-diagnostic.
  It can falsify or support a hypothesis. It can never promote the frontier. Survey checkpoints are
  never eligible.
- **Exclusive-machine lock.** A global lock held by the wrapper for every timing run and every campaign
  blocks builds, profiles and other jobs while it is held.

### P0 — Freeze, adjudicate inputs, baseline (G0)
1. Discover the actual Git state; do not assume `main` = `fd07795`. Preserve all dirty work on branch
   `wip/pre-plan-2026-09-25` (local, no push). **Needs user approval.**
2. **D6 deck adjudication first** (PATHFINDER packet, SAGE verdict and signature, D9). These edits change
   legacy inputs too, so every reference run waits for them. The Zig iteration ceiling (issue-015) is
   Zig-only; it is adjudicated here too, but only the deck result gates P0.4.
3. Move the legacy oracle binary and outputs into a hashed, git-ignored store `D:\ecosys-evidence\legacy\`,
   with a committed manifest (sha256, compiler, flags, argv, deck hash). Record the toolchain
   (zig, gfortran 16.1 with the `-r8 -i4`-equivalent flags, uv). ifort's absence is a recorded
   limitation.
4. ▲×3 legacy `-O2` uninstrumented timing runs on the final deck. The protocol is fixed:
   - exclusive-machine lock, same core affinity, same output set and drive, no checkpoints;
   - one discarded 1-simulated-day warmup immediately before each timed run (file cache and power state);
   - report median and spread.
   These are the D4 reference and the reference outputs.
5. Run `tracecov.py` to *report* stale hashes. Mappings whose source changed are re-reviewed before any
   hash is refreshed. Register the actual commands in the registry.
6. Normalize the Status lines of all 108 issues (tool-assisted) so the open set is exact.
- **Exit G0:** `check_gate.py --gate G0.json` PASS, with the evidence binding recorded.

### P1 — Control plane and wrapper (GP1)
1. `.agent/` layout (spec §5):
   - `state.md` ≤1,500 words;
   - `frontier.json` with `simulation_frontier`, `verified_frontier` and the evidence binding;
   - `workflow.json`, `dispatch.json`, `tasks/`, `results/`, `failures/`, `locks/`, `archive/`, `metrics.csv`.
2. `swarm-wrapper.py`, evolved from `herdr_cycle.py`:
   - launches each role as a fresh non-interactive session in its visible pane;
   - exact OpenCode/Claude headless flags and MAI-Code Flash / Gemini Flash availability under the Copilot
     provider are **verified in this task**;
   - timeouts, locks, child-process cleanup, `--resume`.
3. Wrapper-level hooks (the harnesses' own hook systems differ), each a deterministic step:
   - `zig fmt` + narrow compile after edits;
   - T1 after FORGE;
   - failure packet on failure;
   - archive + fresh SENTINEL after each task;
   - pre-commit gate;
   - **no push hook** (D8).
4. Role prompts (≤60 lines each): spec §39 context rules, per-role tool allowlist, MCP off.
   Role→skill map:
   - SENTINEL: none.
   - PATHFINDER: `ecosys-source-navigation`, `ecosys-divergence-diagnosis`, `ecosys-fortran-zig-traceability`.
   - FORGE: `ecosys-zig-safety-design`, `ecosys-validation-tests`, plus one subsystem skill named in the task.
   - SAGE: exactly one of `ecosys-process-science-parity` / `ecosys-conservation-audit` /
     `ecosys-nonlinear-solver-audit` / `ecosys-feature-attribution`, named in the task.
5. Wrapper test suite, required before autonomy:
   - happy path S→P→F→S(AGE)→S, killed pane + `--resume`;
   - stale result, duplicate delivery, permission-blocked agent, orphaned child process;
   - concurrent dispatch refused by lock;
   - a source change after SAGE review invalidates that review (review bound to the diff hash).
6. **Atomic protocol migration.**
   - Inventory every entry point that encodes the old Claude-lead/Pi-reviewer protocol: `CLAUDE.md`,
     `AGENTS.md`, `ecosys-audit/WORKFLOW.md`, `START_PROMPT.md`, the release-orchestrator and
     multi-agent-coordination skills (both mirrors), `.claude/settings.json` hooks, `.pi/`.
   - Migrate them in one reviewed change.
   - Retire the Pi lane and `herdr_cycle.py peer` only after item 5 passes.
- **Exit GP1:** the item 5 suite passes; migration diff reviewed by SAGE; the user approves the launch.

### P2 — Evidence infrastructure (GP2). Bounded runs only, except legacy ▲
1. **Hourly legacy state oracle** (D7).
   - Copy the in-build sources to `D:\ecosys-evidence\oracle-src\` and add one end-of-hour dump.
   - The dump has a schema file: composite time key (scene, repeat, year, day, hour), variable, units,
     shape, lower bound (0 or 1), column-major order, f64 only.
   - Curated set: per-layer water/ice/heat, C/N/P pools, NH4/NO3/PO4 including band zones, Ca/Na/K/Mg
     and other active salts, gases, root/plant pools, snow, surface.
   - An additional **initialization dump** (key `init`) is written after initialization is complete and
     before the first time advance.
   - **Non-perturbation proof:** the instrumented legacy standard outputs are byte-identical to the
     uninstrumented reference. ▲ legacy one run.
2. Matching Zig dump, including the `init` key, behind a build option; off in production and performance
   builds.
3. **`divcheck.py`**:
   - reports the first divergent (time key, variable, layer) and the earliest-N clusters by process group,
     using per-variable thresholds from the approved rule table;
   - self-test: an injected perturbation of known size, hour and variable is detected at exactly that
     point, over a 30-day window (bounded); the `init` comparison is part of the self-test.
4. **Ottawa execution-path map.**
   - Build the legacy oracle at `-O0 --coverage` (gcov) and ▲ run Ottawa once.
   - Validate gcov line attribution against f77index statement boundaries, including continuation lines.
     Ambiguous lines go into an explicit list for review.
   - Output: the set of legacy routines, branches and statements Ottawa executes.
5. **Survey extension.**
   - Record solver non-convergence (continue with the last iterate, tally it, flag the run as
     non-evidence). **SAGE approves (D9).**
   - **Positive controls:** each conservation sentinel and solver guard must fire on an injected fault in a
     bounded test. Zero breaches is meaningless without them (`conservation_survey.zig:63-69`).
6. **Output provenance and rule table** (`audit/output-provenance.csv`, spec §25–26):
   - drafted by SAGE per variable, covering structural exact fields, continuous metrics,
     event/seasonal/annual/cumulative rules and balance rules including active salts;
   - **approved by SAGE (D9) before any full Zig comparison**, and hash-bound so it cannot change after results are seen.
7. **Qualification validators:**
   - raw-output adapters for every legacy and Zig output file;
   - an expected-horizon and key inventory (no missing, duplicate or non-finite values);
   - an independent local and global balance checker for water, C, N, P, energy and active salts.
   Each validator is tested with synthetic bad inputs.
8. **Restart validator:**
   - Compare the full checkpoint bundle (all 11 sections, including counters and lagged/accumulator state)
     field by field between a continuous run and a resumed one, plus output-tree continuity.
   - Cover day, year and scene boundaries, with composite `--restart <scene,repeat,year,day>` keys.
   - Negative tests: corrupted, missing-section and mismatched-binding bundles are rejected.
   - **State-completeness check.** Every persistent Zig model-state field must either be serialized in
     some bundle section or appear on an explicit non-persistent allowlist that SAGE approves. The field
     list is enumerated at compile time (comptime reflection over the state structs), and `bindcheck.py`
     cross-references it against legacy COMMON.
   - **Isolated output-tree resume.** The resumed run writes to a fresh output tree. The validator checks
     that the prefix tree plus the resumed tree equals the continuous tree, with no gaps or duplicates at
     the seam.
   - Bounded windows only.
9. `run_ottawa.py` (modes strict | survey | dump, `--restart <key>`, daily checkpoints kept in
   `D:\ecosys-evidence\checkpoints\<binding>\`), `make_failure_packet.py` (spec §18 layout),
   `update_frontier.py`.
10. **Test tiering.**
    - T1 = filtered tests for the touched modules; target <2 min, measured.
    - T2 = subsystem suite.
    - The full module suite and both test roots run only at gates.
- **Exit GP2:** every self-test and positive control above passes, the rule table is approved, and the
  validators are tested. Recorded with `check_gate.py`.

### P3 — Ottawa-path science audit (G1). No full runs
The worklist is **every pathway on the P2.4 execution map, whether or not it is already mapped**:
- (a) executed but untraced statements;
- (b) executed and mapped statements, audited semantically (equation, branch, indexing, units, init,
  binding, coupling order), prioritized by risk;
- (c) Zig-only replacements (D2) with an attribution plan;
- (d) the 80 unresolved rows;
- (e) the open issues;
- (f) issue-106/107 (test-root failures).

Method:
- PATHFINDER takes one routine or process group per task and produces a verdict plus packet.
- The evidence for "mapped and correct" is `kernelgen.py` matched-state oracle agreement for that routine,
  or a SAGE-reviewed semantic argument. Mapping alone never counts.
- FORGE fixes follow the hypothesis contract; independent review as in §2.
- **Exit G1:** every executed pathway has a disposition (preserved / legacy-defect-corrected /
  approved-replacement / not-material with a SAGE-approved justification). Zero unresolved items on the
  execution map. Ambiguous gcov lines are resolved or explicitly approved.

### P4 — Integration readiness (G2). Bounded windows only
Checks that must pass before any Zig full run:
- initialization reconciled, with dump divcheck at hour 0;
- the first 30 simulated days in strict mode, with divcheck within rules;
- coupling and output semantics checked against the provenance table;
- restart validator passing on those windows;
- positive controls still passing;
- short replays across the known historical failure hours (2,578, 3,162, 3,253, 3,276, 3,289), from
  strict checkpoints.
- **Exit G2:** all of the above pass under one evidence binding.

### P5 — Batch dynamic campaign (G3)
One campaign is one strict run from hour 0 with dump and daily checkpoints (▲). It stops at the first
fatal event or runs to the end. Steps:
1. **divcheck report.** The earliest divergence is fixed before any later symptom. Where a fatal event
   occurs, the divergence before it is its likely cause.
2. **Localize and fix.** SENTINEL dispatches the earliest cluster. PATHFINDER packet → (SAGE if ambiguous)
   → FORGE fix → T1.
3. **Diagnostic replay.** Replay from the strict checkpoint just before the divergence for ≤7 simulated
   days; divcheck must show the predicted change (spec §15 falsification), otherwise revert.
   - Replays are **diagnostic only**: they cannot promote the frontier, since a fix may change state
     earlier than the checkpoint.
   - Eligible checkpoints: only the **cross-revision diagnostic replay** exception (§4 preamble). For a
     batch, the parent is the strict campaign that produced the checkpoint (the batch's
     checkpoint-producing ancestor), recorded in the replay record. Survey checkpoints are never
     eligible.
4. **Batching and extended replay.** Independent fixes accumulate. The next campaign starts when the
   worklist for the current divergence set is exhausted, or after 5 fixes. It also needs both:
   - every accumulated fix has passed its diagnostic replay;
   - the **combined** candidate has passed an extended replay (spec §22 T6), with divcheck within rules
     and no breach. The window runs from the parent strict checkpoint before the earliest touched
     divergence, for 60 simulated days or to the end of the Ottawa horizon, whichever comes first.
     Late-run repairs must replay through the horizon end.
   - **If the extended replay fails**, keep the failed-gate record and let PATHFINDER localize the new
     failure first:
     - a **regression** (divcheck shows the failure caused by a batch change) → bisect the batch;
     - an **independent defect** (the same failure is present in the parent binding over the same window)
       → queue it as a new bounded task, keeping the batch.
     Either way, no campaign runs until the combined candidate passes the window.
5. **Promotion.** `verified_frontier` = the last hour of the latest campaign where all of these hold:
   divcheck within rules, no breach, no solver fallback left unexplained, and checkpoints restart-equivalent
   by bundle diff, all under a single binding.
6. **Optional survey run** (▲, counted), only when a campaign dies early with no pre-fatal divergence. It
   ranks later breaches; its results are hints, never evidence.

Caps:
- Two consecutive campaigns without verified-frontier advance → SAGE decides a change of strategy (D9).
- The same failure signature twice → SAGE escalation.
- Hard cap 12 campaigns before a mandatory SAGE replan (D9).
- Survey runs: at most 1 per 3 campaigns.
- Elapsed-time cap: 5 wall-clock days without a verified-frontier advance → SAGE decides a change of
  strategy (D9), regardless of campaign count.
- D2 divergences are attributed by A/B over the local window (`ecosys-feature-attribution`) and recorded in
  `intentional-deviations.md`.
- **Exit G3:** one strict campaign completes 30 years with divcheck within rules or attributed, no breach
  and no fatal event.

### P6 — Performance (GP)
Profiling can start once P5 has at least one clean simulated year. Code changes land only between
campaigns, so the campaign itself re-verifies them.
1. Profile ReleaseFast over a fixed 1-year window (dump off) and rank hotspots.
2. A performance change must keep the dump **bit-identical** over the fixed window. Reorderings that change
   floating-point results need to stay within the rules and get SAGE sign-off. Either way it must pass
   the next campaign.
3. The expected gap is ~2x (provisional). Plan for algorithmic work (allocations in hot loops, solver
   workspace reuse, memory layout), not only compiler flags.
- **Exit GP:** hotspot work is done and the last campaign still passes. The 1-year extrapolation is
  **advisory only**: it decides when to schedule P7, not whether a candidate passes. D4 is decided solely
  by the P7 full-horizon medians.

### P7 — Frozen qualification (GQ; spec §35–37)
1. Freeze one candidate and do a clean build.
2. ▲ strict continuous run.
3. ▲ restart run: resume at a mid-run key and compare by bundle diff and output continuity.
4. ▲×3 ReleaseFast timing runs under the P0.4 protocol (the continuous run may count as one if its
   configuration matches; declared in advance).
5. Validators, rule table comparison, balances, event/seasonal/annual/cumulative comparison, restart
   evidence, D4 median-vs-median.
6. Write `validation/reports/ottawa-scientific-qualification.md`.

Any code change after freeze restarts P7.
- **Exit GQ:** every spec §37 criterion, recorded by `check_gate.py`; user acceptance.

### P8 — Remaining v1 gate matrix (deferred by D5)
Scene repeats, Linux compiles, parallel restart, 4 roots × 3 modes.

---

## 5. Full-run budget

| Phase | Legacy ▲ | Zig ▲ |
|---|---|---|
| P0 | 3 (timing) | 0 |
| P2 | 2 (instrumented dump; gcov) | 0 |
| P3–P4 | 0 | 0 |
| P5 | 0 | 1 per campaign (≤12), + survey runs only as in P5.6 |
| P6 | 0 | 0 (1-year windows) |
| P7 | 0 (reuses P0) | 5 (continuous, restart, 3 timing; the continuous run may count as a timing run) |

Every other full run needs a SENTINEL justification in `workflow.json` saying why a bounded replay cannot
answer the question. Jobs that need a full run are serialized (one ▲ at a time).

---

## 6. Storage budget
- Legacy dump: one reference set.
- Zig dumps: the latest 2 campaigns, plus any campaign cited as evidence.
- Strict checkpoints: the current binding, plus the previous binding until promotion.
- Survey checkpoints: deleted after ranking.

All of this lives under `D:\ecosys-evidence\` (git-ignored, manifest-hashed). The wrapper refuses to start a
▲ if free space is below the projected need. Deletion of anything cited in `audit/` is forbidden.

---

## 7. Token-cost controls
1. Fresh session per task (spec §1.2); the §2 budgets are enforced by the wrapper.
2. SAGE gets packets and targeted reads, never broad search.
3. `.agent/state.md` ≤1,500 words; results follow the spec §14 contract; logs stay on disk; agents read
   `summary.json` first.
4. No auto-loaded memory, skills or MCP beyond the role map (spec §39).
5. Headline metric = cost per verified-frontier advance, reported each campaign.

---

## 8. Decision points (formerly "Human review points"; all SAGE since D9, 2026-09-25)
| # | Point | Decided by |
|---|---|---|
| 1 | P0.1: branch parking | done (user, 2026-09-25) |
| 2 | P0.2: D6 list | SAGE signs, by the D6 rule (keep only if justified from legacy, else revert and root-cause) |
| 3 | P1: launch approval | done (user, 2026-09-25; `autonomy_approved`) |
| 4 | P2.5: survey continuation policy | SAGE, within the §6 survey caps |
| 5 | P2.6: rule table | SAGE, fixed and hash-bound before any comparison (D1) |
| 6 | P5 caps triggered | SAGE decides the change of strategy; the swarm never waits |
| 7 | Legacy internally inconsistent / change alters accepted science | SAGE, confirmed by a second independent SAGE session |
| 8 | D8 push policy | done (user, 2026-09-25) |
| 9 | P7: final acceptance | SAGE, only when `check_gate.py` passes every gate; labelled agent-qualified |

---

## 9. Review resolution (R1 → v2)

| R1 finding | Resolution |
|---|---|
| B1 coverage ≠ verification | P2.4 gcov attribution validated; P3 audits executed *mapped* pathways too, with oracle/semantic evidence |
| B2 contaminated/stale replay | Evidence binding (§4 preamble); replays diagnostic only; promotion only by a strict campaign from hour 0; survey checkpoints are never replayed |
| B3 full runs before readiness | P2 Zig ▲ removed; new P4 readiness gate G2 before any Zig ▲; campaign caps |
| M4 baseline before D6 | D6 deck adjudication is P0.2, before reference runs; Git state discovered, not assumed |
| M5 oracle/restart underspecified | Dump schema with composite keys; restart = full bundle diff + output continuity + boundary and negative tests |
| M6 qualification evidence incomplete | P2.7 validators and P2.5 positive controls |
| M7 D4 budget and order | 3 legacy timing runs in P0; performance before the P7 freeze; 3 Zig timing runs on the frozen candidate |
| M8 migration incomplete | P1.5 wrapper test suite; P1.6 atomic entry-point migration |
| M9 wrong facts | tracecov reports (does not clear) stale hashes; `check_gate.py --gate <json>`; "one fatal event per run"; historical figures labelled provisional |
| m10 cost | per-role token/time budgets; cost per advance; storage budget §6 |
| R2 N1 replay vs binding | cross-revision diagnostic replay exception (§4 preamble) |
| R2 N2 performance proxy | 1-year extrapolation is advisory; D4 decided by the P7 medians only |
| R2 N3 init evidence | `init` dump key on both sides; part of the divcheck self-test |
| R2 partial 2/3 | extended combined-batch replay before each campaign; survey and elapsed-time caps |
| R2 partial 5 | comptime state-completeness check + allowlist; isolated output-tree seam check |
| R2 partial 7 | exclusive-machine lock covers all jobs; warmup policy |
| R2 partial 9 | §0 figures labelled provisional; legacy output completeness verified in P0.3 |
| R3 N1 leftover | P5.3 now points to the cross-revision exception and names the checkpoint-producing ancestor |
| R3 N4 late-run window | window capped at horizon end; failures classified as regression vs independent before bisecting |

---

## 10. Risks
| Risk | Mitigation |
|---|---|
| Dump volume | curated f64 vector, per-year files, retention per §6 |
| Instrumentation perturbs legacy | byte-identical output proof (P2.1) |
| Flash models make plausible but wrong science edits | hypothesis file; SAGE gate bound to the diff hash; falsifying replay; campaign promotion |
| D: drive I/O faults | time a D: read before long jobs; wrapper aborts on stall |
| Harness CLI or model availability differs | verified in P1.2 before autonomy |
| gfortran ≠ ifort | recorded limitation; precision contract `-r8 -i4` reproduced |
| Campaign count too high | caps in P5; cost per advance reported; user replan at 12 |
