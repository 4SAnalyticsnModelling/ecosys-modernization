# Issue 066 -- `litter_ammonia_phase_bridge.zig`'s `refreshTransientFromChemistry`/`publishTransientToChemistry` round trip uses an exact-zero-only litter-water guard instead of the shared `ZEROS2`/`dry_reference_water_m3` carrier substitution -- a pack/unpack-shaped sibling the issue-061 keyword sweep could not have found

Status: FIXED (disposition legacy-defect-corrected) -- fix applied 2026-09-20 with OLD/NEW regression tests. `litter_ammonia_phase_bridge.zig`'s `refreshTransientFromChemistry`/`publishTransientToChemistry` now take a `cell_area_m2` parameter, derive the `ZEROS2` floor via `legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3`, and route both the pack multiply and unpack divide through the new `litterAmmoniaCarrierM3` helper instead of the raw exact-zero water guard. Both call sites in `litter_gas_transport_step.zig`'s `advanceWithFailureReport` updated to pass `cell_area_m2` (already a parameter there). Existing "dry retained ammonia" test renamed and re-asserted to the corrected expected values; two new issue-066 OLD/NEW regression tests added. `litter_chemistry_carrier_rebase.zig` required no code change -- see "Fix disposition" below. Targeted `zig test` runs (module root `src/module_index.zig`, `--test-filter` scoped) confirm all 5 `litter_ammonia_phase_bridge.zig` tests and all 3 `litter_gas_transport_step.zig` tests pass; `zig build -Doptimize=ReleaseFast` succeeds (3/3 steps). Not yet independently reviewed; not execution-confirmed against a live production run (per this fix's own item 7, a full-deck rerun is not required to accept this fix).
Owner: unassigned
Discovered by: this session, 2026-09-19, dedicated read-only sweep requested specifically for pack/unpack (or otherwise bidirectional/round-trip) water-carrier functions that issue-061's `*Carrier*`/`*WaterVolumes*`/`rebase`/`transfer`/`remap`/`relayer` keyword sweep could not have matched, following issue-065's ninth/tenth addenda locating and fixing the structurally analogous `erosion_chemistry_bridge.zig` `packMapped`/`unpackMapped` defect.

## Summary

`ecosys-ng/src/surface/litter_ammonia_phase_bridge.zig` owns the one-hour transient mirror between `litter_chemistry.State`'s aqueous ammonia concentration (`ammonia_mol_per_m3`, mol N/m3) and the generic surface-litter gas solver's extensive dissolved mass (`gas.State.dissolved_mass_g`, g N), for the coupled gas/water NH3 phase-exchange equation (`hour1.f:4494-4603`, cited in this file's own doc comment). Two functions form an exact pack/unpack pair, named with a different convention than the `*Carrier*`/`*WaterVolumes*` family issue-061's keyword sweep targeted:

- `refreshTransientFromChemistry` (pack: concentration -> extensive mass), `litter_ammonia_phase_bridge.zig:13-39`
- `publishTransientToChemistry` (unpack: extensive mass -> concentration), `litter_ammonia_phase_bridge.zig:41-75`

Both gate on the litter water carrier with an **exact-zero-only** test (`water > 0` / `water == 0`), never consulting `chemistry_state.dry_reference_water_m3` (a field this file's own `validateDimensions` already reads and range-checks, but never uses for substitution in the pack/unpack arithmetic itself). This is the identical defect shape issues 060/061/063/064/065 already found and fixed at eight-plus other call sites: a `VOLW.GT.ZEROS2`-style legacy floor mistranslated as `live_water_m3 > 0`, so a live water value that has collapsed to a tiny-but-nonzero noise magnitude (below the shared `ZEROS2`/`legacyNegligibleWaterVolumeM3`/`negligibleLitterWaterVolumeM3` floor established by issue-060/061's own fixes) is used directly as the mass carrier instead of substituting the remembered `dry_reference_water_m3`.

This file was not found by issue-061's own sweep because its guard functions are unnamed inline conditionals (`if (water > 0) ... else 0`), not a dedicated `*CarrierM3`/`effectiveAqueousCarrierM3`-named helper, and the file itself is named `*_phase_bridge.zig`, not matched by any of issue-061's search terms (`*Carrier*`, `*WaterVolumes*`, `rebase`, `transfer`, `remap`, `relayer`). It was found this pass specifically by searching for pack/unpack-shaped bidirectional round trips per this pass's own explicit mandate (item 1), the same method issue-065's ninth addendum used to localize `erosion_chemistry_bridge.zig`.

## Evidence

### The pack side (`refreshTransientFromChemistry`, lines 20-38)

```zig
for (chemistry_state.cells, litter_water_m3, 0..) |cell, water, cell_index| {
    const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
    gas_state.dissolved_mass_g[index] = if (water > 0)
        cell.ammonia_mol_per_m3 * water * nitrogen_molar_mass_g_per_mol
    else
        0;
    ...
}
```

When `water` is tiny-but-nonzero (e.g. `1e-9` m3, well below the shared litter floor `negligibleLitterWaterVolumeM3(cell_area_m2)` issue-061's Finding 2 fix already established for the sibling `landscape_mass_inventory_surface.zig`/`metabolism_state_update.zig` litter-carrier consumers), this branch is taken as though the layer were normally wet: `dissolved_mass_g` is set to `concentration * (tiny water) * molar_mass`, a near-zero extensive mass, discarding the true extensive amount the concentration represents against the codebase's own convention for a degenerate carrier.

### The unpack side (`publishTransientToChemistry`, lines 53-74)

```zig
if (water == 0) {
    const scale = @max(1.0, dissolved);
    if (dissolved > absolute_tolerance_g_n + relative_tolerance * scale)
        return error.LitterAmmoniaWithoutWaterCarrier;
}
...
for (litter_water_m3, 0..) |water, cell_index| {
    if (water == 0) continue;
    ...
    chemistry_state.cells[cell_index].ammonia_mol_per_m3 =
        gas_state.dissolved_mass_g[index] / nitrogen_molar_mass_g_per_mol / water;
}
```

Only the **exactly**-zero case holds `ammonia_mol_per_m3` unchanged (the safe, legacy-analogous "layer does not exist / is fully dry" branch, matching the already-reviewed-and-excluded `litter_chemistry_carrier_rebase.zig` design, issue-061 Finding 4). A tiny-but-nonzero `water` instead divides by it directly, producing a concentration consistent with the pack side's own tiny-carrier basis -- internally self-consistent as a round trip, but only because *both* sides independently mistranslate the same floor the same way, not because either substitutes the correct `dry_reference_water_m3` carrier the rest of the codebase already centralizes for this exact condition (`water_carrier_rebase.zig`'s `sourceWaterM3`, the census's `aqueousCarrierM3`, `erosion_chemistry_bridge.zig`'s now-fixed `erosionWaterCarrierM3`, and this same file's own sibling `litter_chemistry_carrier_rebase.zig`'s `effectiveAqueousCarrierM3`, all reviewed by issues 060/061/065).

### Why this is not merely a harmless closed round trip

Real physics runs between the pack and unpack calls, not just an inert copy. `litter_gas_transport_step.zig:178-315` (`State.advance`) is the sole production caller:

1. `ammonia_bridge.refreshTransientFromChemistry(...)` (line 178) -- pack.
2. The coupled gas/water exchange solver (`solver.solve`, lines 255-274) mutates `gas_state.dissolved_mass_g[ammonia]` via real atmospheric/aqueous partitioning kinetics (`litterGasExchange`, `surfaceSolubilityWaterToAir`), using the packed mass as its actual extensive-mass input/output.
3. `ammonia_bridge.publishTransientToChemistry(...)` (line 308) -- unpack.

If the packed extensive mass at a degenerate (tiny-but-nonzero) litter-water hour is manufactured near-zero instead of the true amount (`concentration * dry_reference_water_m3`), the solver equilibrates the wrong (near-zero) ammonia inventory against the atmosphere and the aqueous/gaseous phase split for that hour -- a genuine physics/conservation defect passed through the solver, not merely a bookkeeping artifact caught after the fact.

**This defect is also structurally worse than its already-fixed siblings in one specific way**: the file's own per-species conservation closure check, immediately before the unpack call (`litter_gas_transport_step.zig:279-306`, "surface litter gas owner closure failure"), **explicitly excludes ammonia**:

```zig
for (0..self.cell_count) |cell| for (0..gas.species_count) |species| {
    if (species == @intFromEnum(gas.Species.ammonia)) continue;
    ...
};
```

Every other tracked gas species (CO2, CH4, O2, N2, N2O, H2) has its before/after/atmospheric-flux closure checked and would raise `error.SurfaceLitterGasOwnerClosureFailure` on an unexplained mass change of this shape. Ammonia alone is skipped, so a manufactured mass discard at this call site would **not** be caught by this file's own conservation gate at all -- a strictly less-supervised version of the "silent, unbooked discard" shape issue-065's seventh/eighth addenda catalogued for the SOLUTE capacity-floor gate and the WATSUB-6907 heat discard's own unbooked chemistry analog.

### Reachability

`litter_water_m3` is the same live surface-litter water content issue-061 Finding 2/3 already established "routinely approaches near-zero during ordinary evaporation... likely *more* frequently reachable than the soil-layer instance." `State.advance` runs this pack/unpack pair unconditionally every hour the surface litter gas solver executes (no gating on ammonia presence or litter existence beyond the dimension/shape validation already performed). No new run was required to establish this: the reachability argument is identical to, and reuses, issue-061's own already-recorded evidence for the sibling litter-carrier consumers it fixed.

### Confirmed NOT the same defect: `ammonia_phase_bridge.zig` (soil/TRNSFR mineral-N variant)

The soil-column sibling bridge (`ecosys-ng/src/soil/gas/ammonia_phase_bridge.zig`, TRNSFR's mineral-N matrix inventory) was read in full this pass and is **not** a genuine instance: `refreshTransientFromMineral`/`publishTransientToMineral` copy `mineral_state.matrix.amount_mol` (an already-extensive mol quantity) directly into/out of the gas mirror, multiplied only by the fixed `nitrogen_molar_mass_g_per_mol` constant -- no water-volume carrier of any kind is read or divided by anywhere in that file. This is a clean, correctly-scoped exclusion, not an overlooked second instance.

### Confirmed NOT a new instance: the erosion sibling bridges

Per this pass's item 3/4 checks: `erosion_mineral_bridge.zig`, `erosion_fertilizer_bridge.zig`, `erosion_mineral_fertilizer_bridge.zig`, and `erosion_organic_bridge.zig` (the four siblings of the now-fixed `erosion_chemistry_bridge.zig` in `ecosys-ng/src/soil/profile/`) were each read/grepped for any water-carrier usage. None reference `water`/`dry_reference_water_m3` in their pack/unpack/route logic at all -- they are soil-mass-scaled (`canonical_soil_mass`, `soil_mass_megagrams`) or already-extensive (`organic.ElementPool`), not concentration-basis fields requiring a water carrier. `erosion_chemistry_bridge.zig` itself was re-read in full this pass: its only water-scaled functions are the already-fixed `pack`/`packMapped`/`unpack`/`unpackMapped`, all four of which already route through the fixed `erosionWaterCarrierM3`; no other function in the file performs a water-scaled concentration<->mass conversion. Item 3 of this pass's mandate is answered: no other unfixed function exists in that file.

### Noted but explicitly not filed: `aqueous_transport_bridge.zig`'s `exportChemistry`/`importChemistry`

`ecosys-ng/src/soil/solute/aqueous_transport_bridge.zig` (the TRNSFRS-equivalent aqueous-transport bridge) has the identical pack/unpack shape (`exportChemistry`/`importChemistry`, plus a dedicated `exportCarrierM3` helper) and was found by this pass's own search. Its source already carries an in-progress fix, doc-commented `"ISSUE-065 (eleventh addendum)"`, substituting `chemistry_state.dry_reference_water_m3[cell]` exactly per this defect class's established pattern, plus two new regression tests reproducing hour 2,894's own recorded values. `git status --short` at the repository root confirms this file (along with `ecosys_ng.zig`, `stages/diagnostics.zig`, `stages/hourly_process_driver.zig`, `stages/soil_chemistry_convergence.zig`, `tillage_adapter_compile_test.zig`) is currently **uncommitted working-tree state**, consistent with this task's own briefing that a concurrent agent has an active build/run in progress for issue-065. This pass leaves that file, and every other file with uncommitted changes, untouched -- it is not a new discovery for this issue to claim, and no addendum text for it yet exists in `issue-065-*.md` itself (only in the source comment), consistent with that pass being mid-flight rather than complete.

## What this proves

- A genuine, previously-undiscovered sibling of the issue-060/061/063/064/065 defect class exists in `litter_ammonia_phase_bridge.zig`, reachable every hour the surface-litter gas solver runs, via a naming convention (`refreshTransientFromChemistry`/`publishTransientToChemistry`) issue-061's keyword-based sweep could not have matched.
- It is a symmetric pack-then-later-unpack round trip (concentration->mass pack, mass->concentration unpack), the same structural shape issue-065's ninth addendum identified as distinct from the one-directional `*Carrier*` family, confirming the task's premise that this shape class needed its own dedicated search.
- It is arguably higher-risk than several already-fixed siblings because the one local conservation gate that could have caught a manufactured mass discard (`litter_gas_transport_step.zig`'s own per-species closure check) explicitly excludes the ammonia species from that check.
- The two clean exclusions (`ammonia_phase_bridge.zig`, the four non-chemistry erosion sibling bridges) and the one already-being-fixed file (`aqueous_transport_bridge.zig`) demonstrate this pass's search was not merely pattern-matching on file names -- each candidate was read and individually assessed against the defect's actual mechanism (a water-carrier multiply/divide using raw live water without floor+substitution), consistent with the project's "do not count a keyword search... as a semantic proof" evidence discipline.

## What this is not

- **Not execution-confirmed against a live run.** No rerun was performed this pass (read-only/no-build/no-run mandate, avoiding contention with the concurrent issue-065 build/run). The claim rests on static reading of the pack/unpack arithmetic, the confirmed-unconditional production call site, and the explicit ammonia exclusion from the local closure check -- not a reproduced numeric residual.
- **Not yet shown to explain any specific known failure** (e.g. hour 2,894's `HourlyCellConservationFailure`, which issue-065's own addenda have already fully attributed to `erosion_chemistry_bridge.zig` for the dominant share and an unidentified smaller remainder). This is a structurally analogous, independently-reachable defect, not a claim about hour 2,894 specifically.
- **Not a fix.** Per this pass's explicit instruction, no source change was made.

## Recommended next steps (not performed this pass)

1. Add a synthetic unit reproduction in `litter_ammonia_phase_bridge.zig` (matching this defect class's own established test pattern, e.g. issue-065's tenth addendum "OLD"/"NEW" pair): construct a cell with `litter_water_m3` tiny-but-nonzero (e.g. `1e-9`), a nonzero `dry_reference_water_m3`, and a nonzero `ammonia_mol_per_m3`; show the current code discards most of the true extensive mass relative to the dry-reference basis, analogous to every already-fixed sibling's own regression test.
2. Reuse the exact fix pattern already established four times over (`water_carrier_rebase.zig`'s `sourceWaterM3`, the census's `aqueousCarrierM3`, `erosion_chemistry_bridge.zig`'s `erosionWaterCarrierM3`, and the in-progress `aqueous_transport_bridge.zig`'s `exportCarrierM3`): add a `litterAmmoniaCarrierM3(live_water_m3, dry_reference_water_m3, negligible_water_volume_m3)` helper (or reuse `landscape_mass_inventory_surface.zig`'s existing `negligibleLitterWaterVolumeM3(cell_area_m2)` floor, since this is the same litter-layer scope issue-061 Finding 2 already floored) and thread it into both `refreshTransientFromChemistry` and `publishTransientToChemistry`, widening the exact-zero guards on both sides to `<= negligible_water_volume_m3` and substituting `dry_reference_water_m3` in the pack multiply and the unpack divide.
3. Consider, separately from the carrier-floor fix, whether `litter_gas_transport_step.zig`'s exclusion of ammonia from its own closure check (lines 279-306) should be narrowed or given an ammonia-specific equivalent check, so a future regression in this bridge (or a currently-undiscovered one elsewhere in the same solve) is not silently unsupervised -- flagged as a related but distinct hardening opportunity, not part of this issue's core diagnosis.
4. Confirm with a bounded synthetic test (not a full production rerun) before considering this issue's fix complete, per the project's preference for the cheapest evidence that answers the question; a full-deck rerun is not required to validate a self-contained carrier-substitution fix in an isolated bridge module, matching how the tillage cluster (issue-064, TRC-326) was validated by regression test alone since no live trigger was scheduled in the Ottawa deck.

## Disposition

`legacy-defect-corrected` -- the fix specification below was applied as-is to `litter_ammonia_phase_bridge.zig` and `litter_gas_transport_step.zig`'s two call sites, with the two new regression tests and the one existing test's corrected assertions, per section 2-5 below. `litter_chemistry_carrier_rebase.zig` needed **no source change**: re-reading `effectiveAqueousCarrierM3` during application confirmed section 1's "Important correction" is a narrative correction to this issue's own Evidence section (clarifying that the sibling already substitutes `dry_reference_water_m3` at exact zero, which is *why* this file's `else 0`/`water == 0` branches were themselves the defect) -- not an instruction to change that function's code. Its own code already reads `return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;`, which is exactly the substitution behavior the correction describes; no diff was needed or made there.

Targeted `zig test` evidence (module root `src/module_index.zig`, `--test-filter` restricted to the affected test names, run 2026-09-20): all 5 tests in `litter_ammonia_phase_bridge.zig` pass, including the two new issue-066 OLD/NEW tests and the renamed/re-asserted dry-carrier test (packed mass 112 g N, round trip exact); all 3 tests in `litter_gas_transport_step.zig` pass with the new `cell_area_m2` argument threaded through. `zig build -Doptimize=ReleaseFast` succeeds (3/3 steps, cached compile of the `ecosys_ng` executable). A broader (accidentally near-full) `--test-filter`-unrestricted run surfaced exactly one unrelated failure, in `canopy.symbiosis.plant_symbiotic_fixation.zig` ("production binds WTHR fire to root and canopy before one-shot inoculum publication", `MissingHourlyScienceCall`) -- a source-text-scan test outside this issue's scope, in a file this fix never touched; not attributed to this fix. Not a regression of, and does not reopen, any prior issue's fix. The concurrently-in-progress issue-065 files (`mineral_nitrogen_transport.zig`, `hourly_sediment.zig`, and siblings) were left untouched throughout, per this task's assignment.

## Fix specification (ready to apply)

Produced by a dedicated read-only scoping pass (2026-09-19/20), while a separate heavy build+run for issue-065 held the machine. No source file was touched, no build was run. This section is a complete, ready-to-apply specification; the fix agent should be able to apply the diffs below directly and run the two focused test files.

### 1. Root-cause template being reused

Identical shape to `erosion_chemistry_bridge.zig`'s `packMapped`/`unpackMapped` fix, commit `bb84420` (`git show bb84420 -- ecosys-ng/src/soil/profile/erosion_chemistry_bridge.zig`):

- Add `const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");` (this file lives in `src/surface/`, one level from `src/core/`, unlike erosion's `src/soil/profile/` two levels -- hence `../core/...` not `../../core/...`).
- Add a `cell_area_m2: []const f64` parameter to both public functions (and to `validateDimensions`), used only to derive the per-cell `ZEROS2` floor via `legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2)`.
- Add a private helper `litterAmmoniaCarrierM3(live_water_m3, dry_reference_water_m3, negligible_water_volume_m3) !f64`, structurally identical to `erosionWaterCarrierM3`: `return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;` after validating all three inputs are finite and non-negative.
- Widen **both** guards (pack's `water > 0` and unpack's `water == 0`) to the floored form, and substitute the carrier everywhere the raw `water` was previously multiplied/divided.

**Important correction to this issue's own Evidence section, found while drafting this fix**: the Evidence section above frames the exact-zero branch as "the safe, legacy-analogous 'layer does not exist' branch, matching the already-reviewed-and-excluded `litter_chemistry_carrier_rebase.zig` design." Re-reading `litter_chemistry_carrier_rebase.zig`'s own `effectiveAqueousCarrierM3` (`return if (live_water_m3 > 0) live_water_m3 else dry_reference_water_m3;`) during this pass shows that sibling does **not** leave the value untouched at exact zero -- it substitutes `dry_reference_water_m3` there too, every time. `litter_chemistry_types.zig`'s own doc comment on `dry_reference_water_m3` confirms why: "the remembered dry reference... so the extensive amount survives" -- i.e. a dry cell's stored `ammonia_mol_per_m3` is *already expressed against* `dry_reference_water_m3`, not against raw (zero) water. So `refreshTransientFromChemistry`'s current exact-zero pack branch (`else 0`) is itself part of the same defect, not a correctly-scoped exclusion; this issue's own "Recommended next steps" item 2 already said to widen "the exact-zero guards... to `<= negligible_water_volume_m3`" -- this fix follows that item 2 instruction literally, superseding the more cautious framing in the Evidence section above. The fix agent should not be confused by the apparent conflict between the two: item 2's concrete instruction is correct and is what this section implements.

### 2. Exact before/after: `litter_ammonia_phase_bridge.zig`

**Import** (top of file, after existing imports):

```zig
// BEFORE
const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const gas = @import("../soil/gas/transport.zig");

// AFTER
const std = @import("std");
const chemistry = @import("litter_chemistry.zig");
const gas = @import("../soil/gas/transport.zig");
const legacy_water_negligible_floor = @import("../core/legacy_water_negligible_floor.zig");
```

**`refreshTransientFromChemistry`** (lines 13-39):

```zig
// BEFORE
pub fn refreshTransientFromChemistry(
    chemistry_state: *const chemistry.State,
    gas_state: *gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, nitrogen_molar_mass_g_per_mol);
    for (chemistry_state.cells, litter_water_m3) |cell, water| {
        if (!std.math.isFinite(cell.ammonia_mol_per_m3) or cell.ammonia_mol_per_m3 < 0)
            return error.InvalidLitterAmmoniaInventory;
        const mass = if (water > 0)
            cell.ammonia_mol_per_m3 * water * nitrogen_molar_mass_g_per_mol
        else
            0;
        if (!std.math.isFinite(mass) or mass < 0)
            return error.InvalidLitterAmmoniaInventory;
    }
    for (chemistry_state.cells, litter_water_m3, 0..) |cell, water, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        gas_state.dissolved_mass_g[index] = if (water > 0)
            cell.ammonia_mol_per_m3 * water * nitrogen_molar_mass_g_per_mol
        else
            0;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}

// AFTER
pub fn refreshTransientFromChemistry(
    chemistry_state: *const chemistry.State,
    gas_state: *gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, cell_area_m2, nitrogen_molar_mass_g_per_mol);
    for (chemistry_state.cells, litter_water_m3, chemistry_state.dry_reference_water_m3, cell_area_m2) |cell, water, dry_reference_water, area_m2| {
        if (!std.math.isFinite(cell.ammonia_mol_per_m3) or cell.ammonia_mol_per_m3 < 0)
            return error.InvalidLitterAmmoniaInventory;
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, dry_reference_water, negligible_water_volume_m3);
        const mass = cell.ammonia_mol_per_m3 * water_carrier * nitrogen_molar_mass_g_per_mol;
        if (!std.math.isFinite(mass) or mass < 0)
            return error.InvalidLitterAmmoniaInventory;
    }
    for (chemistry_state.cells, litter_water_m3, cell_area_m2, 0..) |cell, water, area_m2, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        gas_state.dissolved_mass_g[index] = cell.ammonia_mol_per_m3 * water_carrier * nitrogen_molar_mass_g_per_mol;
        gas_state.macropore_dissolved_mass_g[index] = 0;
        gas_state.band_dissolved_mass_g[index] = 0;
    }
}
```

**`publishTransientToChemistry`** (lines 41-75):

```zig
// BEFORE
pub fn publishTransientToChemistry(
    chemistry_state: *chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    absolute_tolerance_g_n: f64,
    relative_tolerance: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, nitrogen_molar_mass_g_per_mol);
    if (!std.math.isFinite(absolute_tolerance_g_n) or absolute_tolerance_g_n < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
        return error.InvalidLitterAmmoniaBridgeTolerance;
    for (litter_water_m3, 0..) |water, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const dissolved = gas_state.dissolved_mass_g[index];
        if (!std.math.isFinite(dissolved) or dissolved < 0)
            return error.InvalidTransientLitterAmmoniaInventory;
        if (!std.math.isFinite(gas_state.macropore_dissolved_mass_g[index]) or
            gas_state.macropore_dissolved_mass_g[index] != 0 or
            !std.math.isFinite(gas_state.band_dissolved_mass_g[index]) or
            gas_state.band_dissolved_mass_g[index] != 0)
            return error.NoncanonicalTransientLitterAmmonia;
        if (water == 0) {
            const scale = @max(1.0, dissolved);
            if (dissolved > absolute_tolerance_g_n + relative_tolerance * scale)
                return error.LitterAmmoniaWithoutWaterCarrier;
        }
    }
    for (litter_water_m3, 0..) |water, cell_index| {
        if (water == 0) continue;
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        chemistry_state.cells[cell_index].ammonia_mol_per_m3 =
            gas_state.dissolved_mass_g[index] / nitrogen_molar_mass_g_per_mol / water;
    }
}

// AFTER
pub fn publishTransientToChemistry(
    chemistry_state: *chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
    absolute_tolerance_g_n: f64,
    relative_tolerance: f64,
) !void {
    try validateDimensions(chemistry_state, gas_state, litter_water_m3, cell_area_m2, nitrogen_molar_mass_g_per_mol);
    if (!std.math.isFinite(absolute_tolerance_g_n) or absolute_tolerance_g_n < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance < 0)
        return error.InvalidLitterAmmoniaBridgeTolerance;
    for (litter_water_m3, cell_area_m2, 0..) |water, area_m2, cell_index| {
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        const dissolved = gas_state.dissolved_mass_g[index];
        if (!std.math.isFinite(dissolved) or dissolved < 0)
            return error.InvalidTransientLitterAmmoniaInventory;
        if (!std.math.isFinite(gas_state.macropore_dissolved_mass_g[index]) or
            gas_state.macropore_dissolved_mass_g[index] != 0 or
            !std.math.isFinite(gas_state.band_dissolved_mass_g[index]) or
            gas_state.band_dissolved_mass_g[index] != 0)
            return error.NoncanonicalTransientLitterAmmonia;
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        if (water_carrier == 0) {
            const scale = @max(1.0, dissolved);
            if (dissolved > absolute_tolerance_g_n + relative_tolerance * scale)
                return error.LitterAmmoniaWithoutWaterCarrier;
        }
    }
    for (litter_water_m3, cell_area_m2, 0..) |water, area_m2, cell_index| {
        const negligible_water_volume_m3 = legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(area_m2);
        const water_carrier = try litterAmmoniaCarrierM3(water, chemistry_state.dry_reference_water_m3[cell_index], negligible_water_volume_m3);
        if (water_carrier == 0) continue;
        const index = cell_index * gas.species_count + @intFromEnum(gas.Species.ammonia);
        chemistry_state.cells[cell_index].ammonia_mol_per_m3 =
            gas_state.dissolved_mass_g[index] / nitrogen_molar_mass_g_per_mol / water_carrier;
    }
}
```

**`validateDimensions`** (lines 88-107):

```zig
// BEFORE
fn validateDimensions(
    chemistry_state: *const chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    if (chemistry_state.cells.len == 0 or
        chemistry_state.dry_reference_water_m3.len != chemistry_state.cells.len or
        gas_state.cell_count != chemistry_state.cells.len or
        litter_water_m3.len != chemistry_state.cells.len)
        return error.LitterAmmoniaPhaseBridgeDimensionMismatch;
    try gas_state.validateShape();
    for (litter_water_m3, chemistry_state.dry_reference_water_m3) |water, dry_reference| {
        if (!std.math.isFinite(water) or water < 0 or
            !std.math.isFinite(dry_reference) or dry_reference < 0)
            return error.InvalidLitterAmmoniaWaterCarrier;
    }
}

// AFTER
fn validateDimensions(
    chemistry_state: *const chemistry.State,
    gas_state: *const gas.State,
    litter_water_m3: []const f64,
    cell_area_m2: []const f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
        return error.InvalidNitrogenMolarMass;
    if (chemistry_state.cells.len == 0 or
        chemistry_state.dry_reference_water_m3.len != chemistry_state.cells.len or
        gas_state.cell_count != chemistry_state.cells.len or
        litter_water_m3.len != chemistry_state.cells.len or
        cell_area_m2.len != chemistry_state.cells.len)
        return error.LitterAmmoniaPhaseBridgeDimensionMismatch;
    try gas_state.validateShape();
    for (litter_water_m3, chemistry_state.dry_reference_water_m3, cell_area_m2) |water, dry_reference, area_m2| {
        if (!std.math.isFinite(water) or water < 0 or
            !std.math.isFinite(dry_reference) or dry_reference < 0 or
            !std.math.isFinite(area_m2) or area_m2 < 0)
            return error.InvalidLitterAmmoniaWaterCarrier;
    }
}
```

**New helper** (add near `validateDimensions`, e.g. immediately after it):

```zig
/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`). issue-066:
/// shares the same floor `landscape_mass_inventory_surface.zig`'s private
/// `negligibleLitterWaterVolumeM3` already applies for this exact litter
/// scope, and `erosion_chemistry_bridge.zig`'s now-fixed
/// `erosionWaterCarrierM3` already applies for the structurally identical
/// pack/unpack shape (issue-065), so this file's
/// `refreshTransientFromChemistry`/`publishTransientToChemistry` round trip
/// agrees with both on the same water-carrier basis for the same degenerate
/// cell. Mirrors `erosionWaterCarrierM3`'s own error-set-local duplication
/// rather than importing it: this file is a distinct production mutator.
fn litterAmmoniaCarrierM3(
    live_water_m3: f64,
    dry_reference_water_m3: f64,
    negligible_water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(live_water_m3) or live_water_m3 < 0 or
        !std.math.isFinite(dry_reference_water_m3) or dry_reference_water_m3 < 0 or
        !std.math.isFinite(negligible_water_volume_m3) or negligible_water_volume_m3 < 0)
        return error.InvalidLitterAmmoniaWaterCarrier;
    return if (live_water_m3 > negligible_water_volume_m3) live_water_m3 else dry_reference_water_m3;
}
```

### 3. Call-site inventory (everything that must change)

Found by grepping the whole `ecosys-ng` tree for `refreshTransientFromChemistry` and `publishTransientToChemistry`: only two files reference either name.

**Production (must be updated, one file, two call sites)** -- `ecosys-ng/src/surface/litter_gas_transport_step.zig`, both inside `State.advanceWithFailureReport` (which `State.advance` merely forwards to). `cell_area_m2` is **already** a parameter of `advanceWithFailureReport` (used at its own line 192 for `thickness`), so no new parameter needs threading into `litter_gas_transport_step.zig`'s own public API -- only the two internal bridge calls change:

```zig
// BEFORE (pack call, line 178)
try ammonia_bridge.refreshTransientFromChemistry(
    ammonia_owner.chemistry,
    gas_state,
    litter_water_m3,
    ammonia_owner.nitrogen_molar_mass_g_per_mol,
);

// AFTER
try ammonia_bridge.refreshTransientFromChemistry(
    ammonia_owner.chemistry,
    gas_state,
    litter_water_m3,
    cell_area_m2,
    ammonia_owner.nitrogen_molar_mass_g_per_mol,
);
```

```zig
// BEFORE (unpack call, line 308)
try ammonia_bridge.publishTransientToChemistry(
    ammonia_owner.chemistry,
    gas_state,
    litter_water_m3,
    ammonia_owner.nitrogen_molar_mass_g_per_mol,
    ammonia_owner.absolute_tolerance_g_n,
    ammonia_owner.relative_tolerance,
);

// AFTER
try ammonia_bridge.publishTransientToChemistry(
    ammonia_owner.chemistry,
    gas_state,
    litter_water_m3,
    cell_area_m2,
    ammonia_owner.nitrogen_molar_mass_g_per_mol,
    ammonia_owner.absolute_tolerance_g_n,
    ammonia_owner.relative_tolerance,
);
```

**Tests only (must be updated, same file as the fix, 3 existing tests)** -- `litter_ammonia_phase_bridge.zig`'s own three tests call both functions directly and must gain a `cell_area_m2` argument (any positive value works; `&.{1, 1}` / `&.{1}` matches this fix's own new tests below and keeps `ZEROS2` floors at the documented `1.0e-6` m3):

- `"litter chemistry ammonia is sole aqueous owner and transient round trip is exact"` (lines 109-124): both calls get `&.{ 1, 1 },` inserted before `14.01`/before the tolerance pair respectively. No assertion changes needed (`water = {3, 4}` is far above any floor).
- `"invalid later transient leaves all litter chemistry owners unchanged"` (lines 140-152): both calls get `&.{ 1, 1 },` inserted. No assertion changes needed (`water = {1, 1}` is far above any floor).
- `"dry retained ammonia remains chemistry owned and never enters gas mirror"` (lines 126-138): **assertions must change**, not just the argument list -- see item 4 below. This test currently encodes the pre-fix behavior it is named for.

**No other production or test call sites exist anywhere in the repository for either function.**

### 4. Existing test that must change semantics, not just signature

`"dry retained ammonia remains chemistry owned and never enters gas mirror"` (lines 126-138) sets `chemistry_state.cells[0].ammonia_mol_per_m3 = 4`, `chemistry_state.dry_reference_water_m3[0] = 2`, `water = {0}`, `molar_mass = 14`. Pre-fix, `water == 0` takes the "layer does not exist" branch: pack sets `dissolved_mass_g[ammonia] = 0` and publish leaves the concentration untouched at `4`.

Post-fix, `water = 0 <= negligible_water_volume_m3 (1.0e-6 for area 1 m2)`, so the carrier is `dry_reference_water_m3[0] = 2`, not `0`. This is the correct behavior per item 1's correction above: a dry cell's stored concentration is *already* expressed against `dry_reference_water_m3`, so packing it against raw (zero) water was always the bug, not a deliberate exclusion. The fixed round trip (with no solver-side mutation in this test) still recovers the original concentration exactly, because both pack and unpack now consistently use the same substituted carrier -- but the **intermediate** packed mass is no longer `0`.

```zig
// BEFORE
test "dry retained ammonia remains chemistry owned and never enters gas mirror" {
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.dry_reference_water_m3[0] = 2;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{0}, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectEqual(@as(f64, 0), gas_state.dissolved_mass_g[ammonia]);
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{0}, 14, 1e-12, 1e-9);
    try std.testing.expectEqual(@as(f64, 4), chemistry_state.cells[0].ammonia_mol_per_m3);
}

// AFTER
test "dry retained ammonia is packed onto the dry-reference carrier and round-trips exactly" {
    // issue-066: pre-fix, this test asserted the defect itself (packed mass
    // forced to exactly 0 at water==0, discarding the true extensive amount
    // the concentration represents against dry_reference_water_m3). Fixed
    // behavior: the dry cell's true extensive mass (concentration *
    // dry_reference_water_m3 * molar_mass = 4 * 2 * 14 = 112 g N) is now
    // correctly packed into the transient mirror, and with no solver-side
    // mutation between pack and unpack, the round trip recovers the exact
    // original concentration.
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 1);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.dry_reference_water_m3[0] = 2;
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &.{0}, &.{1}, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 112), gas_state.dissolved_mass_g[ammonia], 1e-12);
    try publishTransientToChemistry(&chemistry_state, &gas_state, &.{0}, &.{1}, 14, 1e-12, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-12);
}
```

### 5. New regression tests (OLD destroys mass / NEW preserves mass)

No live production trace exists for this bridge (issue-066 performed no rerun; `hour1.f:4494-4603` gives only the general `CNH3S = ZNH3S/VOLW`-shaped equation, not a numeric example). Representative values are used, reusing this file's own existing fixture magnitudes (`ammonia_mol_per_m3 = 4`, `dry_reference_water_m3 = 2`, `nitrogen_molar_mass_g_per_mol = 14`) for continuity, plus a near-zero-but-nonzero `1.0e-9` m3 water content (two orders of magnitude below the `1.0 m2`-cell `ZEROS2` floor of `1.0e-6` m3).

```zig
test "issue-066: OLD raw-carrier pack/unpack arithmetic would destroy litter aqueous ammonia mass at a near-zero-but-nonzero water content" {
    // Reproduces this issue's own diagnosis by direct arithmetic, matching
    // the pre-fix `refreshTransientFromChemistry`/`publishTransientToChemistry`
    // formulas exactly (`if (water > 0) concentration * water * molar_mass
    // else 0` / `dissolved / molar_mass / water`) -- those formulas are no
    // longer reachable through the public entry points after the fix above,
    // so this test documents historical behavior rather than calling into
    // the module.
    const dry_reference_water_m3: f64 = 2;
    const live_water_m3: f64 = 1.0e-9; // below the 1.0e-6 m3 ZEROS2 floor for a 1 m2 cell
    const nitrogen_molar_mass_g_per_mol: f64 = 14;
    const concentration_mol_per_m3: f64 = 4;
    const true_mass_g_n = concentration_mol_per_m3 * dry_reference_water_m3 * nitrogen_molar_mass_g_per_mol;
    try std.testing.expectApproxEqAbs(@as(f64, 112), true_mass_g_n, 1e-12);

    // Pack side: OLD `water > 0` is true even at 1e-9, so the raw live water
    // is used directly as the carrier, discarding nearly all the true
    // extensive mass with no ledger entry -- nothing physically removed the
    // water-borne ammonia; the litter is simply mid-evaporation.
    const packed_old_g_n = concentration_mol_per_m3 * live_water_m3 * nitrogen_molar_mass_g_per_mol;
    try std.testing.expect(packed_old_g_n / true_mass_g_n < 1.0e-6);

    // Unpack side: if the true mass (112 g N) were ever present in the
    // mirror at this water content (e.g. carried over from wet-hour
    // chemistry the solver did not touch because dissolved-phase exchange
    // was zero that hour), OLD's unpack divides by the same raw near-zero
    // water, manufacturing a physically impossible concentration nine
    // orders of magnitude above the correct value -- the "fake mass swing"
    // this defect class produces once real chemistry, not just an inert
    // round trip, is on either side of the divide.
    const unpacked_old_concentration_mol_per_m3 = true_mass_g_n / nitrogen_molar_mass_g_per_mol / live_water_m3;
    try std.testing.expect(unpacked_old_concentration_mol_per_m3 > 1.0e9);
}

test "issue-066: NEW refreshTransientFromChemistry/publishTransientToChemistry round trip preserves litter aqueous ammonia mass through a genuine solver-side mutation at a near-zero-but-nonzero water content" {
    // Two cells: cell 0 is mid-evaporation (live water 1e-9 m3, below the
    // ZEROS2 floor, dry_reference_water_m3 = 2 m3 remembered from before it
    // went dry); cell 1 is ordinarily wet (4 m3, unaffected by the fix,
    // included to prove per-cell independence). A real solver-style
    // transfer of 14 g N from cell 0 to cell 1 (matching this file's own
    // pre-existing "round trip is exact" test's own transfer magnitude) is
    // applied between pack and unpack, proving this is not merely an inert
    // closed loop.
    var chemistry_state = try chemistry.State.init(std.testing.allocator, 2);
    defer chemistry_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    chemistry_state.cells[0].ammonia_mol_per_m3 = 4;
    chemistry_state.cells[1].ammonia_mol_per_m3 = 5;
    chemistry_state.dry_reference_water_m3[0] = 2;
    const litter_water_m3 = [_]f64{ 1.0e-9, 4 };
    const cell_area_m2 = [_]f64{ 1, 1 };
    try refreshTransientFromChemistry(&chemistry_state, &gas_state, &litter_water_m3, &cell_area_m2, 14);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    try std.testing.expectApproxEqAbs(@as(f64, 112), gas_state.dissolved_mass_g[ammonia], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 280), gas_state.dissolved_mass_g[gas.species_count + ammonia], 1e-9);

    // A real transfer: 14 g N moves from cell 0's aqueous ammonia to
    // cell 1's, exactly as if the coupled gas/water solver had equilibrated
    // some of cell 0's now-correctly-available inventory toward cell 1's
    // phase (the bridge itself does not move mass between cells; this
    // simulates what a real intervening solve does to the shared mirror).
    gas_state.dissolved_mass_g[ammonia] -= 14;
    gas_state.dissolved_mass_g[gas.species_count + ammonia] += 14;

    try publishTransientToChemistry(&chemistry_state, &gas_state, &litter_water_m3, &cell_area_m2, 14, 1e-12, 1e-9);
    // Cell 0: (112 - 14) g N / 14 / dry_reference_water_m3(2) = 3.5 mol/m3 --
    // NOT (112 - 14) / 14 / live_water_m3(1e-9), which would be ~7.0e9.
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), chemistry_state.cells[0].ammonia_mol_per_m3, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.25), chemistry_state.cells[1].ammonia_mol_per_m3, 1e-9);
}
```

### 6. Reachability/severity re-check (performed this pass, static reading only)

Re-verified by reading the actual call chain, not assuming it from the original evidence session:

1. `litter_gas_transport_step.zig`'s `State.advanceWithFailureReport` calls `ammonia_bridge.refreshTransientFromChemistry` at line 178 unconditionally at the top of the function (before even its own dimension-mismatch check at line 185), and calls `ammonia_bridge.publishTransientToChemistry` at line 308 unconditionally after the solver and the per-species closure check, with no `if` gating either call on litter presence, ammonia presence, or wetness. Confirmed by direct reading, not inferred.
2. The sole production caller of `State.advanceWithFailureReport` for this state is `ecosys-ng/src/stages/hourly_sediment.zig:1159`, inside `if (phase == .surface_gas) { ... }` (function `routeSedimentAndErosion`/`routeBiogeochemistryAndSolutes`, `ProductionPhase` enum `{ nitro, solute, surface_gas, erosion_redist }`). The call at line 1159 has no additional conditional wrapping it beyond the phase check itself -- confirmed by reading lines 1152-1199 directly.
3. `routeSedimentAndErosion(context, .surface_gas, ...)` is itself called unconditionally, with no gating condition, from `ecosys-ng/src/stages/hourly_heat_water_solute.zig:13060` (grepped and read with context; the call sits at the same top-level indentation as the sibling `.nitro` call at line 12912 and `.solute` call at line 12970, all three unconditional statements in the same function body, not inside any `if`).
4. This confirms the issue's own reachability claim ("`State.advance` runs this pack/unpack pair unconditionally every hour the surface litter gas solver executes") rather than merely repeating it: the full call chain from the hourly driver down to both bridge functions was read end to end this pass and contains no gate narrower than "the hourly driver executed this hour," which it does every production hour. Severity is unchanged from the original diagnosis: this is not a rare degenerate case, it is the ordinary evaporation/rewetting cycle.
5. The severity claim that this bridge's own local conservation gate would not catch a manufactured discard is also re-confirmed: `litter_gas_transport_step.zig:279-306`'s per-species closure loop explicitly does `if (species == @intFromEnum(gas.Species.ammonia)) continue;`, unconditionally skipping ammonia every hour, for every cell. This was re-read directly, not assumed.

### 7. Suggested minimal validation (per this issue's own "recommended next steps" item 4 and the project contract's cheapest-evidence preference)

`zig build test` scoped to (or including) `litter_ammonia_phase_bridge.zig` and `litter_gas_transport_step.zig` is sufficient to validate this fix in isolation: both existing test files' full suites (4 tests in `litter_gas_transport_step.zig`, now 5 in `litter_ammonia_phase_bridge.zig` after item 4's rename and the two new tests in item 5) should pass. No full-deck rerun is required to accept this fix, matching how issue-064 (TRC-326) was validated by regression test alone. A full `ReleaseFast` rerun remains appropriate only once the machine is free and only to re-measure whatever residual the issue-065 campaign is independently chasing; this fix does not need one to be considered complete.
