# Cycle 00008 gate evidence digest — issue-118 retain-gate rejection is non-retention, not a fatal hour abort

Candidate: ReleaseSafe binary sha256 46818c5213d6fe1cb32899f2381003bdbd97405cc7a42c205259775a2aebeb13
(deck copy == install artifact, verified identical by shasum at close; identity is source+toolchain
pinned — commit 7dd6740, zig 0.17.0; Mach-O LC_UUID makes relinks differ byte-wise, so equivalence is
claimed at output level, per the cycle-6 linker-nondeterminism disclosure).
Fix (guard-channel only): retainBestBoundedIterate (soil/solute/reaction_solve.zig) converts the three
eligibility validations (inventory closure, charge conservation, carboxyl capacity bound) from fatal
error propagation (SoluteReactionAcceptedStateConservationFailure through the hard-try loop) into
non-retention (return false; diagnostic warnings kept). Root cause (VERIFIED via replay census probes,
logs/issue118-probes.patch): an iteration-52 anderson_depth_two Picard-extrapolation candidate carried
+4.2306602665576065e-11 N and advanced the BASE vector unchecked (@memcpy(current,best_state)); the next
iteration's retain read the poisoned base and threw. Publish tier (acceptBestBoundedIterate re-check,
legacy-parity "published best bounded iterate" path) and per-accepted-substep tier
(requireAcceptedStateConservation) keep hard-error semantics. No tolerance, gate or physics change.

## G1 builds (Zig 0.17.0)
- zig build install -Doptimize=ReleaseSafe RC=0; deck binary == install artifact (sha above, both paths
  shasum-verified at close); test-module Debug + ReleaseSafe compile+run RC=0 (logs/zig-build-test-module-*.log).

## G2 suites (fresh at close)
- Test binaries of both cached configurations executed directly: 4,406 passed; 1 skipped; 0 failed each
  (logs/gate-suite-direct-testbin-both-configs.log). +1 test vs cycle-7's 4,405 = the new discriminating
  issue-118 test (nitrogen-leaking iterate not retained, entry untouched); the two pre-existing Al/Fe and
  proton-leak assertions updated expectError -> expect(!retained) to match the new channel.
- Disclosure: zig build run-steps report "cached" at close (content-identical to the previous session's
  real executions, RC=0); the direct binary executions above are the live receipts.

## G3 conservation beyond solver residuals (from scratch, pristine "Cool Temperate Maize-Soybean ON" deck)
- Run audit/runs/ottawa/cycle8-verify-candidate-20261023 (receipt EXITED exit_code=1 — it stopped at the
  NEXT defect, issue-119 InvalidPlantInventory at 1999 d286; disclosed): zero
  SoluteReactionAcceptedStateConservationFailure, zero "fatal at total_hour", zero
  HourlyPlantConservationFailure; 1,896 accepted conservation ledger lines.
- Fix channel live in field: 46 warning-level "retained-state inventory failure" lines (stderr.log:74798
  ..74846, all inside the 1999 d193 window — cycle-7 had exactly 1 such line and it was fatal); 253
  "published best bounded iterate" legacy-parity publications through d285 (cycle-7 through its frontier:
  222). Error-class census vs cycle-7: no new class except InvalidPlantInventory (issue-119); the chronic
  n_ledger/at_evaluate, DEV-021 cap and heat-stagnation diagnostics are pre-existing classes.

## G4 legacy semantics
- f77src/solute.f: MRXN=60 fixed-iteration SOLUTE publishes the LAST iterate with no accepted-state
  conservation guard (grep CONSERV empty); Zig retains guard at publish/substep tiers and now merely
  declines to retain non-eligible iterates — movement toward legacy publish semantics, not away. No
  floor/scale touched.

## G5 parity
- All 34 modelled-output files / 99,187 rows written by the cycle-7 verified run (through 1999 d192, the
  last row cycle-7 wrote before its fatal) are BIT-IDENTICAL in the cycle-8 deck outputs
  (python diff, row-by-row, at close). First divergence = cycle-8-only rows after 1999 d193 h2 (new
  territory; the fix can only change behaviour from the previously-fatal hour onward — the field log had
  exactly one retain-channel rejection, cycle-7 stderr seq 74798). Cycle-8 deck wrote 101,700 rows
  through 1999 d285 at exit.

## G6 no forbidden workarounds
- No DEV row required (guard channel moves toward legacy; outputs unchanged through d192 proven by G5);
  no gate/tolerance loosening (tolerance formulas untouched; the discriminating test proves the guard
  still rejects the leaking iterate — it is simply not a hour-abort).

## G7 decisive numbers reproduced; restart-fidelity caveat
- Pre-fix: offline replay of the auto-written snapshot year1999-day193-hour2.bin reproduces
  SoluteReactionAcceptedStateConservationFailure exactly (logs/replay118-prefix-reproduces-fatal.log).
  Post-fix: trace-harness replay no longer aborts on conservation (SoluteTraceCapacityExceeded = replay
  tool buffer, engine iterates to max 99+); --production replay yields chronic
  SoluteReactionSolverDidNotConverge (ladder-managed class, 222-hour precedent;
  logs/replay118-postfix-production.log).
- Restart-fidelity: all verification from scratch (deck-restored state diverges; cycle-7 finding). The
  deck evidence/runs/cycle8-verify-candidate-20261023/deck is CONSUMED.

## G7b disclosed residuals (backlog, no new gates)
- issue-119 InvalidPlantInventory 1999 d286 registered for cycle 00009 (audit/issues/issue-119-*.md).
- Check-side reference drift: commitAcceptedWaterEquilibriumProjection writes state.unpackCell into the
  caller-visible state (reaction_solve.zig:94) making attempt-2's check baseline drift ~6 ulp from
  attempt-1's entry; benign at observed magnitude, hygiene concern only (kept in issues.md).
- Default replay harness trace buffer (max_iterations+2) under-sizes when the engine legitimately
  iterates to max; candidate for a follow-up tooling issue.

## G7/G9
- doc_consistency.py consistent:true (re-checked pre-close); this digest + receipts bind every claim;
  close stages owned paths only. All logs, decks, caches repo-local.

## G8 (remote equality)
- Push at close; HEAD==origin/main verified after push (recorded in cycle.json close entry).
