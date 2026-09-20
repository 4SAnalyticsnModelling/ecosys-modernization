# Issue 068 -- hour 2,895 `SoilHeatSolverTemperatureOutsidePhysicalDomain` (new frontier after issue-067's fix)

Status: OPEN, NOT YET DIAGNOSED (discovered as a direct consequence of fixing issue-067; no root-cause investigation performed this pass; handed off per contract's bounded-work discipline).
Owner: unassigned (discovered 2026-09-20, same session as issue-067's fix)
Discovered by: this session, 2026-09-20, while validating issue-067's hybrid-tolerance fix for `PerLayerPostRichardsTotalWaterClosureMismatch`.

## Summary

With issue-067's fix applied (`validatePerLayerPostRichardsTotalWaterClosure` now sizes its `upstream_arithmetic_roundoff_allowance` from the vapor solver's own already-accepted convergence tolerance, see issue-067), a fresh `ReleaseFast` fresh-from-hour-1 validation run of the tracked `Cool Temperate Maize-Soybean ON` deck (`runottawa`) confirmed the water-closure mismatch is gone (zero occurrences of `PerLayerPostRichardsTotalWaterClosureMismatch` anywhere in the run's log), but hour 2,895 still fails to commit -- now on a different, later-stage check:

```
warning: soil coupled schedule failed: substep_count=64 failed_substep=7 time_step_hours=1.5625e-2 error=SoilHeatSolverTemperatureOutsidePhysicalDomain
warning: bounded fixed external hour recovery rejected: exact_substep_count=64 error=SoilHeatSolverTemperatureOutsidePhysicalDomain
error: hourly science failed: execution=1 scenario=1 scenario_repeat=1 scene=1 scene_hour=2895 total_hour=2895 year=1998 day_of_year=121 month=5 day=1 hour=15 error=SoilHeatSolverTemperatureOutsidePhysicalDomain
```

This is reached only after the retry ladder escalates the hour to `exact_substep_count=64` (1/64 hour = 1.5625e-2 h substeps), failing specifically at `failed_substep=7`. The immediately preceding log lines (this run's own `TEMP_DIAGNOSTIC`/`DRY_CARRIER_TRACE` instrumentation, both narrowly hour-gated to 2893-2896, still present from the issue-060..067 chain) show cell 0/layer 0 cycling through the same near-total-desiccation state (`water_vapor_volume_m3` in the `1e-7`-to-`1e-6` range, old/new water repeatedly hitting exact zero) that has been the site of every issue in this chain since issue-060.

## Why this is out of issue-067's scope

Issue-067 diagnosed and fixed one specific check (`validatePerLayerPostRichardsTotalWaterClosure`, a water-volume closure identity) by correctly accounting for the vapor solver's own accepted Newton residual. That fix is confirmed working: the exact error class it targeted no longer occurs anywhere in a full fresh-from-hour-1 run reaching hour 2,895. `SoilHeatSolverTemperatureOutsidePhysicalDomain` is raised by the spatial heat solver's own domain/finite-state guard (`soil/heat/solver*.zig`), a categorically different check (temperature bounds, not a water-volume identity), most likely previously masked because the water closure check used to abort the hour before the heat solver's retry ladder got this far.

## Evidence

- `<scratchpad>/issue067-validation-run/` -- fresh isolated deck copy + binary (SHA-256 `8FDD0B520FB1AE68A6FA8EE15F539B258288C0058265DAB2D441EA36F644D245`, built at the commit containing issue-067's fix), `run_err.log`/`run_out.log`. Confirmed via `Select-String` that `PerLayerPostRichardsTotalWaterClosureMismatch` has zero occurrences in this log; `SoilHeatSolverTemperatureOutsidePhysicalDomain` is the terminal error at `total_hour=2895`.
- Same cell/layer (cell 0, layer 0) as the entire issue-060 through issue-067 chain; same near-total-desiccation degenerate state.

## Recommended next steps (not performed this pass)

1. Locate the spatial heat solver's domain guard that raises `SoilHeatSolverTemperatureOutsidePhysicalDomain` (likely `ecosys-ng/src/soil/heat/solver_solve.zig` or `solver.zig`, near the same Newton/Anderson loop referenced by issue-060's `heat-solver-stagnation` finding) and read its exact bound and the trial temperature that violates it at `failed_substep=7` of the 64-substep schedule.
2. Determine whether this is the SAME underlying near-desiccated-layer degeneracy (heat capacity of an almost-waterless layer collapsing toward the `negligible-capacity layer discarded heat` warning already visible immediately before the failure in this run's own log) reaching a genuinely different numerical failure mode, or an unrelated defect.
3. Follow the contract's required investigation order (unequal inputs/initialization; parsing/output semantics; bindings/update order; translation/units/indexing/precision; convergence/timestep/compiler behavior; then approved physical changes) and its three-experiment bounded-diagnosis discipline before attempting a fix.
4. Do not widen the heat solver's physical-domain bound to manufacture a pass; if the bound itself is found to be miscalibrated, that must be demonstrated with evidence (analogous to issue-067's own tolerance-provenance reasoning), not assumed.

## Disposition

**Open, not yet diagnosed.** Discovered as the immediate next frontier after issue-067's fix, at the same hour (2,895) and cell/layer (0/0) as the entire recent issue chain. Handed off per contract rather than guessing at a fix under this task's bounded scope (issue-067 only).
