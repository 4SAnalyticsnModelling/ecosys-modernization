# Issue 074 -- `aqueous_transport_bridge.zig`'s `importChemistry` and `synchronizeCellAfterCarrierChange` still use the raw live water carrier with only an exact-zero guard, distinct from this same file's already-fixed `exportChemistry`

Status: FIXED (both findings) and validated. See "Fix and validation (2026-09-20, later pass)" below for evidence. The diagnosis narrative below (originally filed read-only/no-build/no-run) is preserved unchanged as the record of how these two findings were discovered.
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

## Fix and validation (2026-09-20, later pass)

Implemented the recommended fix pattern above almost exactly, with one deliberate deviation noted below.

**`importChemistry`** (`aqueous_transport_bridge.zig:132-181`): added a required `negligible_water_volume_m3: f64` parameter. Both loops now compute `carrierM3(live_water_volume_m3, dry_reference_water_m3, negligible_water_volume_m3)` (the renamed, generalized former `exportCarrierM3`) instead of using `transport_state.water_volume_m3[cell]` raw; when live water is at or below the floor, `chemistry_state.dry_reference_water_m3[cell]` is substituted. The old `water_volume_m3 <= 0` exact-zero guard was removed (superseded by the substitution); a separate finite/non-negative validation on both the live and dry-reference values was kept. Sole call site (`hourly_heat_water_solute.zig:7385`) now passes `context.config.physical_tolerance.water_volume_m3`, matching `exportChemistry`'s own already-established call-site convention in the same file/driver (a scalar tolerance, not a per-cell-area-scaled floor), since both functions operate at the same driver layer with the same existing precedent.

**`synchronizeCellAfterCarrierChange`** (`aqueous_transport_bridge.zig:183-262`): added a required `negligible_water_volume_m3: f64` parameter. `new_water_volume_m3` is validated as finite and non-negative (no longer rejected merely for being small/zero), then substituted via `carrierM3` against `chemistry_state.dry_reference_water_m3[cell]` when at or below the floor. The *substituted* carrier (not the raw caller-supplied value) is used for both the changed-species and unchanged-species passes and is what gets written back to `transport_state.water_volume_m3[cell]`, exactly as recommended. All three call sites updated:
- `hourly_vegetation.zig:277-291`: threads `ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell])`. **Deviation from the recommendation**: its pre-existing `if (matrix_liquid_water_m3[layer] == 0) continue` skip guard was left unchanged rather than widened. This is intentional, not an oversight: `synchronizeCellAfterCarrierChange` itself now floors/substitutes any value in `(0, floor]` that reaches it, so the only case the unwidened skip still special-cases is exact zero (unaffected either way — the function now handles that too, but the caller's existing behavior for that one value is preserved rather than churned). Widening it further was out of this fix's scope (not one of the two named findings) and risked an unreviewed third behavior change on a call site neither finding's evidence covers.
- `hourly_heat_water_solute.zig:7401-7411`: same treatment, `legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[layer / context.grid.soil_layer_capacity])` (mapping the flattened layer index to its owning cell, matching this file's own existing pattern at line 4626).
- `pond_domain_transaction.zig:358-378` (the most severe site, Finding B): this is the new guard. The call now threads `legacy_water_negligible_floor.legacyNegligibleWaterVolumeM3(inputs.horizontal_cell_width_m[cell] * inputs.vertical_cell_width_m[cell])` (the same footprint expression this file's own `carrierVolumes` helper already uses two lines above). Since this call site never had any water guard of its own, all of its protection now comes from `synchronizeCellAfterCarrierChange`'s own floor substitution -- exactly the "matching how sibling functions in this same defect-class family handle it" instruction, using `pond_chemistry_transfer.zig`'s `calculate`/`pondSurfaceWaterCarrierM3` (issue-069 Finding A) as the directly analogous pond-domain sibling: substitute the dry reference, never skip, never error on a routine degenerate value.

**Regression tests** (all in `aqueous_transport_bridge.zig` unless noted): four new tests added -- an OLD-behavior arithmetic proof that a near-zero-but-positive carrier manufactures a >1e5x spuriously huge concentration in `importChemistry`'s old divisor; a NEW-behavior proof `importChemistry` preserves the correct concentration at exact-zero, near-zero, and above-floor water; an OLD-behavior proof (isolated guard reproduction, not a live panic) that the removed `<= 0` guard would have produced the exact error that reached `pond_domain_transaction.zig`'s `catch unreachable`; and a NEW-behavior proof `synchronizeCellAfterCarrierChange` substitutes the dry reference and republishes both changed- and unchanged-species correctly at exact-zero and near-zero water. A fifth test in `pond_domain_transaction.zig` itself proves the same OLD-panic-risk/NEW-stable behavior using this file's own `legacyNegligibleWaterVolumeM3(horizontal_cell_width_m * vertical_cell_width_m)` convention on both a changed species (`carbonate`, verified via its republished extensive amount) and an unchanged species (`calcium_carbonate`, verified via its diluted concentration). Every pre-existing test in `aqueous_transport_bridge.zig` and `pond_domain_transaction.zig` that called either fixed function was updated to the new signature (negligible-floor argument of `0`, which is a no-op substitution for every one of their non-degenerate water values, so no prior expected result changed).

**Verification.** Targeted filters only, via `zig test src/module_index.zig --test-filter "<name>"` (direct, not `zig build test`, per this task's explicit instruction to avoid the full suite): `aqueous_transport_bridge` (all pass, includes both new OLD/NEW pairs), `pond_domain_transaction` (all pass, includes the new Finding B test), `issue-074` (all pass, six tests tagged). `zig build` and `zig build -Doptimize=ReleaseFast` both exit 0 -- both needed several retries during this pass because a concurrent peer session was actively mid-edit across several unrelated microbial files (`nitrogen_exchange_step.zig`, `phosphorus_exchange_step.zig`, `chemodenitrification_step.zig`, `biogeochemistry_batches.zig`, confirmed by `git status --short` showing those files modified though never touched by this pass, and by the compiler error's exact reference moving between distinct files/lines across consecutive retries); both commands passed cleanly once that peer's edit stabilized. A separate, unrelated pre-existing compile break was found and NOT fixed by this pass (a stale `pond_inventory_transfer.zig` test literal missing `CarrierVolumes.cell_area_m2`, reproduced even at git HEAD `ce0564e` before any of this pass's edits, via `git stash`/retest) -- it only affects the full, untargeted `zig test src/module_index.zig` (no filter) and `zig build test`, which this task's instructions say not to run anyway; left unfixed as out of this issue's scope and flagged here for whoever owns it.

**Live production validation** (machine was free: `Get-Process ecosys_ng` returned nothing before starting). Built `zig build -Doptimize=ReleaseFast` to an isolated scratchpad prefix (SHA-256 `A730B89EF2BF552BAD1399F85F9E9FB5DB2B66EBBD02E3C794B5FA836494A760`, 12,258,816 bytes). Fresh scratch copy of the Ottawa deck truncated to the single 1998 scene exactly per `issue-069`'s own documented methodology (`grid_inputs`'s scenario-group line kept `1  1`; its scene-count line changed `6,5` -> `1,1`; scenes 2-6's data lines removed; the `0  0` terminator kept immediately after scene 1's block). Ran single-threaded (`--threads 1`), fresh from hour 1, no checkpoint resume. Wall time **19 min 12 s** (23:04:29 -> 23:23:41), within the ~25-minute budget.

Result: **exactly the expected frontier, no regression found.** `plant_emergence_refresh`, `canopy_carboxylation`, `canopy_energy_balance`, `nonsymbiotic_nitrogen_fixation`, and `census_positive_control` all show `entries=2894 first_hour=1 last_hour=2894`; hour 2895 then fails with the already-tracked `issue-068` frontier (`SoilPhaseSolverStagnated`), not a new failure. The full stderr log is **3,906 lines total -- byte-for-byte identical to issue-069's own confirmed pre-this-fix baseline line count.** `implausible surface conductive flux` occurs **934 times**, the retry ladder shows **92 rejected + 86 accepted = 178 total events**, and `HourlyCellConservationFailure` occurs **0 times** -- all three numbers match the established baseline exactly. No `AqueousTransport*` error of any kind appears anywhere in the log (0 occurrences). The pond-domain-collapse path this fix directly touches fired repeatedly and without incident throughout the run, including at the final committed hour: `DRY_CARRIER_TRACE site=stage_boundary stage=after_pond_domain_transfer hour=2894 cell=0 layer=0 live_water_m3=0e0 dry_reference_water_m3=6.058232575064708e-3 ...` -- this is the exact degenerate state (`live_water_m3` exactly zero) that `pond_domain_transaction.zig`'s previously-unguarded call site now passes through `synchronizeCellAfterCarrierChange`'s new substitution with no error and no panic, in real production data, not just a synthetic test.

Traceability: `TRC-341` (`importChemistry`, Finding A) and `TRC-342` (`synchronizeCellAfterCarrierChange`, Finding B) -- both pre-existing rows from this issue's own diagnosis -- updated in place from `disposition=unresolved` to `disposition=legacy-defect-corrected`, with refreshed `zig_lines`/`zig_sha256`/`tests`/`evidence`/`author` fields (no new rows added, since these two rows already described the exact same audited units). Checked for duplicate `unit_id`s before and after (`Import-Csv | Group-Object unit_id | Where-Object Count -gt 1`, empty both times; 351 rows total after, up from 342 before this pass -- the +9 came from a concurrent peer session's own additions, re-confirmed empty after this pass's own edits).

## Disposition

`legacy-defect-corrected` for both findings, fixed and live-production-validated this pass. Independent of, and does not reopen or duplicate, any of issue-060 through issue-073. Not yet independently reviewed by a separate reviewer/session.
