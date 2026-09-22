# Issue 083 -- the vertical mechanical excess-relief term wrongly inherits the Darcy term's recipient clamp, so an overfilled soil column cannot drain

Status: **OPEN (LOW PRIORITY) -- AND ITS CENTRAL PREMISE IS NOW REFUTED: the FLQR path is NOT missing from ecosys-ng.** `run-018` established that `stages/hourly_heat_water_solute.zig:4539-4570` IS the FLQR analogue and was working correctly all along; only its ledger declaration was missing, and adding that cleared hour 3,253 (`issue-089`). So the `litter terminus port` this issue escalated as a solver-architecture decision is **not needed**. The recipient-clamp finding below remains real and correctly cited, but it is no longer on the critical path and its fix stays reverted.

Prior status: **OPEN -- DIAGNOSIS CONFIRMED; THE RELIEF-TERM FIX STAYS REVERTED, AND AN ISOLATED CONTROL RUN NOW PROVES IT WAS THE REGRESSING HALF.** `run-015` reapplied only the *other* half of `run-013`'s change (`issue-078`'s guard-domain correction) and got the frontier unchanged at hour 3,253 with zero regression. Since `run-013`'s combined change regressed to 2,973 and the guard half alone does not, **the donor-only relief rewrite is confirmed as the cause of that regression** -- previously this was inference, now it is measured. Do not reapply it without the litter terminus.

Prior status line: **OPEN -- DIAGNOSIS CONFIRMED, THE ATTEMPTED FIX WAS VALIDATED AND REVERTED (2026-09-21, adversarial Claude/Pi session).** The defect below is real and verified line by line against the oracle at all three vertical face types, and the recipient clamp demonstrably zeroes the relief (a unit test measures `0` instead of the required `-0.04 m3`). **But porting this leg on its own made the production frontier WORSE -- hour 2,973 `SoilWaterSolverStagnated` against a pre-change frontier of hour 3,253 -- so the source change was reverted.** Full evidence: `audit/runs/run-013-issue-083-donor-bound-relief-validation-2026-09-21.md`.

**The lesson, which is the reusable part:** the oracle's relief legs are a **system**, not three independent ports. Leg two (layer-to-layer, `watsub.f:4898-4902`) moves excess **upward**, and `transport/hydrology.zig:484` shows layer 0 is never a vertical-face destination, so it has **no in-solver outlet**. Porting leg two without leg three (the top-layer-to-litter terminus, `watsub.f:3683-3685`) turns the profile into a one-way pump that accumulates water at the top until the hydraulics go stiff. Consistent with the observed failure being 441 hours after the run's only tillage event, with `limiting_cell` reaching 0 and `limiting_domain=matrix` throughout.

**Do not retry this change by itself.** Either port the litter terminus in the same change, with its own conservation evidence at the litter ledger boundary, or leave both unported. The "Fixes applied" section below is retained as the record of what was tried; treat it as a reverted candidate, not as current source.

Filed by: Claude Code (editor lane). Root mechanism independently pointed at by the Pi reviewer lane in `audit/reviews/review-pi-2026-09-21-round14-entry-overfill-drain-sufficiency.md` (verdict INSUFFICIENT), then re-verified here against the Fortran directly rather than accepted from the report.

## Summary

The legacy oracle gives its vertical **excess-relief** term a deliberately *different* bound from the **Darcy** term it is added to, and that difference is the entire purpose of the term. ecosys-ng routed both through the same helper, so the relief term silently inherited the Darcy term's recipient-capacity clamp. The consequence is that relief becomes exactly zero precisely when it is needed -- when the shallower recipient is itself at or over capacity -- so an overfilled column is permanently jammed instead of draining.

This is a translation defect with an exact oracle citation on both sides, not a design preference and not a tolerance question. No tolerance, iteration ceiling, substep ladder, or Newton/Anderson acceptance/damping rule was touched.

## The oracle's asymmetry, verified line by line

Both vertical face types show the identical two-step pattern: a recipient-clamped Darcy flux, then an excess-relief term added **on top** with a **donor-only** bound.

**Soil layer to soil layer, micropore** (`f77src/watsub.f`):

- Darcy, upward branch, `:4884-4886` -- recipient-clamped:
  ```fortran
  VOLP2N=VOLP1(N3,N2,N1)-FLWL(3,N3,N2,N1)
  FLQL=AMIN1(0.0,AMAX1(FLQZ,-VOLW2(N6,N5,N4)*XNPHX
 2,-VOLP2N*XNPHX))
  ```
  `VOLP1` is the **clamped**, nonnegative air volume (`:213`), so this term cannot overfill its recipient.
- Excess relief, `:4898-4902` -- donor-only, no recipient term at all:
  ```fortran
  IF(N.EQ.3.AND.VOLP1Z(N6,N5,N4).LT.0.0)THEN
  FLQL=FLQL+AMIN1(0.0,AMAX1(-VOLW2(N6,N5,N4)*XNPHX
 2,VOLP1Z(N6,N5,N4)))
  ENDIF
  ```
  `VOLP1Z` is the **signed** excess (`:212`), named "excess water+ice (-ve) (m3)" at `:4894`.
- Application, `:4927-4932`: `VOLW2` is updated by `FLQL` and the air volumes are re-derived with `AMAX1(0.0,..)`. The oracle therefore knowingly credits a recipient that has no air space left and lets that recipient become the next substep's donor. Nothing errors.

**Soil layer to soil layer, macropore** (`f77src/watsub.f`): identical shape.

- Darcy, `:4973-4974`, clamped by `VOLPH1(N6,N5,N4)` (the clamped macropore air volume, `:222`).
- Excess relief, `:4987-4990`, donor-only:
  ```fortran
  IF(N.EQ.3)THEN
  FLWHL(N,N6,N5,N4)=FLWHL(N,N6,N5,N4)
 2+AMIN1(0.0,AMAX1(-VOLWH1(N6,N5,N4)*XNPHX,VOLPH1Z(N6,N5,N4)))
  ENDIF
  ```
  Both legs are gated `N.EQ.3` (vertical only), matching ecosys-ng's own `face.direction != .vertical` filter.

**Top soil layer to surface litter** (`f77src/watsub.f`): the same asymmetry again, which is what makes the pattern convincing rather than incidental.

- Darcy, `:3670`, clamped by `VOLP10` (the litter's air space).
- Excess relief, `:3683-3685`, donor-only:
  ```fortran
  IF(VOLP1ZN.LT.0.0)THEN
  FLQR=FLQR+AMIN1(0.0,AMAX1(-VOLW1N*XNPZX,VOLP1ZN))
  ENDIF
  ```

## What ecosys-ng did instead

`ecosys-ng/src/soil/water/solver_residual.zig`'s `applyMechanicalFreezingDisplacement` computed the correct donor-bounded request via `water_flux.mechanicalFreezingDisplacementM3` (`soil/water/flux.zig:93-106`, which **is** a faithful port of `watsub.f:4899`'s `AMIN1(0.0,AMAX1(-VOLW2*XNPHX,VOLP1Z))`), and then passed that request through `group_flux.limitFluxForAssembledTarget` (`soil/water/solver_flux.zig:52-75`). For an upward (negative) flux that helper returns

```zig
return @max(flux_m3, -@min(@max(0.0, target[destination]), @max(0.0, source_capacity_m3 - target[source])));
```

The `source_capacity_m3 - target[source]` factor is the **recipient's** spare room. When the shallower layer is full or overfilled that factor is `<= 0`, the whole bound collapses to `0`, and the relief is discarded. The helper is correct for the Darcy term -- it is exactly `watsub.f:4886`'s `-VOLP2N*XNPHX` -- and wrong for this one.

Measured, not argued: the new regression test below reports relief of exactly `0` with the clamp in place versus the required `-0.04 m3` without it.

## Why this is the mechanism behind issue-078's hour 3,253

`issue-078`'s own second-candidate experiment measured the tilled mixing zone as 4 layers with `total_excess_m3=5.185e-3` against `total_spare_m3=2.083e-3`. With every layer in the zone at or over capacity, every face's recipient clamp evaluates to `0`, so no relief moves anywhere: the zone is jammed by construction, and the excess survives to the next hour's entry check, where `runtime_material_refresh.zig` aborted the run. That also explains why `issue-078`'s sixth pass concluded no ordinary relief mechanism existed -- the mechanism was present and being called, but its output was being zeroed.

## Fixes applied

1. **`ecosys-ng/src/soil/water/solver_residual.zig`, tag `MECHANICAL-RELIEF-DONOR-BOUND-ONLY-001`.** The matrix and macropore relief terms now apply their donor-bounded request directly instead of routing it through `limitFluxForAssembledTarget`. Nonnegativity is unaffected: `mechanicalFreezingDisplacementM3` returns at worst `-target[destination] * time_fraction` with `target[destination] >= 0`, so no carrier can go negative. The Darcy terms elsewhere in the same file keep the helper unchanged.

2. **Same file, the per-cell trial ceiling.** `applyMechanicalFreezingDisplacement` now runs **before** the per-cell `acceptedEntryLiquidCeilingM3` loop, and the ceiling is taken from `@max(base[cell], target[cell])` rather than `base[cell]`. This was required, not cosmetic: once the prepass may legitimately credit a full recipient, a ceiling derived from the entry state alone rejects the solver's own mandated result as an "optimizer excursion that manufactures additional overfill." The `@max` is the union of the two admissible states -- a **donor's** post-prepass target is *lower* than its entry value and its trial is still entitled to sit at the accepted entry overfill, while a **recipient's** is *higher* by the credit it was just mandated to absorb. Both quantities are deterministic functions of the accepted entry state and the grid; neither is an optimizer degree of freedom, so the guard keeps its stated purpose.

   A first attempt used the post-prepass `target` alone and was caught by an existing regression (`soil.water.solver_tests`'s "vertical Richards residual routes accepted HOUR1 material contraction conservatively" failed with `SoilWaterCandidateExceedsPoreCapacity`), because it tightened the donor's ceiling below the donor's own entry state. Recorded because the failure is the useful part: the existing suite did catch the wrong formulation.

## Test evidence

New discriminating regression, `ecosys-ng/src/soil/water/solver_tests.zig`, `test "vertical mechanical relief overfills a full shallower recipient like the oracle"`: layer 0 holds **exactly** its capacity (zero spare room), layer 1 enters over capacity by `0.04 m3`. Asserts the full excess moves, that the recipient ends **above its own capacity** (the behavior `VOLP2=AMAX1(0.0,..)` exists to absorb), and that the transfer conserves water to `32 * floatEps`.

- With the fix: passes.
- With the clamp deliberately restored: **fails**, `actual 0, not within absolute tolerance ... of expected -0.04`. The test is therefore discriminating rather than vacuous -- checked explicitly because of this project's own `issue-076` finding that a silently-passing assertion retires the guarantee it was written to protect.
- `zig test src/module_index.zig --test-filter "soil.water"`: **450 passed, 0 failed** (this filter was also run before the changes, same 450, so the count is comparable).

## Known scope boundary, deliberately not widened

`watsub.f:3683-3685`'s **top-soil-layer to surface-litter** relief leg has **no counterpart in ecosys-ng's prepass**: the solver's face set contains no litter face (`surface_litter_liquid_water_m3` is only an option consumed at `soil/water/heat_step.zig:1757` for the water-table refresh, not a solver face), and `stages/diagnostics.zig:291-293` states the prepass "only ever relieves a DEEPER layer by moving liquid UP into the layer above, never the reverse." So the **top** layer's own entry overfill still has no in-solver outlet.

The stage-level cascade that does reach the litter (`stages/hourly_heat_water_solute.zig:4446-4571`, terminating at `:4539-4570`) is driven only by `displacement_by_layer` from the phase solve, so it does not fire for unfrozen entry overfill -- verified independently by the Pi lane (round 14) and consistent with the call chain read here.

This gap is left **open and unimplemented on purpose**: it needs a new solver face or a sanctioned re-entry of the accepted-displacement path, which is a stage-pipeline/solver-architecture decision of the kind `issue-068` and `issue-078` already reserved for human sign-off, and the fixes above may make it moot if the zone's excess can distribute upward and then leave by ordinary drainage. The validation run is the cheapest way to find out. Do not implement it speculatively before reading that run's result.

## Relationship to other records

- `issue-078` (hour 3,253 `RuntimeSoilPoreCapacityExceeded`): this is the drain-side half. `issue-078`'s own entry-guard half is the `runtime_material_refresh.zig` domain correction recorded there.
- `issue-080` (tillage dosing, 1 versus `24*NFH`): independent and still open. Note it interacts -- 96 doses each followed by a relief pass is a different loading pattern from one dose followed by one.
- `issue-012` / `GEOM-SUBSIDENCE-001`: `redist.f:8397-8402` is a *third* legacy overfill response (the layer physically expands downward, gated at `:8394` on `BKDS(L+1).LE.ZERO`, so the pond boundary specifically). Not ported, not part of this fix, noted so a later pass does not mistake it for a fourth mechanism.
- The macropore branch of `runtime_material_refresh.zig`'s entry guard remains strict even though `watsub.f:221-222`/`:6824-6825` show the oracle carries a signed macropore excess too. No observed macropore failure justifies widening that yet; recorded here so the citation is not lost.
