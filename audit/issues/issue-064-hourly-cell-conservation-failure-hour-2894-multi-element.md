# Issue 064 -- after issue-063's carrier-consistency fix, hour 2,894 now fails on a DIFFERENT, previously-masked gate: `HourlyCellConservationFailure` across many elements

Status: NOT_ASSESSED/OPEN -- diagnosis-only, filed promptly per the project's "do not fix blind" discipline. Not fixed this pass.
Owner: unassigned
Discovered by: this session, 2026-09-19, immediately after implementing and validating issue-063's fix (`chemistry_remap.transferSolidLayerFraction` carrier-consistency, Option A) and re-running the same resumed hour-2,880 checkpoint used by issue-062/063.

## Summary

Issue-063 diagnosed and fixed a carrier-basis mismatch in `relayering.zig`'s call to `chemistry_remap.transferSolidLayerFraction` (the mutator used raw, unfloored live water; the census used the floored `aqueousCarrierM3` substitution), which manufactured fake `carbon_dioxide_carbon_g` mass at hour 2,894's degenerate cell-0/layer-0 boundary and tripped `relayering_activity.zig`'s `RelayeringActivityConservationFailure`.

**That fix is confirmed effective**: re-running the identical resumed scenario with the fixed binary shows no `RelayeringActivityConservationFailure` at hour 2,894 at all. However, **hour 2,894 still does not complete**. Execution now proceeds further into the hour (past the relayering-activity check) and fails at a later, broader validation stage with a new terminal error: `HourlyCellConservationFailure`, reporting large, simultaneous mass mismatches for **carbon, nitrogen, phosphorus, aluminum, iron, calcium, magnesium, sodium, potassium, and silicon** at cell 0.

This is exactly the "masking risk" issue-063 itself warned about, materializing at a different (broader) validation gate than the one issue-063 named.

## Evidence

Live run: resumed from the hour-2,880 checkpoint (`prod-run-issue062-verify/`, copied to `prod-run-issue063-verify/`, freshly built `ReleaseFast` binary with issue-063's fix, invoked `ecosys_ng.exe --execution-evidence verify063-evidence.json runottawa`). Execution journal (`verify063-evidence.json`) shows hour 2,894 `attempted` but never `committed`/`accepted` (hours 2,881-2,893 all committed/accepted normally). Full stderr (`verify063-stderr.log`) shows, in order: the same WATSUB-6907 heat-floor discard warning as before (issue-062's already-fixed, expected, legacy-faithful mechanism, unaffected); **no** `RelayeringActivityConservationFailure` line; then:

```
error: hourly cell conservation failure: cell=0 quantity=carbon before=6.139931762355135e3 after=6.132080644694612e3 ... residual=-7.657654094846645e0 ... normalized_relative=9.753584681771447e-1 ...
error: hourly cell conservation failure: cell=0 quantity=nitrogen ... residual=-9.74378892114669e-3 ...
error: hourly cell conservation failure: cell=0 quantity=phosphorus ... residual=-5.411409046040926e0 ... normalized_relative=1.0000002103350032e0 ...
error: hourly cell conservation failure: cell=0 quantity=aluminum before=1.0172695194103026e4 after=1.0134189273766877e4 ... residual=-3.8505920339067494e1 ... normalized_relative=1.0000000000757974e0 ...
error: hourly cell conservation failure: cell=0 quantity=iron ... residual=-3.586034566540333e1 ...
error: hourly cell conservation failure: cell=0 quantity=calcium ... residual=-3.40929439883276e1 ...
error: hourly cell conservation failure: cell=0 quantity=magnesium ... residual=-3.337844719461464e1 ...
error: hourly cell conservation failure: cell=0 quantity=sodium ... residual=-3.337845257319532e1 ...
error: hourly cell conservation failure: cell=0 quantity=potassium ... residual=-3.3378449999303484e1 ...
error: hourly cell conservation failure: cell=0 quantity=silicon ... residual=-1.0013639440922263e2 ...
```

then a second, smaller-scale block reporting the **same ten quantities again** with different absolute pool sizes but nearly identical residual magnitudes (e.g. aluminum residual `-3.850592033906913e1` vs. the first block's `-3.8505920339067494e1`; iron, calcium, magnesium, sodium, potassium, silicon residuals match to 8+ significant figures between the two blocks) -- consistent with the same fixed-magnitude manufactured-mass artifact being visible at two different aggregation scopes (this session did not fully trace which two validators/scopes these are; see "Not yet done" below), not two independent defects. Terminal error: `RelayeringActivityConservationFailure` does not recur; the run now fails with `HourlyCellConservationFailure`.

Full logs preserved at (session scratchpad, not durable/tracked): `prod-run-issue063-verify/verify063-stderr.log`, `verify063-stdout.log`, `verify063-evidence.json`.

## Working hypothesis (not confirmed by a targeted experiment this pass)

The failing-element list -- aluminum, iron, calcium, magnesium, sodium, potassium (plus carbon/silicon) -- matches, field-for-field, `chemistry.aqueous[...]`'s `isBasePondedAqueousField` list (`ecosys-ng/src/soil/chemistry/layer_remap.zig:625`: `hydrogen`, `hydroxide`, `aluminum`, `iron`, `calcium`, `magnesium`, `sodium`, `potassium`) -- the free aqueous-ion pools moved by `transferAqueousLayerFraction`, **not** the geochemistry-solid/phosphate-precipitate pools issue-063 fixed. `relayering.zig`'s call to `transferAqueousLayerFraction` (item "4a. Aqueous chemistry", lines ~490-506) builds its `ZoneWaterVolumes` via `waterZones(src_water_before, ...)`/`waterZones(dst_water_before, ...)`/`waterZones(src_water_after, ...)`/`waterZones(dst_water_after, ...)` from the same **raw**, unfloored `src_water_before`/`dst_water_before`/`src_water_after`/`dst_water_after` values -- this call site was explicitly named, but deliberately not touched, in issue-063's own diagnosis ("`transferAqueousLayerFraction`'s own raw `ZoneWaterVolumes` ... not yet checked against the same floor").

This strongly suggests the **same carrier-basis mismatch mechanism** (mutator divides by a raw near-zero carrier; some census/whole-hour-balance reader elsewhere uses a floored carrier for the same field) recurs one call site over, on the aqueous free-ion pools instead of the solid/precipitate pools. Silicon and carbon's continued appearance could be residual attribution from the same cell's other pools (e.g. silicon from geochemistry silicates already fixed by issue-063, now showing a smaller residual than before but not zero; or from a different, not-yet-identified contributor) -- **not yet traced**, and should not be assumed without checking.

**Not confirmed to be `transferAqueousLayerFraction` specifically** -- this is a plausible, well-evidenced hypothesis from field-name overlap and this issue's own prior art, not a targeted reproduction. Per the project's three-experiment discipline, this is Experiment 0 (an observation from the validation run performed for issue-063, not a dedicated experiment for this issue); a real Experiment 1 should be a targeted read of `hourly_cell_conservation.zig`'s actual census wiring (does it call the same `aqueousCarrierM3`-floored path, or a different one?) before any fix is attempted.

## What this is not

- **Not a regression of issue-063's fix.** `RelayeringActivityConservationFailure`/`carbon_dioxide_carbon_g` does not recur anywhere in the new run's log; the specific mechanism issue-063 diagnosed and fixed is gone.
- **Not yet confirmed to be `transferAqueousLayerFraction`.** That is a hypothesis from field-name overlap with issue-063's own prior art, not a targeted reproduction.
- **Not necessarily a single element's defect.** Ten quantities fail simultaneously at the same cell/hour; this is consistent with one shared call-site defect (carrier consistency) affecting several element-bearing pools at once, matching the exact "per-call-site, not per-field" pattern issue-063 itself identified for the previous mechanism.

## Recommended next steps (not performed this pass)

1. Read `hourly_cell_conservation.zig`'s actual census wiring in full: which fields/aggregators feed its before/after carbon/nitrogen/phosphorus/aluminum/iron/calcium/magnesium/sodium/potassium/silicon totals, and do any of them read `chemistry.aqueous[...]`/`geochemistry_solids[...]` through a floored carrier while some other mutator (candidate: `transferAqueousLayerFraction`) still writes through a raw one?
2. If `transferAqueousLayerFraction` is confirmed: thread the same `solidTransferWaterCarrierM3`/`aqueousCarrierM3`-equivalent floor into `relayering.zig`'s `waterZones(...)` calls at the aqueous-chemistry call site (item "4a"), mirroring issue-063's fix pattern exactly, then re-validate with the same resumed checkpoint.
3. A cheap synthetic reproduction (matching issue-063's own regression-test pattern: construct a degenerate near-zero water carrier, call `transferAqueousLayerFraction` directly, compare against a floored-carrier census read) is strongly preferred over another full/resumed production run, per the project's bounded-experiment discipline.
4. Trace why the same ten quantities appear in two consecutive log blocks with near-identical residual magnitudes but different absolute pool sizes -- confirm this is one defect observed at two aggregation scopes (e.g., a per-process-stage trace vs. the authoritative hourly gate) rather than two independent defects, before scoping any fix.

## Disposition

No source fix attempted this pass -- diagnosis-only, filed promptly per the project's established discipline. This is the new frontier for the "production run completes to the end" goal as of this pass. Issue-063's own fix and disposition are unaffected and not reopened by this finding.
