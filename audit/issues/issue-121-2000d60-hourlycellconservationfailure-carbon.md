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
