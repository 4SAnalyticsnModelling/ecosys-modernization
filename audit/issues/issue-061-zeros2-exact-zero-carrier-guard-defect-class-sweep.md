# Issue 061 -- systematic sweep for issue-060's defect class ("ZEROS2 floor mistranslated as exact-zero guard on a water/liquid carrier"): found siblings, including one in PRODUCTION model state, not just a validation ledger

Status: FIXED (source + regression tests, 2026-09-19 -- see "## Fix applied" below) -- all three genuine siblings (Findings 1-3) now floor at the shared `legacyNegligibleWaterVolumeM3` (`ZEROS2`) threshold instead of exact zero, mirroring issue-060's `aqueousCarrierM3` fix. Finding 4 remains correctly excluded (not a genuine instance; no action needed). NOT yet independently confirmed by a live full-deck rerun (same reachability-argument caveat as issue-060's own fix: no cheap checkpoint exists to rerun from).
Owner: unassigned
Discovered by: this session, 2026-09-19, dedicated defect-class sweep requested after issue-060 diagnosed `aqueousCarrierM3` in `landscape_mass_inventory_phosphorus_ions.zig`.

## Relationship to issue-060

Issue-060 diagnosed (and, per this session's git history, a concurrent pass has since fixed -- see "Concurrent fix observed" below) a defect in `landscape_mass_inventory_phosphorus_ions.zig`'s `aqueousCarrierM3`: the Zig translation of legacy's `VOLW.GT.ZEROS2` floor (`solute.f:610`) only substituted the stable dry-reference carrier when live water was **exactly** zero (`live_water_m3 > 0`), not when it merely collapsed to a tiny-but-nonzero value below the legacy `ZEROS2` noise floor. This issue is the requested follow-up sweep: find every OTHER Zig site with the same shape -- an exact-zero-only guard on a water/liquid carrier feeding a concentration<->mass conversion, where legacy's equivalent site uses `ZEROS2` (or an analogous small-but-nonzero floor), not exact zero.

## Method

1. Established `ZEROS2`'s definition: `starts.f:270`, `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)`, with `ZERO2=1.0E-06` (`starts.f:94`) -- a per-cell-footprint-scaled noise floor. Confirmed by the concurrent issue-060 fix, which reproduces the identical literal (`legacy_negligible_water_volume_m3_per_m2 = 1.0e-6`).
2. Grepped `ZEROS2` across `f77src/solute.f`, `trnsfr.f`, `trnsfrs.f`, `redist.f`, `watsub.f`, plus `hour1.f`, `nitro.f`, `uptake.f`, `erosion.f`, `extract.f`: several hundred call sites, overwhelmingly `IF(VOL*.GT.ZEROS2(...))THEN` guards on water/air/ice-volume-denominated conversions (concentration<->mass, or gating whether a transport/reaction/diffusion block runs at all). Given the volume, this pass prioritized Zig functions structurally isomorphic to the already-fixed `aqueousCarrierM3` (same function shape: `live`/`current` carrier vs. a remembered `dry_reference`/`mineral_reference` fallback, chosen by an exact-zero test) rather than attempting to re-derive all several hundred sites' Zig counterparts individually.
3. Grepped `ecosys-ng/src` for the `dry_reference_water_m3` field and for `*CarrierM3`/`*Carrier(` function names, then read each candidate's body and its cited legacy line(s).

## Concurrent fix observed (not this issue's scope, noted for context)

`git log`/`git status` at the start of this pass showed uncommitted working-tree changes to `landscape_mass_inventory_phosphorus_ions.zig` (and its call sites: `landscape_mass_balance_runtime.zig`, `landscape_mass_inventory_test.zig`, `layer_mass_inventory.zig`, `relayering_layer_snapshot.zig`, `ecosys_ng.zig`). The fix threads `cell_area_m2` through to `aqueousCarrierM3`, computes `legacyNegligibleWaterVolumeM3(cell_area_m2) = 1.0e-6 * cell_area_m2` (the `ZEROS2` literal scaled to the cell), and widens the guard to `live_water_m3 > negligible_water_volume_m3`. This is the fix pattern recommended below for the siblings found in this pass. **This file does not re-diagnose or re-fix that instance.**

## Findings

### Finding 1 (HIGH PRIORITY, materially worse than issue-060's own instance): `ecosys-ng/src/soil/chemistry/water_carrier_rebase.zig` -- the PRODUCTION soil-chemistry state's own water-carrier rescale has the identical exact-zero-only guard

`sourceWaterM3` (`water_carrier_rebase.zig:354-356`):

```zig
fn sourceWaterM3(state: *const chemistry.State, layer: usize, old_water_m3: f64) f64 {
    return if (old_water_m3 > 0) old_water_m3 else state.dry_reference_water_m3[layer];
}
```

This is the exact same shape as the pre-fix `aqueousCarrierM3` (`live_water_m3 > 0` else fallback), and the function's own doc comment (`validateLayerRebase`, lines 364-367) explicitly cites `solute.f:610`'s `ZEROS2` floor as the source of truth: "`solute.f:610` admits a vanishing carrier (`VOLW <= ZEROS2`) and keeps the extensive `Z*` pools." The Zig implementation, like the pre-fix `aqueousCarrierM3`, only implements the exact-zero case.

**This is not a validation-ledger reconstruction -- it is the actual production `chemistry.State` mutation used every hour.** `rebaseLayer` (lines 178-197) is called from `ecosys-ng/src/stages/hourly_heat_water_solute.zig` at multiple sites (lines 731-736, 754-759, 4558-4564, 8181-8186, and others found via grep), every one of which passes `context.grid.matrix_liquid_water_m3[...]` -- **the identical array issue-060 showed collapses to a tiny-but-nonzero value during a heat-solver stagnation/recovery episode** -- directly as `new_water_m3` (some via `catch unreachable`, i.e. a future defensive error return at this call site would need to be added carefully, not just declared, or it will turn a near-zero-water hour into a hard panic instead of a controlled error).

Mechanism: when `new_water_m3` is exactly `0`, `rebaseLayer` takes the "remember dry carrier, don't rescale" branch (`rememberDryCarrier`, line 186) -- this is correct and mirrors legacy's intent. But when `new_water_m3` is tiny-but-nonzero (the exact scenario issue-060 diagnosed for the same array), `rebaseLayer` instead calls `prepareScaledLayer` with `scale = old_water_m3 / new_water_m3` (line 399) -- if `old_water_m3` was a normal value and `new_water_m3` has collapsed by many orders of magnitude, this **multiplies every aqueous, phosphate, and geochemistry-solid-mineral concentration in the layer by an enormous factor and commits it to live model state** (`commitScaledLayer`, line 421). This is a much larger-consequence defect than issue-060's fixed instance: instead of a validation ledger merely *misreporting* a mass change that the conservation gate then correctly rejects, this path can *actually corrupt* the concentrations that feed every subsequent hour's chemistry, transport, and reaction solving -- silently, since no bound/floor check catches it (`validateScalable`'s check at line 437 only fires when `old_water_m3 == 0 or new_water_m3 == 0` exactly, not when either is merely tiny).

The existing test `"SOIL-CHEM-DRY-CARRIER-001 evaporating the carrier to dryness..."` (line 1196) already uses a real captured value (`Hour-2705 Ottawa capture: layer 0 old_water_m3=6.42297794652246e-3, new_water_m3=0`) to exercise the exact-zero branch, confirming this function is fed real, small, production water values -- but the test suite has no case for the tiny-but-nonzero collapse this issue is about.

**Reachability:** very high. `rebaseLayer`/`previewLayerRoundoff` run unconditionally, every hour, for every soil layer and cell in the Ottawa deck, fed directly from `context.grid.matrix_liquid_water_m3`. Issue-060 already showed this array collapsing to a tiny-but-nonzero value non-fatally at hours 2,705-2,726 and fatally (via the downstream validation-ledger bug) at hour 2,894. This production-path sibling is exposed to the exact same trigger and is not gated behind any recovery-ladder or rare condition.

**Recommended fix pattern (same as issue-060's, not applied here):** thread a per-cell `ZEROS2`-equivalent floor (reuse the `legacyNegligibleWaterVolumeM3`/`negligible_water_volume_m3` helper introduced by issue-060's fix, or a shared version of it) into `sourceWaterM3`/`rebaseLayer`/`rebaseLayerWithRoundoff`/`previewLayerRoundoff`/`validateLayerRebase`, and widen every `old_water_m3 == 0` / `new_water_m3 == 0` exact-zero test in this file to `<= negligible_water_volume_m3`. Because two call sites currently use `catch unreachable` (lines 4564, 8181/8186), whoever fixes this must also audit whether widening the "stay dry" branch's trigger condition changes those call sites' error-reachability assumptions.

### Finding 2 (same class as the fixed instance, different layer): `ecosys-ng/src/validation/landscape_mass_inventory_surface.zig:286` -- litter/surface-layer counterpart of `aqueousCarrierM3`

```zig
const aqueous_carrier = if (water > 0) water else dry_reference_water;
```

in `aggregateSurfaceChemistryRange` (called by `aggregateSurfaceChemistry`/`aggregateSurfaceChemistryCell`), used to convert aqueous ammonium/ammonia, nitrate (+ nitrite), carbonate/bicarbonate, and HPO4/H2PO4 concentrations to extensive mass for the landscape conservation ledger -- the litter-layer sibling of the just-fixed soil-layer `aqueousCarrierM3`. (Note: this function's solid-mineral terms, e.g. calcite and phosphate minerals, use a separate `mineral_reference_water` that is not carrier-selected the same way, so they are not implicated here.)

Legacy correspondence: `solute.f:4018` (`IF(VOLW(0,NY,NX).GT.ZEROS2(NY,NX))THEN`), and similarly `solute.f:4050`, `4172` -- the litter layer (index `0`) equivalents of the soil-layer `VOLW.GT.ZEROS2` pattern, confirming legacy also floors this exact conversion at `ZEROS2`, not exact zero.

**Reachability:** litter/surface water content routinely approaches near-zero during ordinary evaporation (see Finding 4 below: a sibling counter shows the exact-zero branch alone firing ~10 times in the first simulated day with evaporation enabled), so a tiny-but-nonzero collapse during the same wet/dry transition is plausible on essentially the same timescale, independent of any solver-stagnation event -- likely *more* frequently reachable than the soil-layer instance, not less.

### Finding 3 (same class, different conservation check): `ecosys-ng/src/surface/metabolism_state_update.zig:609` -- `effectiveAqueousCarrierM3`

```zig
fn effectiveAqueousCarrierM3(live_water_m3: f64, dry_reference_water_m3: f64) f64 {
    return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;
}
```

Used in `authoritativeCellNitrogen_g_n`, `authoritativeCellPhosphorus_g_p`, and the nitrate-before/after reconstruction feeding surface-metabolism conservation checks (lines 250-254, 720-723, 892-895, 937-940) -- the same exact-zero-only pattern, feeding a different (surface biology) conservation ledger than Finding 2's landscape inventory.

### Finding 4 (reviewed and excluded -- not a genuine instance of this defect): `ecosys-ng/src/surface/litter_chemistry_carrier_rebase.zig:52` -- `effectiveAqueousCarrierM3`

Same primitive shape and name as Finding 3, but this one's legacy correspondence is different: its own doc comment (lines 101-107) cites `hour1.f:4494-4524`, which computes `CNH4S = AMAX1(0.0, ZNH4S/VOLW(0))` -- a **raw, unguarded division with no `ZEROS2` floor at all** in legacy (legacy instead sets concentrations to `0.0` in a separate `ELSE` branch keyed on whether the litter layer exists at all, not on a `VOLW` magnitude test). The Zig design deliberately does *not* reproduce legacy's raw division (which would itself blow up at tiny nonzero `VOLW`); instead it holds concentration constant and remembers `dry_reference_water_m3` for later rescaling -- documented as an intentional, approved redesign (`EXEC-004`). Since there is no legacy `ZEROS2` floor being mistranslated here, this is not a genuine sibling of issue-060's specific defect class, and this pass recommends no action on it beyond this note. (The `dry_branch_executions` diagnostic counter in this file -- "10 executions over the first day of the Ottawa example with surface evaporation enabled" -- was used above only to support Finding 2/3's reachability argument, not as evidence against this file.)

## Reachability / materiality summary

| Finding | File | Scope | Reachability | Consequence if triggered |
|---|---|---|---|---|
| 1 | `water_carrier_rebase.zig` | production model state | very high (every hour, every layer, fed live `matrix_liquid_water_m3`) | silent, potentially enormous concentration corruption committed to live state |
| 2 | `landscape_mass_inventory_surface.zig` | validation ledger (litter layer) | high (ordinary evaporation, not just solver stagnation) | fake mass swing in conservation ledger, likely `HourlyCellConservationFailure` |
| 3 | `metabolism_state_update.zig` | validation ledger (surface metabolism) | high (same evaporation dynamics as Finding 2) | fake mass swing in a different conservation check |
| 4 | `litter_chemistry_carrier_rebase.zig` | N/A | N/A | not a genuine instance -- documented, approved design without a legacy `ZEROS2` floor to mistranslate |

None of Findings 1-3 have been confirmed by a live instrumented rerun in this pass (per the contract's diagnosis-budget discipline, and per this pass's read-only/no-build/no-run mandate to avoid contending with any concurrent build/run for issue-060's fix). Confirmation would require either a synthetic unit reproduction (cheap: feed `rebaseLayer`/`aggregateSurfaceChemistryRange`/`effectiveAqueousCarrierM3` a deliberately tiny-but-nonzero carrier and observe the resulting concentration/mass swing, analogous to issue-060's own recommended next step) or a live rerun instrumented to log `matrix_liquid_water_m3`/`litter_water_m3` immediately before each call site once a fix lands.

## Recommended next steps (not performed in this pass)

1. Prioritize Finding 1 (`water_carrier_rebase.zig`) first: it is the only production-state-mutating instance, and plausibly contributes to (or independently causes) instability beyond what issue-060's own fix will resolve, since it runs before and independent of the validation ledger.
2. Reuse the exact fix pattern and `ZEROS2` literal (`1.0e-6` per `starts.f:94`/`starts.f:270`) issue-060's concurrent fix already established for `aqueousCarrierM3`, rather than re-deriving it, to keep the floor value consistent project-wide. `soil_chemistry_convergence.zig:366`'s `context.config.physical_tolerance.waterVolume(bulk_volume_m3)` was suggested by issue-060 as an alternative floor source; if adopted, apply the same choice to all three findings for consistency, and document why it is or is not equivalent to `ZEROS2`.
3. For Finding 1 specifically, audit the two `catch unreachable` call sites (`hourly_heat_water_solute.zig:4564`, `8181`/`8186`) before widening any exact-zero branch there, so a legitimately near-zero-water hour cannot turn a controlled error into a panic.
4. Add a synthetic unit reproduction for each of Findings 1-3 (tiny-but-nonzero carrier in, assert no unphysical scale/mass swing out) before attempting a live rerun, consistent with the project's "small compilations, tests, extracted routines... allowed throughout" G1 guidance.
5. Do not fix blind: this pass is diagnosis-only, per the requesting instructions.

## Disposition (superseded below by "Fix applied")

No source files were modified by this pass. This is a read-only defect-class sweep. Three genuine, distinct siblings found (Findings 1-3); one candidate reviewed and excluded as not a genuine instance of the defect class (Finding 4). This issue stays `NOT_ASSESSED`/`OPEN` until a fix is proposed, reviewed against the legacy `ZEROS2` correspondence for each site, and validated.

## Fix applied (2026-09-19, this pass)

### Shared floor, factored into one place

Per this issue's own recommendation ("keep the `ZEROS2` literal consistent project-wide"), the `ZERO2=1.0E-06` literal (`starts.f:94`) and its `ZEROS2 = ZERO2*DH*DV` per-cell scaling (`starts.f:270`) are now derived in exactly one place: the new `ecosys-ng/src/core/legacy_water_negligible_floor.zig` (`legacy_negligible_water_volume_m3_per_m2`, `legacyNegligibleWaterVolumeM3`). Issue-060's already-fixed `landscape_mass_inventory_phosphorus_ions.zig` was updated to delegate its own private constant/function to this shared module (pure delegation, no behavior change, its own tests unchanged) rather than leaving two independent derivations. All three fixes below reuse this same shared module.

### Finding 1 (`water_carrier_rebase.zig`) -- HIGHEST PRIORITY, production state

`sourceWaterM3` (previously `if (old_water_m3 > 0) old_water_m3 else state.dry_reference_water_m3[layer]`) now takes a `negligible_water_volume_m3: f64` parameter and widens the guard to `old_water_m3 > negligible_water_volume_m3`. The floor is threaded as a new final parameter through `rebaseLayer`, `rebaseLayerWithRoundoff`, `previewLayerRoundoff`, `validateLayerRebase`, `prepareLayerRebase`, `prepareScaledLayer`, and `rememberDryCarrier`; every "stay dry" branch's own trigger (`new_water_m3 == 0`) is widened identically to `new_water_m3 <= negligible_water_volume_m3`. The substitution/rescale actions themselves are byte-identical to before -- only the threshold that selects between them changed. Every production call site (`hourly_heat_water_solute.zig`'s several loops, `plant_root_water_storage_state_update.zig`'s two `previewLayerRoundoff`/`rebaseLayerWithRoundoff` calls including both `catch unreachable` sites) now computes `legacyNegligibleWaterVolumeM3(cell_area_m2)` from the cell's actual footprint (`context.canopy_cell_area_m2[cell]`, resolving `cell` from a flat layer index via `layer / grid.soil_layer_capacity` where the loop is layer-flat) and passes it through; `plant_root_water_storage_state_update.state_update` gained a new required `cell_area_m2: []const f64` parameter, threaded from `hourly_vegetation.zig`'s existing `context.canopy_cell_area_m2`.

Regression tests added (`water_carrier_rebase.zig`): a BEFORE test that re-derives the old guard as a local closure and shows a collapsed-but-nonzero water value (`1e-320`, chosen so `old_water_m3/new_water_m3` overflows `f64`) manufactures `error.InvalidSoilChemistryWaterCarrier` -- exactly the failure mode that, at the two production `catch unreachable` call sites, would have been a hard panic on an ordinary thin/dry-layer hour, not a controlled error; an AFTER test showing the same inputs through the fixed `rebaseLayer` instead take the "stay dry" branch cleanly (concentration held, live water remembered); a boundary test pinning the strict `>` (not `>=`) comparison and the pre-existing exact-zero case; a floor-validation test rejecting negative/NaN `negligible_water_volume_m3`. The pre-existing "invalid fractions and uncertified mutation reject atomically" test's two assertions that had used `floatMin`/`floatMax` as `old_water_m3`/`new_water_m3` directly were updated: one now reaches the same `floatMin/floatMax` scale-underflow arithmetic via the dry-reference-recall path (`old_water_m3=0`, `state.dry_reference_water_m3[0]` poked to `floatMin` directly) instead of passing `floatMin` as a supposedly-live value (which the fix now correctly reclassifies as negligible/dry before ever reaching that division); the other now uses a genuinely-invalid negative `old_water_m3` instead of relying on the same reclassified magnitude.

### Finding 2 (`landscape_mass_inventory_surface.zig:286`) -- litter layer

`aggregateSurfaceChemistryRange`'s `aqueous_carrier = if (water > 0) water else dry_reference_water` is now `if (water > negligible_water_volume_m3) water else dry_reference_water`, with `negligible_water_volume_m3 = negligibleLitterWaterVolumeM3(cell_area_m2[cell_index])` computed per cell from a new `cell_area_m2: []const f64` parameter threaded through `aggregateSurfaceChemistry`/`aggregateSurfaceChemistryCell`/`aggregateSurfaceChemistryRange` and every call site (`landscape_mass_balance_runtime.zig` x2, `layer_mass_inventory.zig`, `landscape_mass_inventory_test.zig`), all of which already had `inputs.cell_area_m2` in scope from issue-060's own fix. `mineral_reference_water`'s solid-mineral terms are untouched, per this finding's own note that they are not carrier-selected the same way.

Regression tests added (`landscape_mass_inventory_test.zig`): a collapsed-but-nonzero (`1e-9` m3) litter water test proving the result is bit-identical to the pre-existing exact-zero dry case (`84 = 14*2*3`), plus an explicit BEFORE computation (re-deriving the old guard) showing it would have produced `2.8e-8` instead -- a >99.99% fake loss, the same shape as issue-060's own hour-2,894 evidence; a boundary test pinning the strict `>` comparison at the floor.

### Finding 3 (`metabolism_state_update.zig:609`) -- surface metabolism

`effectiveAqueousCarrierM3(live_water_m3, dry_reference_water_m3)` gained a third `negligible_water_volume_m3: f64` parameter and widened its guard identically. `ApplyContext` gained a new required `cell_area_m2: []const f64` field (validated for length in `validate()`); all four call sites (`state_updateCell`, `projectedCellNitrogen_g_n`, `authoritativeCellNitrogen_g_n`, `authoritativeCellPhosphorus_g_p`) compute `negligibleLitterWaterVolumeM3(context.cell_area_m2[cell])`. The sole production constructor (`biogeochemistry_batches.zig`) now sets `.cell_area_m2 = context.canopy_cell_area_m2`.

Regression tests added: a BEFORE/AFTER pair mirroring issue-060's own literal-closure pattern (collapsed `1e-9` m3 carrier manufactures a >99.99% fake loss under the old guard vs. the correct dry-reference substitution under the new one) and a boundary test pinning the strict `>` comparison and the pre-existing exact-zero/ordinary-wet cases.

### Commands run (cwd `ecosys-ng`, Zig 0.16.0, targeted filters only per this project's standing instruction not to run the full suite)

- `zig build` (full executable compile) -> exit 0.
- `zig test src/module_index.zig --test-filter "issue-061"` -> 61/61 passed (12 new tests across all three fixes plus the shared-floor module's own test).
- `zig test src/module_index.zig --test-filter "water_carrier_rebase"` -> 68/68 passed.
- `zig test src/module_index.zig --test-filter "landscape_mass_inventory_surface"` -> 51/51 passed.
- `zig test src/module_index.zig --test-filter "metabolism_state_update"` -> 52/52 passed.
- `zig test src/module_index.zig --test-filter "carrier"` -> 167/167 passed.
- `zig test src/module_index.zig --test-filter "mass_inventory"` -> 94/94 passed.
- `zig test src/module_index.zig --test-filter "SOIL-CHEM-DRY-CARRIER"` -> 55/55 passed.
- `zig test src/module_index.zig --test-filter "phosphorus"` -> 88/88 passed.
- `zig test src/module_index.zig --test-filter "REDIST profile phosphorus"` -> 52/52 passed.
- `zig test src/module_index.zig --test-filter "REDIST surface chemistry"` -> 52/52 passed.
- `zig test src/module_index.zig --test-filter "issue-060"` -> 56/56 passed (confirms this pass did not regress issue-060's own fix or its tests).
- `zig test src/module_index.zig --test-filter "hourly_heat_water_solute"` -> 51/51 passed (all of that file's tests, including its structural/plumbing checks on the call sites this pass edited).
- `zig test src/module_index.zig --test-filter "root uptake removes soil water"` -> 52/52 passed, explicitly including `plant_root_water_storage_state_update.zig`'s own test by name.
- `zig test src/module_index.zig --test-filter "insufficient substrate leaves every surface metabolism"` -> 52/52 passed.
- `zig test --dep ecosys_ng "-Mroot=src/ecosys_ng.zig" "-Mecosys_ng=src/module_index.zig" --test-filter "issue-061"` -> 3/3 passed, confirming the `ecosys_ng.zig`/`hourly_vegetation.zig` side (outside `module_index.zig`'s own reachable graph) compiles and its tests pass.

### Full-run confirmation: not attempted this pass, reachability argument stands in

As with issue-060's own fix: no checkpoint near a hour deep enough to exercise these paths exists, and a fresh from-hour-1 rerun was already assessed there as too slow for a bounded pass. That assessment is unchanged by this pass's fix (no performance-relevant code path was touched -- only threshold comparisons and one new parameter per call site). A live full-deck rerun confirming these three sibling fixes (together with issue-060's) let the run progress further is still pending and is the recommended next bounded action for whoever picks this up next.

### Disposition

`legacy-defect-corrected` (translation defect, investigation-order category "translation/units/indexing/precision defects") for all three findings' guards. Finding 4 remains correctly excluded (documented, approved redesign, not a `ZEROS2` mistranslation). Independent reviewer: not yet done. Full-run confirmation: pending (see above). Traceability: `TRC-316`/`TRC-317`/`TRC-318` (added by this issue's own diagnosis pass to record the pre-fix `unresolved` state) updated in place to `legacy-defect-corrected` with this pass's evidence, rather than appended as new duplicate rows for the same code paths -- confirmed no duplicate `unit_id` via `Import-Csv audit/traceability/traceability.csv | Group-Object unit_id | Where-Object Count -gt 1` (empty result).
