# Issue 066 -- `litter_ammonia_phase_bridge.zig`'s `refreshTransientFromChemistry`/`publishTransientToChemistry` round trip uses an exact-zero-only litter-water guard instead of the shared `ZEROS2`/`dry_reference_water_m3` carrier substitution -- a pack/unpack-shaped sibling the issue-061 keyword sweep could not have found

Status: `unresolved` -- diagnosis-only, per this pass's explicit no-fix mandate. Not yet execution-confirmed against a live production run. No source change made.
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

`unresolved` -- genuine, reachable, previously-undiscovered candidate identified and documented by static reading; no fix attempted, no live reproduction performed, per this pass's explicit diagnosis-only mandate. Not a regression of, and does not reopen, any prior issue's fix. The concurrently-in-progress `aqueous_transport_bridge.zig` fix (issue-065, uncommitted at the time of this pass) is unaffected and not claimed by this issue.
