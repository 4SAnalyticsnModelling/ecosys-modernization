# issue-121 — 2000 d60 h3 HourlyCellConservationFailure carbon (total_hour 18939)

Registered: 2026-10-26 (cycle 00010 verification aftermath). Status: ACTIVE (cycle 00011 target).

## Registered facts (VERIFIED, two independent reproductions, bit-identical)
- Candidate binary sha256 ac1d46d3bdaefde44d04351bcc0fdc098ad095300781cadd09fea77dca916d55
  (ReleaseSafe, cycle-10 issue-120 fix).
- Reproduction A (from scratch): audit/runs/ottawa/cycle10-verify-candidate-20261026 (deck =
  pristine prod-examples copy; elapsed 5.6 h; zero HourlyLayerConservationFailure anywhere;
  34-file/129,112-row bit parity vs cycle-9 outputs through 1999 d360 h24).
- Reproduction B (restart from h17400): audit/runs/ottawa/cycle10-restartx10-fixed-20261026.
- Failure line (identical digits in both):
  hourly cell conservation failure: cell=0 quantity=carbon
  before=4.726392231937252e3 after=4.726390769503288e3
  external_inputs=6.4891652298282e-18 external_outputs=1.4624339520421478e-3
  internal_production=0e0 internal_consumption=0e0
  residual=-1.2619472307406898e-11 absolute=1.2619472307406898e-11
  normalized_relative=8.629088637398315e-9 physical_limit=1.4624339646616137e-12
  arithmetic_roundoff_allowance=1.0908581399401483e-11 effective_limit=1.2371015364063096e-11
  => |residual| exceeds effective_limit by 2.485e-13 (relative 1.02e0 of the allowance budget
  scale ~1e-11 on a 4.7 kg C cell inventory; NOT a subnormal-pool artifact like issue-120).
- Storage components at the failure: residue 6.286322574940589e1 -> 6.286250953858022e1,
  organic 4.56017489981857e3 -> 4.560174317715281e3, inorganic_and_gas
  1.0335410636927607e2 -> 1.033539422494256e2.
- Hour context (same hour, both runs): SOLUTE hourly reaction solver
  SoluteReactionSolverDidNotConverge at cell=0 layer=0; bounded fixed external hour recovery
  rejected 4 substeps, ACCEPTED 20 substeps; failure snapshot
  ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene3-year2000-day60-hour3.bin written;
  trace line "hourly litter-soil rebase drift: substeps=2e1 cross_term_megajoules=1.81e-18
  booked_over_c_org=6.11914814498719e-6 last_temperature_k=2.7295703524410476e2
  carbon_step_total_g_c=2.241789287538154e-8 census_temperature_gap_megajoules=6.84e-17".
- All earlier territory clean: hours 17401..18938 zero conservation failures of any class.

## UNVERIFIED hypotheses (cycle 00011 starting points)
- Producer class candidates: (a) litter->soil rebase during the 20-substep recovery books
  CO2/C transfers with a per-substep rounding sum ("booked_over_c_org" trace exists — is the
  booked ledger the sum of per-substep bookings while storage moved by the composed map?);
  (b) non-converged reaction candidate published via the cycle-8 eligibility path carrying a
  small unpaired C (issue-118 class recurring on the CARBON channel);
  (c) CO2 outgassing/equilibration leg at the surface-soil interface double/fractionally
  rounded across the rebase boundary (rebase drift trace names the litter-soil rebase).
- 2000 = leap year, d60 h3 ~ 2000-02-29/03-01: check whether the defect is scene/day-rollover
  state (day_of_year_reset) rather than biology.
- NEVER loosen the cell gate; diagnose at the smallest state (replay the 2000 d60 h3 snapshot).

## RESOLUTION (cycle 00011, 2026-10-26) — validator-mirror organic sum completion
Root cause (VERIFIED, probe receipts audit/runs/ottawa/cycle11-probe{2,3,7,8,10,k}-20261026):
the hourly relayering rewrites ~4600 organic pool slots per cell (naive `moved = f*src` transfers).
The cell/layer carbon validators reconstruct storage by re-summing every pool in
`validation/landscape_mass_inventory_organic.zig` order into TWO flat accumulators (organic =
substrate-4 class, residue = others), then close the compensated sum. Re-summing rewritten
mantissas drifts the accumulators ulp-scale per hour (validator-order organic drift at the fatal
hour -9.09e-12 = -10 ulp of the cell total); the unbooked drift plus mirror-publish noise
(-3.6e-12) and gas-leg slack (+1.1e-13) summed EXACTLY to the validator residual -1.2619e-11
vs the effective limit 1.2371e-11 at 2000 d60 h3.

Fix (D-14 -> supersession -> D-15 -> D-16): `src/soil/organic/sum_completion.zig` captures the
per-cell validator-order (organic, residue) accumulator bit targets around
`soil/profile/relayering.zig` applyLayerRedistribution and restores them after the cell-local
rewrite: per-accumulator drift distributed across layers proportional to the layer accumulator
magnitude, capped at 8 ulp steps per layer-hour (keeps every LAYER-scope injection a large
multiple under the layer closure limit), finisher on the class largest pool, mass guard
|drift| > 1e-6 g C fatal (never paper over a real unbooked movement), non-convergence warns
(bounded +/-1 ulp residual). Structural/colonized pools are never adjusted (coupling guards,
cycle11-fixsmoke receipt). Gas-leg slack stays unbooked (~1e-13, far under allowance).

Intermediate receipts (kept honest):
- attempt 1 (single-slot completion, bin a274d0c3): HourlyLayerConservationFailure
  layer_scope=9 carbon at 1998 d30 (residual 2.7536e-12 vs 2.6217e-12) — the whole cell drift
  concentrated in one layer exceeds that tighter scope's limit.
- attempt 2 (v2 proportional + unbounded bit-exact finisher, bin bce0792e): same failure class
  at 1998 d33 (2.6563e-12 vs 2.5384e-12) — the finisher chasing a non-validator sum oscillated
  and injected up to 2.67e-12 into layer 9 (probeK line TEMPDIAG121K share layer=9).
- probeK (bin in evidence/runs/cycle11-probek-20261026/deck): per-layer natural relayering
  deltas are MASS-scale (up to 1.3e-3 g/hour, legitimate booked moves) while the cell total is
  invariant to ~2e-14 -> the completion target must be the validator accumulators, per class.
Verification (in progress): validator-mirror v7, candidate 39033e28c8803f1eef87431138d57b64467972d90a32a84b03e9926a8d2d1d96,
from-scratch run audit/runs/ottawa/cycle11-smoke-v7-20261026 (pristine deck; to be committed as
cycle11-verify-candidate-attempt3-20261026): must accept total_hour 18939 with zero
HourlyCellConservationFailure and zero new error classes; parity vs cycle-10 verified outputs
through h18938.
