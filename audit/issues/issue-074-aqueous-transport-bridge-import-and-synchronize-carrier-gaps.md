# Issue 074 -- `aqueous_transport_bridge.zig`'s `importChemistry` and `synchronizeCellAfterCarrierChange` still use the raw live water carrier with only an exact-zero guard, distinct from this same file's already-fixed `exportChemistry`

Status: DIAGNOSED, NOT FIXED. Read-only/no-build/no-run pass (another agent had an active build/run in progress; this pass did not compete for CPU/build resources and modified no file under `ecosys-ng/src/`). Both findings are confirmed by direct reading of current source and call-chain tracing only; neither has a synthetic regression test or a live production re-run yet.
Owner: unassigned
Discovered by: consumer-based sweep of the LIVE water fields `matrix_liquid_water_m3`/`liquid_water_m3`/`macropore_liquid_water_m3` (`ecosys-ng/src/state/grid.zig`) across the whole `ecosys-ng/src/` tree, this session, 2026-09-20 -- one level beyond issue-069's own `dry_reference_water_m3`-consumer sweep, per this task's explicit brief. Independently cross-checked against `issue-072`/`issue-073` (two concurrent peer sessions' filings from the identical brief, both read in full) to confirm no overlap: neither peer file, nor any of issue-060 through issue-069, mentions `aqueous_transport_bridge.zig`'s `importChemistry` or `synchronizeCellAfterCarrierChange` by name.

## Why this is not a duplicate of issue-065's already-fixed `exportChemistry` in the same file

`ecosys-ng/src/soil/solute/aqueous_transport_bridge.zig` has four public functions built around the same "water carrier" concept: `exportChemistry` (concentration -> extensive amount, chemistry to transport), `importChemistry` (extensive amount -> concentration, transport to chemistry), `synchronizeCellAfterCarrierChange` (reconciles both directions after a carrier change), and `exportConcentrations` (concentration-only, no carrier, not affected). Issue-065 (twelfth addendum plus the independent review's own confirmation) found and fixed `exportChemistry`'s raw-carrier defect by adding a private `exportCarrierM3(live_water_m3, dry_reference_water_m3, negligible_water_volume_m3)` helper (current lines 58-60) that substitutes `chemistry_state.dry_reference_water_m3[cell]` whenever the live carrier is at or below the shared `ZEROS2`-equivalent floor. The file's own doc comment on `exportCarrierM3` (lines 54-57) explicitly asserts: *"`importChemistry`/`synchronizeCellAfterCarrierChange` in this same file both already require strictly positive water and error otherwise; only this direction lacked an equivalent safeguard or substitution."* That assertion is the root of this issue: "requires strictly positive" (`<= 0` -> error) is not the same guarantee as "requires above the `ZEROS2` floor." A tiny-but-nonzero carrier passes both functions' guards unchanged and is used raw, reproducing the exact defect shape `exportChemistry` was fixed for, in the same file, right next to the fix.

## Finding A: `importChemistry` (lines 126-150) -- mass-to-concentration carrier, no floor

```zig
pub fn importChemistry(transport_state: *const transport.State, chemistry_state: *chemistry.State, fractions_source: anytype) !void {
    ...
    for (0..chemistry_state.cell_count) |cell| {
        ...
        const water_volume_m3 = transport_state.water_volume_m3[cell];
        if (!std.math.isFinite(water_volume_m3) or water_volume_m3 <= 0) return error.AqueousTransportRequiresPositiveWaterVolume;
        for (0..Species.count) |species_index| {
            ...
            _ = try concentrationFromAmount(amount_mol, water_volume_m3, species, fractions);
        }
    }
    for (0..chemistry_state.cell_count) |cell| {
        ...
        const water_volume_m3 = transport_state.water_volume_m3[cell];
        for (0..Species.count) |species_index| {
            ...
            setConcentration(..., concentrationFromAmount(amount_mol, water_volume_m3, species, fractions) catch unreachable);
        }
    }
}
```

`water_volume_m3 <= 0` only rejects exact zero (and negatives); any near-zero-but-positive carrier (below the `ZEROS2`-equivalent floor) proceeds unchanged and is used directly as the divisor inside `concentrationFromAmount` (mass -> concentration). A near-zero divisor manufactures a spuriously huge concentration for a preserved extensive mass -- the mirror-image failure mode of `exportChemistry`'s pre-fix defect (which manufactured a spuriously *small* mass from a correct concentration); this direction instead corrupts the concentration written back into `chemistry_state`, which is the same state every other fixed carrier in this defect-class family (issue-060/061/063/064/065/066/069) reads from.

**Reachability.** `importChemistry`'s sole call site is `stages/hourly_heat_water_solute.zig:7385`, inside the main micropore aqueous-transport substep loop (`try ecosys.soil_aqueous_transport_bridge.importChemistry(context.micropore_solute_state, context.soil_chemistry, context.fertilizer_band)`), called unconditionally every accepted transport substep, every hour -- not gated by tillage, fertilizer banding, or any deck-specific configuration. `transport_state.water_volume_m3[cell]` is synchronized from `context.grid.matrix_liquid_water_m3` by the neighboring `synchronizeCellAfterCarrierChange` calls in the same function (see Finding B), so it tracks the same live per-layer water this whole defect-class family already treats as routinely near-zero during ordinary soil drying.

## Finding B: `synchronizeCellAfterCarrierChange` (lines 156-203) -- both directions, no floor, and the most severe call site has no guard at all

```zig
pub fn synchronizeCellAfterCarrierChange(chemistry_state: *chemistry.State, transport_state: *transport.State, cell: usize, new_water_volume_m3: f64, changed_species: []const Species, fractions_source: anytype) !void {
    ...
    if (!std.math.isFinite(new_water_volume_m3) or new_water_volume_m3 <= 0)
        return error.AqueousTransportRequiresPositiveWaterVolume;
    ...
    for (changed_species) |species| {
        ...
        const amount_mol = value * new_water_volume_m3 * species_module.zoneFraction(species, fractions);   // concentration -> mass, unfloored
        ...
    }
    for (0..Species.count) |species_index| {
        ...
        if (!containsSpecies(changed_species, species))
            _ = try concentrationFromAmount(amounts[species_index], new_water_volume_m3, species, fractions);   // mass -> concentration, unfloored
    }
    ... // same two operations repeated on the actual publish pass, lines 188-201
    transport_state.water_volume_m3[cell] = new_water_volume_m3;   // unfloored value becomes the new baseline carrier
}
```

Same `<= 0` exact-zero-only guard as Finding A, on both the concentration->mass (`changed_species`) and mass->concentration (unchanged species) directions, and the raw, unfloored `new_water_volume_m3` is what gets written back as `transport_state.water_volume_m3[cell]` -- propagating the un-substituted carrier forward into every subsequent call (including into Finding A's `importChemistry`).

Three confirmed production call sites, none of which floor the water volume before passing it in:
- `stages/hourly_vegetation.zig:277-291`: `if (context.grid.matrix_liquid_water_m3[layer] == 0) continue;` then passes `context.grid.matrix_liquid_water_m3[layer]` raw. Exact-zero-only skip, same shape as this defect class's other "widen `== 0` to the floor" fixes.
- `stages/hourly_heat_water_solute.zig:7401-7411`: identical `== 0` guard and raw pass-through, inside the same substep loop as Finding A's `importChemistry` call, for the four bare-phosphate species' irrigation-increment publish.
- `surface/pond_domain_transaction.zig:358-375`: **no water-volume guard of any kind** -- only `if (!inputs.transitions.active[cell]) continue;` gates the loop, then `grid.matrix_liquid_water_m3[destination]` is passed straight through. This call is the most severe of the three: it is the pond-domain-collapse chemistry/carrier reconciliation step, the same production-mutating severity class as issue-069 Finding A (`pond_chemistry_transfer.zig`, also in the REDIST pond-collapse path) and issue-061 Finding 1.

**Reachability.** All three call sites are unconditional production paths (no tillage/fertilizer-band/deck-specific gating on any of them), matching the reachability argument already established for every other finding in this defect-class family: near-zero-but-nonzero soil/pond water is an ordinary, frequent condition (evaporation, drainage, pond-domain collapse), not a rare edge case.

## What this is not

- **Not a regression of issue-065's `exportChemistry` fix.** `exportChemistry`/`exportCarrierM3` (lines 58-105) were re-read in full and confirmed unchanged and correct; this issue's two findings are the other two carrier-consuming functions in the same file, which issue-065's own fix explicitly (and, per this finding, incorrectly) assumed were already safe.
- **Not a duplicate of issue-072 or issue-073** (the two concurrent peer sessions' filings from the identical live-water-field-consumer brief). Both were read in full; neither mentions `aqueous_transport_bridge.zig`, `importChemistry`, or `synchronizeCellAfterCarrierChange`.
- **Not execution-confirmed.** Both findings are diagnosed by static reading and call-chain tracing only, per this pass's read-only budget. No synthetic reproduction, unit test, or production run was added or executed this pass.
- **Not a claim that any specific currently-tracked failure hour is caused by either finding.** No connection to any specific known failure hour is asserted.

## Recommended fix pattern (not applied here)

1. Reuse `exportCarrierM3`'s exact shape (rename/generalize it, e.g. to a shared `carrierM3(live_water_m3, dry_reference_water_m3, negligible_water_volume_m3)` used by all three directions in this file, since the substitution logic is identical regardless of which way mass and concentration are being converted).
2. `importChemistry`: derive `negligible_water_volume_m3` the same way `exportChemistry` already does (a new parameter, following that function's own precedent of adding one when it was fixed), and substitute `chemistry_state.dry_reference_water_m3[cell]` for `transport_state.water_volume_m3[cell]` whenever the latter is at or below the floor, in both loops.
3. `synchronizeCellAfterCarrierChange`: add the same `negligible_water_volume_m3` parameter; widen the `<= 0` guard to `<= negligible_water_volume_m3` is not sufficient alone -- the function must still *substitute* a usable carrier (matching every other fix in this family) rather than error out, since callers like `pond_domain_transaction.zig` run unconditionally and cannot treat a routine near-zero carrier as an exceptional error. Store the *substituted* carrier into `transport_state.water_volume_m3[cell]` at the end (mirroring `water_carrier_rebase.zig`'s own rebase pattern), not the raw caller-supplied value, so the corrected baseline propagates to `importChemistry`'s next call.
4. Update the three call sites (`hourly_vegetation.zig`, `hourly_heat_water_solute.zig`, `pond_domain_transaction.zig`) to thread the appropriate `negligible_water_volume_m3`/`legacyNegligibleWaterVolumeM3(cell_area_m2)` value and to widen their own `== 0` guards (or add one, for `pond_domain_transaction.zig`) to match, consistent with how issue-069 Finding A widened `pond_chemistry_transfer.zig`'s own guards in the same call chain.
5. Add OLD/NEW regression tests per this defect class's established pattern (see issue-060/061/066/069) before considering either finding fixed, and confirm via targeted `zig test --test-filter`, not a full production rerun.
6. Coordinate with whoever fixes issue-072/issue-073's own microbial-exchange-family findings, since `synchronizeCellAfterCarrierChange`'s callers (`hourly_vegetation.zig`, `hourly_heat_water_solute.zig`) sit in the same hourly pass as several of those files.

## Disposition

`unresolved` for both findings. Independent of, and does not reopen or duplicate, any of issue-060 through issue-073.
