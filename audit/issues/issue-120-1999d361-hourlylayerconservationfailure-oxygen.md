# issue-120: HourlyLayerConservationFailure at 1999 d361 h1 (subnormal oxygen pool)

Status: REGISTERED at cycle 00009 close (fix scope = cycle 00010).

Evidence (audit/runs/ottawa/cycle9-verify-candidate-20261025/stderr.log, exit_code=1):
- 86005: info: daily conservation accepted: day=360 year=1999 hour=24 (oxygen ledger 5.37e-14)
- 86006: info: day advanced: scene_weather_hours=8640 (last accepted hour = 1999 d360 h24,
  total_hour 17400)
- 86007: error: hourly_layer layer_scope conservation failure: layer_scope=17 quantity=oxygen
  before=3.39519326554e-313 after=3.3951932656e-313 external_inputs=0e0 external_outputs=0e0
  internal_production=0e0 internal_consumption=0e0 residual=5e-324 absolute=5e-324
  normalized_relative=1e0 physical_limit=0e0 arithmetic_roundoff_allowance=0e0 effective_limit=0e0
- 86033: error: HourlyLayerConservationFailure (first occurrence of this class in any archived run)

Facts:
- The pool is SUBNORMAL (3.4e-313 < smallest normal 2.2e-308); the delta is one denormal ulp
  (2^-1074 = 4.9e-324). With zero external inputs/outputs the hourly identity should be exact;
  normalized_relative evaluates 5e-324 / subnormal-scale = 1e0 against effective_limit 0e0, so any
  subnormal perturbation is fatal. Perturbing writer not yet identified (UNVERIFIED).
- Preceded within the same window by "soil phase-enthalpy Newton-Picard stagnated" +
  "soil phase limiting block" warnings (chronic classes, layer_cell=0 state=1).
- Ottawa scenario: winter anoxic soil; oxygen pool has decayed to the subnormal edge over the
  profile. This is the near-zero-signed-defect class covered by
  .agent/playbooks/convergence-and-balance.md: resolve the benign edge case with bounded work and
  no false errors — never by loosening the conservation gate.

Reproduction asset: deck evidence/runs/cycle9-verify-candidate-20261025/deck is CONSUMED
(through d360). Rebuild from pristine scenario for from-scratch work; the binary lineage is
bit-reproducible at output level (retention.json).

Frontier: last accepted hour = 1999 d360 h24 (scene_hour 8640; total_hour 17400) — advanced from
issue-119's h15600 by 1,800 hours (~75 days) of clean trajectory.

## Investigation (cycle 00010)

Attempt-1 probe run (audit/runs/ottawa/cycle10-probe-17401-20261025, probe binary
sha256 5c77662c0e1119a4bd0eefb2041fa0681967714c743816a57ad2ff66dfdbb401, exit 1, fatal
reproduced bit-exactly):
- TEMPDIAG120P (soil/gas/oxygen_step writeback operands) = 0 lines and TEMPDIAG120F (frozen-layer
  skip) = 0 lines across the whole run => the microbial oxygen kernel never visits this layer at
  trace scale; the allocation-split sum-drift hypothesis, while arithmetically real in isolation,
  never fires here.
- TEMPDIAG120T (before/after snapshot around coupled_gas_solver.solve inside
  soil/gas/transport_step.zig State.advance) = 0 lines => the coupled gas solver never perturbs
  any trace-scale pool.
- TEMPDIAG120A (validator per-hour trace dump for pools < 1e-300): scope-17 nonzero residuals
  occur only in the first hours of 1999 d361 — hour before h-2: before=3.0581182251113463e-297,
  after=3.39519326554e-313 (residual +3.395e-313, within tol); h-1: before=2.080663984240254e0
  (anomaly: previous check ended at 3.395e-313), after=3.39519326554e-313 (residual 1.6755e-12,
  within tol); h0: fatal +1 subnormal ulp. Drift recurs hourly thereafter.
- Conclusion so far: an untagged writer (or layer-scope identity shift) perturbs the pool without
  touching the four hourly ledgers.

Attempt-2b probe run (audit/runs/ottawa/cycle10-probe-17401-attempt2b-20261026, binary
sha256 ca89c962..., adds TEMPDIAG120V slot-diff brackets around advanceDissolvedGasTransport,
advanceSoilGasTransport (remainder outside the solve) and geometry_disturbance.finalize
(hourly relayering in stages/hourly_vegetation.zig), plus TEMPDIAG120R bracketing
plant_root_gas_transport.advanceOxygen soil-side uptake). Restart-from-17400 was attempted first
but the engine resumes=false despite the scene control record and restart.manifest; scratch truth.
Receipt: pending (run in progress at checkpoint time).


Attempt-3..5 probes + restart fast lane (2026-10-26):
- resume=false RESOLVED: per-scene control record decides (1998 file f25y98 record line 6 = NO,
  1999 f25y99 = YES). With record6=YES and a deck containing restart.manifest + the 17400-hour
  *.bin set, the engine resumes at total_hour 17400 and reproduces this fatal BIT-EXACT in ~45 s
  (audit/runs/ottawa/cycle10-restartx-20261026 .. cycle10-restartx9-20261026).
- TEMPDIAG120V (all four soil-gas phases, every hourly bracket incl. dissolved advance, soil gas
  advance, geometry finalize, chemistry converge, hour_window coarse) = ZERO hits at the fatal
  hour => entire soil gas State + coupled solve + root exchange + geometry relayering EXONERATED
  (also 120Y/Z engine-window quad diff over soil slots + active_soil_layer_count: zero).
- TEMPDIAG120B scope decode: layer_scope 17 = kind=SURFACE, cell 0 (layout caps soil=12, snow=5,
  cells=1; surface = 12+5). Validator surface oxygen = fourPhaseGas(gaseous+dissolved+macropore+
  band) of the LITTER gas State slot (validation/landscape_mass_inventory_surface.zig:566-590).
- TEMPDIAG120W (storage dump at evaluate) + TEMPDIAG120L (engine window snap->accept diff on
  litter slot): litter gaseous O2 slot 0 changes inside the hour; fatal-hour final delta
  +5e-324 == validator residual.
- TEMPDIAG120M brackets: block=litter_advance moves dissolved 3.39519326554e-313 -> 0 and
  gaseous 3.0581182251113463e-297 -> 3.39519326554e-313 (equilibration, booked/accepted);
  block=surface_microbial_oxygen (stages/biogeochemistry_batches.zig:532 ->
  surface/microbial_oxygen.zig applyTile -> soil/gas/oxygen_allocation.zig solveLayer) then moves
  gaseous 3.39519326554e-313 -> 3.3951932656e-313 = the exact validator before/after pair,
  zero ledgers. WRITER PINNED.
- Mechanism (source-verified): solveLayer feeds each population round(shared.phase*fraction)
  (:115-118) and writes back SUM_i result.phase (:131-135); oxygen_solver's trace guard
  (soil/gas/oxygen_solver.zig:92, total <= floatMin) returns every slice verbatim with uptake 0
  (=> zero ledgers, consistent), but the re-summed rounded slices differ from the shared pool by
  one subnormal ulp on the denormal grid.

Fix (leader decision, cycle 00010): soil/gas/oxygen_allocation.zig solveLayer gains an early
return when shared.gaseous + shared.aqueous <= floatMin - provably the identity window of the
solver guard, so per-population outcomes are unchanged (fractions normalized, uptake/
satisfaction/iterations cleared, shared fluxes zeroed) and the shared pools stay bit-identical,
removing the only observable difference (the sum-drift). Covers both the soil oxygen_step path
and the surface microbial path (shared module). Validator, gates, tolerances untouched.
Discriminating test "issue-120 trace-window allocation preserves subnormal shared oxygen
exactly" uses the exact fatal pool 3.39519326554e-313 heap-backed; FAILS at HEAD (bit
0x1000000000 -> 0xfffffffff; standalone repro harness:
audit/experiments/cycle10-diagnose-120-20261025/prefix-drift-repro/) and PASSES post-fix.
Verification: from-scratch run cycle10-verify-candidate-20261026 pending (protocol: restart lane
is diagnostic only) + parity vs cycle-9 outputs through 1999 d360 h24.
