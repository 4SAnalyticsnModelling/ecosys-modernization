# Issue 065 -- hour 2,894's `HourlyCellConservationFailure` persists, bit-for-bit identical, after a complete `ZEROS2`-defect-class fix and exhaustive sweep (issue-064's hypothesis REFUTED)

Status: NOT_ASSESSED/OPEN -- diagnosis needed. Not fixed this pass (no source change made specifically for this issue; the four fixes that motivated filing it belong to issue-064 and are already committed/tested there).
Owner: unassigned
Discovered by: this session, 2026-09-19, immediately after implementing and validating issue-064's diagnosed fix (`relayering.zig`'s `transferAqueousLayerFraction`/`waterZones` carrier-flooring) plus a requested exhaustive sweep that found and fixed three more genuine siblings of the same defect class (`pond_particulate_settling.zig`, `phosphate_inventory.zig`, `litter_removal.zig`), then re-running the same resumed hour-2,880 checkpoint used by issues 062/063/064.

## Summary

Issue-064 hypothesized that `relayering.zig`'s call to `chemistry_remap.transferAqueousLayerFraction` built its `ZoneWaterVolumes` from raw, unfloored water -- the same carrier-basis mismatch mechanism issue-063 diagnosed and fixed for `transferSolidLayerFraction`, recurring one call site over on the free aqueous-ion pools (`isBasePondedAqueousField`: hydrogen, hydroxide, aluminum, iron, calcium, magnesium, sodium, potassium) instead of the solid/precipitate pools.

**That hypothesis is now confirmed WRONG for hour 2,894's specific failure.** The fix was implemented exactly as recommended, unit-tested (before/after regression proving the mechanism is real and the fix works in isolation), and the codebase-wide sweep this same pass requested found and fixed three more genuine siblings of the identical defect class elsewhere (surface pond settling, a daily phosphorus output ledger, and REDIST operation 21's surface litter removal). All four fixes compile cleanly (`zig build` and `zig build -Doptimize=ReleaseFast`, both exit 0) and pass their own and every pre-existing related test unchanged.

**A live validation run resumed from the same hour-2,880 checkpoint, with a `ReleaseFast` binary containing all four fixes, reproduces hour 2,894's `HourlyCellConservationFailure` with every reported residual value bit-for-bit identical to issue-064's original, pre-fix evidence.** `RelayeringActivityConservationFailure` does not recur (confirming issue-063's own fix is intact and unaffected), but the broader `HourlyCellConservationFailure` gate fails identically to before any of this pass's four fixes were applied.

## Evidence

Live run: resumed from the hour-2,880 checkpoint (`prod-run-issue063-verify/`, copied to a fresh `prod-run-issue064-verify/`, freshly built `ReleaseFast` binary containing issue-064's fix plus the three sweep-sibling fixes, SHA-256-confirmed to be the binary actually exercised, invoked identically to every prior pass: `ecosys_ng.exe --execution-evidence verify064-evidence.json runottawa`). `verify064-evidence.json` shows hour 2,894 `attempted`, never `committed` (hours 2,881-2,893 all committed/accepted normally, identical to every prior pass's evidence). `verify064-stderr.log` shows the same WATSUB-6907 heat-floor discard warning (issue-062's already-fixed, expected, legacy-faithful mechanism, unaffected), **zero** occurrences of `RelayeringActivityConservationFailure`, then:

```
error: hourly cell conservation failure: cell=0 quantity=carbon before=6.139931762355135e3 after=6.132080644694612e3 ... residual=-7.657654094846645e0 ...
error: hourly cell conservation failure: cell=0 quantity=nitrogen ... residual=-9.74378892114669e-3 ...
error: hourly cell conservation failure: cell=0 quantity=phosphorus ... residual=-5.411409046040926e0 ...
error: hourly cell conservation failure: cell=0 quantity=aluminum ... residual=-3.8505920339067494e1 ...
error: hourly cell conservation failure: cell=0 quantity=iron ... residual=-3.586034566540333e1 ...
error: hourly cell conservation failure: cell=0 quantity=calcium ... residual=-3.40929439883276e1 ...
error: hourly cell conservation failure: cell=0 quantity=magnesium ... residual=-3.337844719461464e1 ...
error: hourly cell conservation failure: cell=0 quantity=sodium ... residual=-3.337845257319532e1 ...
error: hourly cell conservation failure: cell=0 quantity=potassium ... residual=-3.3378449999303484e1 ...
error: hourly cell conservation failure: cell=0 quantity=silicon ... residual=-1.0013639440922263e2 ...
```

then a second, smaller-scale block reporting the same ten quantities again (same as issue-064's own evidence -- two aggregation scopes, not yet traced which two). Terminal error: `HourlyCellConservationFailure`. **Every one of these residual values is identical, to full double-precision, to issue-064's own original evidence recorded before any fix in this family was applied to `relayering.zig`, `pond_particulate_settling.zig`, `phosphate_inventory.zig`, or `litter_removal.zig`.**

Full logs preserved at (session scratchpad, not durable/tracked): `prod-run-issue064-verify/verify064-stderr.log`, `verify064-stdout.log`, `verify064-evidence.json`.

## What this proves

- **The fix mechanism itself is real and works correctly in isolation.** Both issue-064's own regression test and the three sweep-sibling regression tests demonstrate, with controlled synthetic inputs, that the old exact-zero guard manufactures or undercounts mass by orders of magnitude and the new `ZEROS2`-floored guard conserves/reports correctly. This is not in question.
- **This specific mechanism is not what causes hour 2,894's `HourlyCellConservationFailure`.** If it were, widening any of the four fixed guards would have changed at least one of the ten failing quantities' residual by some nonzero amount. None changed at all, to the last bit of double precision. A partial, non-bit-identical improvement would have been consistent with "right mechanism, other contributors remain"; a bit-identical failure is not.

## Working hypotheses (none confirmed this pass -- diagnosis only, no source change attempted)

1. **Carrier convergence, not carrier mismatch.** `water_carrier_rebase.zig`'s `rememberDryCarrier` (issue-061 Finding 1's own fixed mechanism) may have already driven cell 0/layer 0's `dry_reference_water_m3` to nearly the same tiny magnitude as the current live water by hour 2,894, after many preceding hours of the same cell oscillating near dryness. If live water and dry reference are both ~1e-9 to ~1e-6 m3 and nearly equal, then substituting one for the other via either the old exact-zero guard or the new `ZEROS2`-floored guard picks nearly the same value either way -- explaining why widening the threshold changed nothing. Cheap test: instrument (or add a one-off diagnostic build) to print `ctx.grid.matrix_liquid_water_m3[cell0_layer0]` and `ctx.soil_chemistry.dry_reference_water_m3[cell0_layer0]` immediately before the relayering call at hour 2,894, or add a targeted unit reproduction using the actual checkpoint's own recorded state for that cell/layer (readable from the `2880.soil_geometry_and_hydrology.bin`/`2880.soil_biogeochemistry.bin` checkpoint files already present in the scratchpad) rather than a live rerun.
2. **A different call site or a different mechanism entirely.** The `HourlyCellConservationFailure` gate's stderr trace (`hourly post-NITRO conservation trace`, printed just before the terminal error) shows `inorganic_and_gas_carbon_g_c` changing between the `after_uptake`/`after_chemistry`/`after_transport` trace points -- stages that are not named `relayering`/`REDIST` in this trace at all. This raises the possibility that the actual mass-losing step for this specific cell/hour is in root nutrient uptake, the reaction-solver network, or transport, not in any of the REDIST layer-relayering functions this issue and issues 060/061/063/064 have focused on. Not yet traced whether this trace's changes are legitimate (accounted elsewhere) or are the actual defect; the magnitudes in this trace (~0.2-0.4 g C swings) do not obviously match the failure's own residual (-7.66 g C at the outer scope), so this may be a red herring, but it has not been ruled out.
3. **The failure predates hour 2,894 and only becomes visible then.** Given the exact same residual recurs no matter which of four independent carrier-flooring fixes is applied, the actual defect may have already fully manifested (state already corrupted) at some earlier hour before the hour-2,880 checkpoint was even captured, and hour 2,894 is merely the first hour a validation gate happens to check the specific quantity/cell that was already wrong. If so, resuming from hour 2,880 can never diagnose this -- a fresh from-hour-1 (or from an earlier checkpoint, if one exists) run with the same instrumentation issue-063 added (`relayering_activity.zig`'s field-level diagnostic logging) would be needed to find the true first divergence, per the project's own G3 guidance ("diagnose the first divergence, not only the last failed hour").

## What this is not

- **Not a regression of issue-063's fix.** `RelayeringActivityConservationFailure` does not recur anywhere in this run's log.
- **Not a defect in the four fixes applied this pass.** Each is independently unit-tested and demonstrably correct for the synthetic scenario it targets. They are being kept (not reverted) because they are genuine, real fixes to a real defect class, confirmed by controlled tests -- they simply do not happen to be the cause of hour 2,894's specific failure.
- **Not yet confirmed to be caused by any of the three working hypotheses above.** All three are plausible from this pass's evidence; none has been tested with a targeted reproduction.

## Recommended next steps (not performed this pass)

1. Read the actual field-level composition of the `HourlyCellConservationFailure` gate (likely `hourly_cell_conservation.zig`, per issue-064's own "Recommended next steps" item 1, which this pass's fix addressed only for the `transferAqueousLayerFraction`/`transferSolidLayerFraction` carrier basis, not for the gate's own wiring) to determine exactly which fields/aggregators feed the ten failing quantities' before/after totals, and trace every mutation between those two captures for hour 2,894's specific cell/hour -- the same method issue-063's own root-cause investigation used successfully (ruling out hypothesis 1, confirming hypothesis 2), applied here fresh rather than assumed to be the same mechanism.
2. Test working hypothesis 1 (carrier convergence) first, since it is the cheapest: read the hour-2,880 checkpoint's own recorded `matrix_liquid_water_m3`/`dry_reference_water_m3` for cell 0/layer 0 directly from the checkpoint binary format (no rerun needed), or add one bounded diagnostic rerun with field-level logging at the exact call site.
3. If hypothesis 1 is ruled out, trace the `hourly post-NITRO conservation trace`'s stage-by-stage carbon changes (working hypothesis 2) before assuming any new carrier-flooring mechanism -- this failure may not be a `ZEROS2`-family defect at all.
4. If both are ruled out, consider working hypothesis 3 and whether a from-hour-1 (or earliest-available-checkpoint) rerun with issue-063's field-level `stageBoundary` diagnostic logging (already a permanent improvement, not diagnostic-only) is warranted, per the project's G3 "diagnose the first divergence" guidance -- this is the most expensive option and should be a last resort per the bounded-experiment discipline.
5. A cheap synthetic reproduction is strongly preferred over another full/resumed production run wherever the checkpoint's own recorded state can answer the question directly (per the project's bounded-experiment discipline, and per this pass's own experience that a full resumed rerun, while conclusive, is expensive relative to what it revealed here).

## Disposition

`unresolved` -- diagnosis needed. This is the actual frontier for the "production run completes to the end" goal; it has not moved since issue-063's own disposition, despite four independent, tested, legitimate fixes applied by issue-064's pass. Do not attempt another fix for the `ZEROS2`/`transferAqueousLayerFraction` mechanism specifically -- that hypothesis is closed (refuted). Issue-064's own fix and the three sweep-sibling fixes remain `legacy-defect-corrected` and are not reopened or reverted by this finding.
