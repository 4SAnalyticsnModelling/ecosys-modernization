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
