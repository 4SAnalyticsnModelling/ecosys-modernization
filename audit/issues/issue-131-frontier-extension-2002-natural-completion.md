# issue-131 — frontier extension: complete the 5-scene Ottawa plan (2002) via verified resume

Status: EXECUTING (cycle 14, opened 2026-11-26)
Owner: leader. Depends on: cycle-12 authority (v19, through hour 35124 = 2002-01-02 12:00).

## Scope
The runottawa run plan is 5 one-year scenes (1998..2002; f25y98..f25y02 exist as forcing
options; f25y03/f25y22 are present in the forcing directory but the plan line is 1,1,5).
v19 authority stopped by planned SIGTERM at hour 35124 — inside scene 5 (2002), 60 h after
the last checkpoint boundary 35064. This cycle extends the verified trajectory to the
plan's natural end (scene-5 completion, expected hour 43824 = 2002-12-31 24:00) using the
v19-identity engine (sha256 e522a1f6…, __text 58e2c7a769ecf4308e75) with NO code change,
then characterizes the terminal state: exit status, counters, ladder-warning profile, and
whether any new failure boundary appears in 2002 (first territory no prior campaign
reached beyond hour 35124).

## Acceptance
- Absolute counters ZERO to completion: hourly science failures, conservation violations,
  FATAL, SoluteConcentration guard trips.
- Trajectory-faithful re-entry proven: failure-snapshot names through the shared region are
  a strict subset of v19's set (already shown at day 2; full-region check at 35124).
- Natural completion: engine EXITED 0 on its own (no SIGTERM), run plan scenes 1..5 all
  published; day-line count 1826 = 365+365+366+365+365.
- Watcher doctrine exclusions remain proven-baseline families only; anything new alarms.
- Evidence: audit/runs/ottawa/cycle14-verify-v20resume-20261126 (stderr gzipped before any
  gate scan), parity receipt in run dir, g-digest kit under
  audit/experiments/cycle14-… per close doctrine.

## Resume mechanics (recorded so the recipe is reproducible)
- Deck = copy of v19 campaign deck at the manifest-embedded root path; keep restart.manifest,
  tile bins, .ecosys-output-bank-35064.bin, .ecosys-output-cursor.bin AND the 60 rolling
  journal bins; flip entry-scene (f25y98) options line 6 resume NO→YES. False-start evidence
  retained: cycle14-v20falsestart-20261126 (flag NO → engine versioned root _v2 and restarted
  1998), cycle14-v20b-untracked-20261126 (journal bins deleted while CSVs carried
  post-checkpoint rows → UntrackedExistingOutputFile; fail-closed correct).
- Engine re-solves from checkpoint 35064 (journals are not replayed as logs); 60-h overlap
  reproduces v19's published hours (bit-parity sampled via identical failure-snapshot names
  and ladder-count windows).

## FRONTIER FOUND (2026-11-26 17:0x): next failure boundary = InvalidSnowSourceOrderCandidate
- v20c (resume, v19-identity engine) advanced the verified frontier 35124 -> 35283
  (2002-01-10 03:00, scene 5 day 10 hour 3) - +159 h of NEW territory, all published
  through day 9 with accepted dailies (water 3.4e-13 / heat 4.3e-11 class) and ZERO
  conservation violations, ZERO solute-guard trips, ZERO Untracked/Replay errors.
- Failure class: snow source-order candidate validation (soil/water/snow_source_order_energy.zig
  :153/:163/:167 - candidate temperature non-positive/non-finite, or next_capacity<=0 with
  nonzero energy). Fatal by design -> engine EXITED 1 naturally (no SIGTERM).
- Failure report heat-failure-35283.json (format ecosys-heat-v1): topsoil temperatures
  273.93/273.55 K (thaw-sided) with snow heat-capacity arrays all zero (snow-free or
  negligible-snow surface) - UNVERIFIED hypothesis: source-order candidate row degenerates
  when the snow source pass runs with zero-capacity snow rows during a thaw transition.
- Evidence: audit/runs/ottawa/cycle14-verify-v20resume-20261126 (FRONTIER_RECEIPT.txt,
  heat-failure-35283.json, receipt.json exit 1, stderr.log.gz); lane deck frozen at
  .tmp/cycle121/v19-deck (bins/bank/cursor/manifest untouched, checkpoint 35064 intact,
  restart.manifest advanced - re-resume must re-verify boundary).
- NEXT (forensics): replay the hour from the published day-9 state with the existing
  heat-failure JSON input via the module's apply() (unit-scale repro), pin which raise site
  fires and the source-row arithmetic; then legacy-parity comparison of the snow source
  ordering (f77src snow heat source terms) before any fix design. NO gate/tolerance touched.

## D-33 FIX LANDED IN TREE (2026-11-26 night, leader decision - decisions.md D-33)
- VHCPWX floor parity in BOTH snow candidate sites: fused-hour schedule builder
  (hourly_heat_water_solute.zig, floor = 8.380e-04 * canopy_cell_area_m2[cell], starts.f:654)
  and atomic replay snow_source_order_energy.apply() (new per-row
  minimum_heat_capacity_megajoules_per_k parameter). Legacy semantics watsub.f:2441-2446:
  capacity always recomputed; temperature recomputed ONLY above the floor; below-floor rows
  retain entry temperature and NEVER fatal (that fatal had no legacy analogue). Above-floor
  rows keep the full strict validation; volume non-negativity and finiteness fatals kept.
  Old EnergyWithoutCapacity + (capacity==0 && energy!=0) fatal branches replaced per parity.
- Discrimination: new tests 'issue-131 sliver below the legacy VHCPWX floor...' (trip-shaped
  sliver 4.19e-4 MJ/K, -0.42176 MJ drawdown => no fatal, T retained) and 'issue-131
  above-floor rows keep the strict candidate validation' (fatal kept). NEUTER (predicate ->
  next_capacity>0) fails EXACTLY the sliver test; restored -> module suite RC=0.
- NEXT: full suite battery (Debug+ReleaseSafe x module+executable) in flight; ship131
  double-build identity; verification lane = SAME frozen deck resume (boundary 35283 must
  pass, continue to natural scene-5 completion, counters absolute); then close ladder.

## D-33 v2/v3 ledger evolution (2026-11-26/27)
- v1 (8ea6a73) lane: SnowSourceOrderEnergyConservationFailure at 35278 = the pack-internal
  ledger did not know the below-floor retained-T energy (d68d684 = v2 books it).
- v2 lane: HourlyCellConservationFailure heat day 9 (residual 4.50369e-7 MJ cell=0 =
  exactly the retained-heat term): the cell/layer/landscape ledgers did not see it.
  0e11350 = v3: publish the term into the XHFLWW-parity totals
  (snow_inactive_reference_heat_total_megajoules_by_layer/by_cell/grand - the exact
  lanes feeding all three ledgers; step array untouched because
  snow_inactive_temperature.apply memcpy-overwrites it and its own !active gate never
  touches active sliver rows). Algebra closes exactly. Suites MOD/EXE Debug+RS rc=0.

## LANE RESULT (v3, ship131 __text 76233418bbd74420e516) - issue-131 ACCEPTED
- Frozen-deck resume 35064: PASSED 35283 CLEAN; 2002 days 9..99 absolute counters ZERO
  (science/conservation/FATAL/SoluteConcentration); dailies nominal (water ~3e-13,
  heat ~2e-11 class).
- NEW separate boundary at 37445 (2002-04-10 h5): hydrogen layer-scope ledger after
  bounded-recovery publication -> REGISTERED AS ISSUE-132 (fix scope cycle 15).
- issue-131 acceptance MET: old frontier passed, trajectory-faithful resume, +2156 h of
  first-ever territory with zero counters. Natural scene-5 completion remains open ONLY
  behind issue-132; carried to cycle 15 with the same frozen deck (checkpoints through
  37224, journals through ~37311+ kept).
