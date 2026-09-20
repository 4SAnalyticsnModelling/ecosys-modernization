# Issue 067 -- hour 2,895 `PerLayerPostRichardsTotalWaterClosureMismatch` (new frontier after issue-065's fix)

Status: OPEN, NOT YET INVESTIGATED -- filed as a bounded handoff record only.
Owner: unassigned
Discovered by: this session, 2026-09-20, as a direct consequence of fixing issue-065 (hour 2,894's nitrogen/phosphorus carrier-basis defect in `nitrogen_state_update.zig`). This is NOT a residual instance of issue-065's own defect class; it is a categorically different failure (Richards-equation soil-water-solver closure), surfaced for the first time only because the run now gets one hour further than every prior attempt.

## Summary

With issue-065's fix applied (`ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig`'s ammonium/nitrate/phosphate mass<->concentration round trip now substitutes `chemistry_state.dry_reference_water_m3` for a dry layer instead of the raw live carrier), a fresh `ReleaseFast` validation rerun of the tracked `Cool Temperate Maize-Soybean ON` deck (`runottawa`) advanced past hour 2,894 (which now commits and accepts cleanly, both nitrogen and phosphorus closing to roundoff) and failed at hour 2,895 with a new error class:

```
error: per-layer post-Richards total-water closure mismatch: cell=0 layer=0 before_m3=1.0399626626397992e-7 after_m3=3.991456771405978e-25 vapor_internal_gain_m3=8.989422010247231e-6 phase_displacement_m3=0e0 post_phase_boundary_m3=-9.09341827708986e-6 residual_m3=5.786492873673544e-16 normalized_relative=5.564135184227206e-9 limit_m3=1.0399626684262921e-16
error: hourly science failed: ... total_hour=2895 year=1998 day_of_year=121 month=5 day=1 hour=15 error=PerLayerPostRichardsTotalWaterClosureMismatch
```

Cell 0, layer 0 -- the same cell/layer that issue-065's own defect lived in, now essentially fully dried out (`before_m3=1.04e-7` m3, `after_m3≈4e-25` m3, i.e. numerically zero) at the very end of a Richards-equation water-redistribution step. The absolute residual (`5.79e-16` m3) is tiny in absolute terms but exceeds a very tight `limit_m3` (`1.04e-16` m3) that appears to scale with the layer's own near-zero water content (`normalized_relative=5.56e-9`, i.e. the residual is ~5.6 billionths of the total -- this reads as a genuine near-singular-carrier numerical closure failure at the wet/dry transition, not a gross physics error).

## Why this is out of issue-065's scope

Issue-065's entire seventeen-pass (now eighteen-pass) history investigated ONE defect class: a stored concentration/amount being computed against the wrong water-carrier basis (raw live water vs. the remembered `dry_reference_water_m3`), producing a mass-conservation mismatch measured in grams of N/P at the hourly cell-conservation gate. This new failure is a DIFFERENT gate entirely (`PerLayerPostRichardsTotalWaterClosureMismatch`, a water-VOLUME closure check on the Richards solver's own output, not a tracked-element mass gate) and a different physical quantity (m3 of water, not g of N/P). No carrier-substitution fix of the kind issue-065 applied is expected to be relevant here without further investigation.

## Evidence

`<scratchpad>/prod-run-issue065-eighteenth-final/` (fresh isolated deck copy + binary, SHA-256 `71F6DEDF3A95390C3724213C93A67487F3CE5F55B15324B6484166C83CFC277D`; `combined_err.log`, `eighteenth-final-evidence.json`). `eighteenth-final-evidence.json` confirms hour 2,894 `committed`/`accepted`, hour 2,895 `attempted` only. Full source-side reference: issue-065's eighteenth addendum, which found and fixed the unrelated hour-2,894 defect as part of the same investigation session.

## Recommended next steps (not performed this pass)

1. Locate the Richards-solver post-step water-closure check (`PerLayerPostRichardsTotalWaterClosureMismatch`'s raise site) and read its own before/after/vapor/phase-displacement/boundary accounting for layer 0 at hour 2,895 specifically.
2. Determine whether `limit_m3` is itself computed from a relative tolerance applied to a near-zero `before_m3`, which would make this a known-hard near-singular-carrier edge case (the layer drying essentially completely within one Richards step) rather than a new translation defect -- check whether the legacy Fortran oracle (`watsub.f`) has an equivalent floor/guard for this exact transition that the Zig port may be missing.
3. Do not assume this is the same defect class as issue-065; investigate from first principles per the contract's required order (unequal inputs, parsing, bindings/update order, translation/units/indexing/precision, convergence/timestep/compiler behavior, then approved physical changes).
4. Follow the contract's bounded-experiment discipline: state a hypothesis, minimal reproducer, and stop condition before any further `ReleaseFast` rerun.

## Disposition

**Open, unassessed.** No fix attempted. This is a clean handoff record only, filed so the new frontier reached by issue-065's fix is not lost.
