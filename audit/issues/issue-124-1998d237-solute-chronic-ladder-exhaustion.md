# issue-124 — SoluteReactionSolverDidNotConverge FATAL at 1998 d237 h4 (total_hour 5668): chronic ladder exhausted (v10 trajectory)

## Status
OPEN — diagnosis in progress (fast offline replay lane LIVE, reproduces in seconds).

## Receipt (observed)
- Run: audit/runs/ottawa/cycle11-verify-v10-20261027 (binary 1a8b569147f6cce3, v7 carbon +
  issue-122 gate + issue-123 texture ulp-ladder completion; pristine from-scratch deck).
- After 5667 clean-accepted hours (zero conservation failures, zero texture-completion
  residual warns; all v8/v9 death zones passed): stderr lines 246368/246446
  `SOLUTE accepted-state conservation rejection reclassified as chronic non-convergence:
  cell=0 (issue-122)` (accepted-state charge failure before=6.477688749569778e2
  after=6.477688749360624e2 residual=-2.0915422282996587e-8) then
  `SOLUTE hourly reaction solver failed: cell=0 layer=0 packed_cell_index=0
  error=SoluteReactionSolverDidNotConverge` and
  `SOLUTE fixed-hour recovery attempt failed: exact_substep_count=64` ->
  `error: hourly science failed: ... scene_hour=5668 total_hour=5668 year=1998 day_of_year=237
  hour=4 error=SoluteReactionSolverDidNotConverge`. Engine EXITED 1.
- Hourly failure snapshots also exist for earlier hours (day200 h16, day211 h14, ...): chronic
  non-convergence CLUSTER at cell=0 in this season; earlier hours were ladder-recovered,
  5668 exhausted the full ladder (playbook-correct: never publish an unresolved iterate).

## Offline replay lane (seconds)
- Snapshot: evidence/runs/cycle11-verify-v10-20261027/deck/runottawa_output_files/logs/
  ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day237-hour4.bin
- Replay binary: .tmp/cycle121/ecosys_ng_replay_v124 (build-exe ReleaseSafe from the v10 tree,
  root src/replay_solute_failure.zig). `./ecosys_ng_replay_v124 <snapshot>` ->
  "SOLUTE replay failed reproducibly" + DidNotConverge (rc=1). Receipts:
  .tmp/cycle121/replay124.{out,err}.
- Trace facts: initial maximum_scaled_residual = 1.3243264725884006e12 carried by
  aqueous.hydrogen (state 9.132355551197398e-4, residual 1.222665286079919e1 -> state-relative
  1.3e12); closure=0 runs 24 iterations (limiter churn: carboxyl_bound_hydrogen_mol_per_megagram
  90 -> phosphate pairs 59 -> ...), closure=1 restarts and dies after 2; other large residuals
  phosphate_non_band.deprotonated_site 3.14 (state 5.79), bicarbonate 4.2e-1.

## Trajectory note
- NOT pre-existing on the v7/v8/v9 trajectories (0 exhaustions through 789 d in cycle-10 gated
  run; v8 died earlier at 5848 before this hour; same-hour forcing existed but solver state
  differed). The completion fixes intentionally shift trajectory by ulps from the first rewrite
  hour (documented chaos, D-6/D-14 precedent), surfacing this solver-capability defect at 5668.
- The accepted-state charge residual signature (-2.09e-8, cell=0) matches the issue-118/122
  packed-block excursion family; the issue-122 gate did its job (reclassify, never publish);
  the FATAL is the ladder correctly refusing to publish after exhausting its schedule.

## Fix policy (leader)
Root-cause the non-convergence per the numerical recovery playbook (diagnose actual progress;
fix the diagnosed cause; NO relaxation of acceptance bands or publication of unresolved
iterates). Hypotheses under test (see durable notes): (a) hydrogen state-relative residual
normalization blows up at pH 3.7 states (scaling defect), (b) solver iteration budget does not
scale with ladder substep count (64 substeps x same cold budget cannot resolve), (c) upstream
unbooked writer leaves inconsistent sorption state (carboxyl/phosphate sites) so no iterate can
satisfy charge closure.

## Resolution
PENDING.

## Root cause (VERIFIED 2026-10-29, TEMP124 probe ladder + code map)
- TEMP124 phase bracketing (replay lane): entry net 6.477688749569778e2 -> after phase-0
  (pre-kinetic equilibrium) net 6.477688749360627e2; kinetics delta exactly 0; phase-1 delta
  3e-13. The whole -2.0915e-8 mol charge m^-3 leak is created INSIDE the equilibrium loop.
- TEMP124C per-iteration census: iterations 0..19 hold the entry census (+-1 ulp); the single
  commit at iteration 19->20 moves net by exactly -2.0915e-8. Trace: committing candidate =
  anderson_depth_two. Water projection EXONERATED (equal_reaction_extent=0e0, net unchanged;
  water_equilibrium.solve preserves the activity difference exactly and is charge-safe).
- Mechanism (code): retainMeaningfulAndersonCandidate is MERIT-ONLY; the vector-space mix is
  linear in the PACKED vector but the charge census is computed after unpackCell, which
  rewrites guard-coupled components -> a mix off the guard manifold leaks. Newton/surface-
  charge probes are census-gated before commit (reaction_solve.zig:1838 family) and
  retainBestBoundedIterate censuses, but the per-iteration COMMIT chokepoint (@memcpy(current,
  best_state)) had no census: a leaking iterate became the committed lineage. The solver then
  CONVERGED (physical accept) onto a root its own accepted-state publish census must reject ->
  every ladder rung converge-then-rejected -> ladder exhausted -> fatal at rung 64. The two
  "(issue-122)" reclassifications that hour are this signature; the gate itself behaved
  exactly as designed (never publish a leaking iterate).
- Fork code map corroborates: budget NOT binding (26 iterations << 100 per closure; ladder
  schedule {1,2,4,8,16,20,32,64} carries no budget sharing); H3 (more iterations) REFUTED -
  fixed binary with 1000 iterations runs the full budget and still fails (DidNotConverge,
  no leak): the full-hour solve is genuinely hard; recovery is the ladder's job and was being
  poisoned by the wrong-root trap.

## Fix (leader; shipped in v11 candidate)
- reaction_solve.zig: committedIterateCensusPassed(...) at the single per-iteration commit
  chokepoint. Closure = IDENTICAL to retainBestBoundedIterate/terminal publish (aqueous
  molarity, elemental inventories, charge census, carboxyl capacity); leaking best-of-
  iteration candidate is NOT committed (stays a private search probe; committed lineage and
  its scratch view are reloaded and preserved; stagnation guard bounds the loop). NO gate,
  limit or tolerance changed; publish/accepted tiers untouched; issue-118 doctrine enforced
  uniformly across candidate classes (its own test name: leaking iterates are not retained).
- Observable effect (offline, day237 h4 fixture): census invariant holds every iteration
  (net constant through all 42 iterations); terminal class changes from wrong-root publish
  rejection to HONEST ladder-eligible non-convergence (Stagnated at 100 iterations) - the
  per-substep ladder entries at finer rungs start nearer equilibrium, which is exactly the
  situation the ladder (and DEV-011 census-clean best-bounded publish) exists to resolve.

## Regression test (discriminating, VERIFIED both ways)
- src/soil/solute/testdata/ottawa_day237_hour4_layer0_issue124.b64 (production snapshot).
- reaction_solver_tests.zig "issue-124 committed iterates keep the entry charge census...":
  solves the fixture, asserts the raw accepted-state conservation class never surfaces from
  the solver AND the final committed iterate (workspace.current) passes the entry charge
  census. WITH fix: pass. Fix surgically removed: test FAILS via
  requireConservedStates -> SoluteReactionAcceptedStateConservationFailure (the -2.09e-8
  leak), 51/52 -> receipt in session. 

## Resolution
- v11 shared from-scratch verification (deck evidence/runs/cycle11-verify-v11-20261029):
  must show exactly 1 "(issue-122)" reclassification-free chronic cluster behaviour through
  5668 (no ladder exhaustion), pass the 1999 d230 clay zone and frontier total_hour 18939,
  campaign EXITED 0. Mark RESOLVED when that run passes.

## Batch sweep (39 sampled chronic-cluster snapshots, old vs fixed binary, .tmp/cycle121/batch124.txt + batch124_redo.txt)
- 19x SoluteTraceCapacityExceeded -> same; 10x DidNotConverge -> same; 9x Stagnated -> same;
  1x DidNotConverge -> Stagnated. ZERO new error classes; classes are unchanged because the
  fix is a CORRECTNESS fix (kills the converge-onto-wrong-root trap), not a convergence
  accelerator. All fixed-binary classes are ladder-survivable: these same hours/days were
  recovered by the ladder during the v10 campaign up to 5668 with these very snapshot states.
- The distinguishing behaviour is at the trap hour itself: old binary converges then publish-
  rejects on EVERY rung (rung 64 -> fatal); fixed binary returns honest non-convergence so the
  ladder's finer rungs (fresh substep states, closer to equilibrium) can accept - as they did
  for the other ~1335 chronic-cluster hours of this campaign (all recovered except 5668).
