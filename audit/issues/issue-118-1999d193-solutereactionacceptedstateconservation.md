# issue-118: SoluteReactionAcceptedStateConservationFailure at 1999 d193 (post-issue-117 frontier)

Status: OPEN (registered cycle 00007; fix scope = cycle 00008).

Evidence (audit/runs/ottawa/cycle7-verify-candidate-20261022/stderr.log):
- 74798: SOLUTE retained-state inventory failure: inventory=nitrogen_mol_per_m3
  before=1.6103856504600056e0 after=1.6103856505023122e0 residual=4.2306602665576065e-11
  limit=7.358943829275302e-13 (cell=0 layer=0)
- 74799: SOLUTE hourly reaction solver failed: cell=0 layer=0 error=SoluteReactionAcceptedStateConservationFailure
- 74801: fatal at total_hour=13370 year=1999 day_of_year=193 hour=2 (scene_hour 4610, exec 1 scenario 1 scene 2)
- preceding warnings: phosphate site reconciliation rejected nonconservative transformation
  (residual ~-4.4e-20 vs envelope 1.3e-20 - borderline rounding class).

Context: first defect encountered after issue-117 advanced the trajectory from 1999 d140; distinct from the
resolved solute translation defects (issue-113/114) and from the recorded h2173 legacy solver stall. The
residual (4.2e-11 against ~1.6 mol/m3 inventory) is a near-zero signed defect class -> follow
.agent/playbooks/convergence-and-balance.md: diagnose cause before any scale/floor change; preserve gates.
Frontier: h13369 (last accepted hour, 1999 d193 h1).

## Resolution (cycle 00008)

Root cause (VERIFIED via offline replay census probes on the auto-written failure snapshot
`ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene2-year1999-day193-hour2.bin`):

1. The hour's reaction solve is a chronic non-converged solve (limiter aqueous.aluminum, stalled
   Newton crawl). Search iterates are legitimate non-conservative points; only publication is
   guarded (accepted-state tier + best-bounded publish re-check).
2. Probes (all log-only; saved at .tmp/issue118-probes.patch):
   - retained-state decomposition: N created only in NH4/NH3/exch (NO3 deltas exactly 0); band
     group excess +3.35e-11, non-band +8.8e-12 = guard residual +4.23e-11 vs 2048-ulp limit 7.36e-13.
   - every structured candidate update (state_updateCellProjectedWater, 4.01M census calls) realized
     |dN| < 1e-13; the recovery block never executed that hour.
   - the base advance @memcpy(current, best_state) at iteration 52 adopted an
     anderson_depth_two candidate (affine mix of Picard-mapped history vectors x + lambda*R(x) in
     packed vector space) carrying exactly dN = +4.2306602665576065e-11; all 51 prior advances
     <= 1e-13.
3. The next-iteration retainBestBoundedIterate gate read the advanced vector and threw
   SoluteReactionAcceptedStateConservationFailure through a hard-try, aborting hour 4633 instead of
   simply not retaining the iterate. The tolerance was correct (defect = 57x limit); the fatal
   rejection channel was the defect. The Zig guard has no legacy counterpart (f77src/solute.f
   publishes the last iterate unguarded); the Zig accepted-state tiers remain the science gates.

Fix: retention is eligibility, not acceptance. In retainBestBoundedIterate the inventory-closure,
charge and carboxyl-capacity validations now return false (not retained, diagnostics warnings kept)
instead of propagating SoluteReactionAcceptedStateConservationFailure; non-conservation errors
still propagate. Publish (acceptBestBoundedIterate) and per-accepted-substep
(requireAcceptedStateConservation) tiers keep hard-error semantics unchanged; no tolerance, gate,
or physics change. A leaked iterate can never become the best-bounded fallback and can never be
published: the terminal publish re-checks inventories against the entry and the accepted-hour tier
re-checks against the per-substep original state.

Evidence:
- Reproduction (pre-fix): replay of the snapshot reproduces
  error=SoluteReactionAcceptedStateConservationFailure at scene_hour 4610 cell 0 layer 0.
- Post-fix replay (production mode): same snapshot now terminates as chronic
  SoluteReactionSolverDidNotConverge - the accepted class handled by the recovery ladder and the
  published-best-bounded path (222 prior hours precedent, e.g. stderr.log:6805); no conservation
  abort.
- Unit tests: reaction_solver_tests.zig "issue-118 nitrogen leaking iterate is not retained
  instead of aborting the hour" (fails pre-fix: expectError path; post-fix: not retained, entry and
  retained state untouched) and the updated element/charge/proton-leak retention tests assert
  non-retention instead of error propagation.
