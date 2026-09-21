# Issue 069 -- two more genuine siblings of the issue-060/061/063/064/065/066 "ZEROS2 mistranslated as exact-zero carrier guard" defect class, missed by every prior sweep

Status: OPEN / NOT_ASSESSED. Found by independent read-only review of issues 060-067 (see `issue-060-067-independent-review-2026-09-20.md`), while extending that review's cross-consumer check beyond the eight issues' own files to every file in `ecosys-ng/src` referencing `dry_reference_water_m3`. No source change made. Not execution-confirmed by a live run or a synthetic unit reproduction -- diagnosis only, per this project's own established discipline ("do not fix blind").
Owner: unassigned
Discovered by: independent-review pass, this session, 2026-09-20, while verifying issue-060 through issue-067's fixes hold up and checking for gaps between their sweeps.

## Why this is a new, distinct issue and not a reopening of any of issue-060 through issue-067

Every one of issue-060/061/063/064/065/066's own fixes is independently confirmed correct in `issue-060-067-independent-review-2026-09-20.md`. This issue does not dispute any of those fixes. It reports two call sites with the *same defect shape* (a legacy `VOLW.GT.ZEROS2`-style floor, `starts.f:270`, mistranslated as an exact-zero-only guard on a water/liquid carrier feeding a concentration<->mass conversion) that none of those issues' sweeps reached, because each sweep searched by keyword/naming-convention/file-location heuristics that these two sites did not match:
- issue-061's sweep searched for `*Carrier*`/`*WaterVolumes*`/`rebase`/`transfer`/`remap`/`relayer` naming patterns.
- issue-064's sweep searched `soil/`, `redistribution/`, `surface/`, `plant/` for similar naming patterns plus explicit "rebase"/"transfer"/"remap"/"relayer" functions.
- issue-066's sweep specifically targeted pack/unpack-shaped bidirectional round trips (a different shape than either finding below).

Neither finding below is a pack/unpack round trip, and neither function name matches any of the keywords above (`calculate`, `acceptedSurfaceTransfer`, `gatherTillageSurfaceAmounts`), which is exactly why they were not found until this review searched every consumer of `dry_reference_water_m3` directly rather than by keyword.

## Finding A (HIGH PRIORITY -- production-state-mutating, same severity class as issue-061 Finding 1): `ecosys-ng/src/surface/pond_chemistry_transfer.zig`'s `calculate` -- three exact-zero-only guards on the surface pond water carrier

`calculate` (the shared implementation behind both `transferSurfaceFractionToSoil` -- the production mutator -- and `acceptedSurfaceTransfer` -- the conservation-ledger reader) contains, at lines 482-499:

```zig
const surface_aqueous_before_m3 = if (carriers.surface_water_before_m3 > 0)
    carriers.surface_water_before_m3
else
    dry_reference_before;
const surface_dry_reference_after_m3 = if (carriers.surface_water_after_m3 > 0)
    0
else if (carriers.surface_water_before_m3 == 0)
    dry_reference_before
else
    carriers.surface_water_before_m3 * (1 - carriers.dissolved_chemistry_fraction);
const surface_aqueous_after_m3 = if (carriers.surface_water_after_m3 > 0)
    carriers.surface_water_after_m3
else
    surface_dry_reference_after_m3;
const surface_mineral_reference_after_m3 = if (carriers.surface_water_after_m3 > 0)
    carriers.surface_water_after_m3
else
    mineral_reference_before;
```

Every one of these four expressions gates on `carriers.surface_water_*_m3 > 0` (exact zero only), never on the shared `ZEROS2`-equivalent floor (`legacyNegligibleWaterVolumeM3`) that issue-060/061/063/064/066 already established and centralized in `core/legacy_water_negligible_floor.zig`. This is the identical shape to `water_carrier_rebase.zig`'s pre-fix `sourceWaterM3` (issue-061 Finding 1, flagged there as "the PRODUCTION soil-chemistry state's own water-carrier rescale" and prioritized highest because it mutates live model state, not merely a validation ledger).

**Reachability and consequence.** `transferSurfaceFractionToSoil` (`pond_chemistry_transfer.zig`) is called unconditionally, with `catch unreachable`, from `pond_domain_transaction.zig:329`, itself called from `hourly_sediment.zig` as part of the REDIST pond-domain-collapse handling -- a real, unconditional production commit path, not a rare or gated diagnostic. Surface/litter pond water routinely approaches near-zero during ordinary evaporation (issue-061's own Finding 2/3 already established this reachability argument for the sibling litter-carrier consumers it fixed; this is the same physical water reservoir). When `carriers.surface_water_before_m3` or `carriers.surface_water_after_m3` is tiny-but-nonzero (below the `ZEROS2`-equivalent floor) rather than exactly zero:
- `surface_aqueous_before_m3`/`surface_aqueous_after_m3` are used directly as the multiplier for the surface's aqueous nitrogen/phosphorus/carbon/aluminum/iron/calcium/magnesium/sodium/potassium (and, when `dynamic_salts`, sulfur/chloride) concentrations, both in the production mutator (`calculate`'s own `result.surface`/committed state, via `transferSurfaceFractionToSoil`) and in the conservation ledger (`acceptedSurfaceTransfer`'s `aqueous_scale = carriers.dissolved_chemistry_fraction * aqueous_reference`, read separately in `acceptedSurfaceTransfer` at lines 279-283 with its own identical exact-zero guard).
- A near-zero-but-nonzero raw carrier here produces the same failure mode issue-060's own diagnosis first characterized: a real concentration multiplied by an almost-zero carrier manufactures a near-total fake mass loss relative to what the same concentration represents against the correct (`dry_reference_water_m3`-substituted) basis -- and because `transferSurfaceFractionToSoil` is a `catch unreachable` production call, this would silently corrupt live surface/soil chemistry state, not merely trip a validation gate that then correctly rejects the hour (the more severe of the two failure modes this defect class has produced elsewhere, matching issue-061 Finding 1's own severity ranking).

**Not yet execution-confirmed.** No rerun or synthetic unit reproduction was performed this pass (read-only review budget). The claim rests on static reading of `calculate`'s actual arithmetic and the confirmed unconditional production call chain, exactly as issue-061's own Finding 1 was filed (diagnosis-only) before a later pass fixed it.

**Recommended fix pattern (not applied here):** reuse the established pattern exactly. Add a `cell_area_m2` (or equivalent) parameter to `CarrierVolumes`/`calculate`/`acceptedSurfaceTransfer`, derive `legacyNegligibleWaterVolumeM3(cell_area_m2)`, and widen all four `carriers.surface_water_*_m3 > 0` guards to `> negligible_water_volume_m3`. Note the existing comment at lines 453-456 ("A dry surface carrier (`surface_water_before_m3 == 0`) is legitimate... Substituting the zero live-water carrier here would silently erase retained dry solute") is a correct rationale for substituting *at* zero -- it is not a reason to leave the guard at exact-zero-only; issue-066's own "Important correction" addendum already worked through this exact reasoning for a sibling file and concluded the same widening applies. `acceptedParticulateTransfer`/`transferParticulateFractionToSoil` (the neighboring "particulate settling" functions in the same file) were read and do not use a water carrier at all (dry-mass and mineral-reference scaled only) -- confirmed not a second instance in this file.

## Finding B (same tillage-cluster scope as issue-064's own deferred 5th cluster; still unreachable in the current Ottawa deck): `ecosys-ng/src/surface/aqueous_runoff_transport.zig`'s `gatherTillageSurfaceAmounts` -- the read-side counterpart of a fix issue-064 only applied to the write side

issue-064's "Deferred 5th cluster fixed" pass fixed five exact-zero guards inside `redistribution/tillage/runtime_adapter.zig` itself, including the caller-supplied carrier at the `SurfaceAqueousTillage.commitTillageSurfaceAmounts` call site (`runtime_adapter.zig:1092-1098`, now correctly `tillageWaterCarrierM3(physical_gas.surface_water_m3, physical_gas.surface_dry_reference_water_m3, commit_negligible_water_volume_m3)`). That function (`commitTillageSurfaceAmounts`, defined in `aqueous_runoff_transport.zig:89-130`) is confirmed correctly guarded by the caller now.

**Its sibling, `gatherTillageSurfaceAmounts` (same file, lines 50-83), was not.** It still contains its own internal exact-zero-only guard:

```zig
pub fn gatherTillageSurfaceAmounts(
    chemistry: *const Chemistry,
    extensive: *const surface_routing.State,
    cell: usize,
    actual_water_m3: f64,
) !TillageSurfaceAmounts {
    try validateTillageOwners(chemistry, extensive, cell, actual_water_m3);
    const represented_carrier_m3 = if (actual_water_m3 > 0)
        actual_water_m3
    else
        chemistry.dry_reference_water_m3[cell];
    ...
```

and its sole production call site, `runtime_adapter.zig:2602-2607` (inside `gatherSurfaceTransfers`, the tillage predicted-vs-actual "before" gather), passes the **raw, unfloored** `context.surface_water_m3[cell]` directly:

```zig
const dynamic_amounts = try SurfaceAqueousTillage.gatherTillageSurfaceAmounts(
    context.surface_chemistry,
    context.surface_solute_transport,
    cell,
    context.surface_water_m3[cell],
);
```

Note that the *same function* (`gatherSurfaceTransfers`) correctly floors the carrier for its own "core" nitrogen/phosphate family two lines earlier, via `surfaceAqueousCarrier(context, cell)` (line 2586, which does call `tillageWaterCarrierM3` with the proper floor) -- i.e. the fix pattern is present and correct *right next to* the unfixed call, which is exactly the kind of near-miss a keyword sweep across files can produce when the fix is applied at one call site of a shared helper but not at a second call site of a *different* function in a *different file* that happens to take the same raw input.

**Reachability.** Per issue-064's own finding (re-confirmed, not re-derived, by this review): "Checked the Ottawa deck's actual management input files: no tillage operation is scheduled in this deck/run." This finding, like issue-064's own deferred 5th cluster, is therefore **not reachable in the current validated Ottawa deck** -- a real, latent defect for any future deck that schedules a tillage operation, not a blocker for this candidate's current evidence.

**Recommended fix (not applied here):** mirror issue-064's own fix for `commitTillageSurfaceAmounts`: either (a) widen `gatherTillageSurfaceAmounts`'s own internal guard to accept a `negligible_water_volume_m3` parameter (matching `commitTillageSurfaceAmounts`'s sibling shape more closely would require a slightly larger signature change since `gatherTillageSurfaceAmounts` currently derives its own carrier internally rather than accepting one), or (b) have `runtime_adapter.zig`'s call site pass the already-computed `tillageWaterCarrierM3(...)` result instead of the raw `context.surface_water_m3[cell]` -- but note option (b) alone is insufficient without also reading `gatherTillageSurfaceAmounts`'s own internal `represented_carrier_m3 == 0` checks (lines 69, which uses `== 0` for an "unbound inventory" validation that would need re-examination against a floored input rather than an exact-zero one).

## What this is not

- **Not a regression of issue-064.** The five sites issue-064's deferred-cluster pass actually enumerated and fixed in `runtime_adapter.zig` remain correctly fixed (re-confirmed by this review). This finding is a sixth, distinct call site the enumeration did not include because it lives in a different file.
- **Not execution-confirmed for either finding.** Both are diagnosed by static reading and call-chain tracing only, per this review's read-only budget. Finding A's reachability argument is stronger (unconditional production call, ordinary evaporation trigger) than Finding B's (tillage, confirmed unreachable in the current deck).
- **Not a claim that hour 2,894/2,895 or any other currently-tracked failure is caused by either finding.** No connection to any specific known failure hour is asserted.

## Recommended next steps (not performed this pass)

1. Prioritize Finding A: it is a production-state-mutating path reachable under ordinary evaporation, the same severity class as issue-061's highest-priority finding.
2. Reuse the exact fix pattern and shared `legacyNegligibleWaterVolumeM3` floor already centralized in `core/legacy_water_negligible_floor.zig`, per every prior fix in this defect-class family, rather than re-deriving a new floor source.
3. Add a synthetic unit reproduction for each finding before considering either fixed (matching this defect class's own established OLD/NEW test pattern), and confirm via targeted `zig test --test-filter` rather than a full production rerun, consistent with how issue-064's own deferred tillage cluster was validated (regression test only, since the trigger is unreachable in the current deck).
4. Given Finding B is in the same currently-unreachable tillage path as issue-064's own deferred cluster, it does not block this candidate's release evidence; Finding A should be assessed for whether it is reachable within the already-completed Ottawa production run's own hour range (i.e. whether any surface pond-to-soil transfer actually occurred at a degenerate near-zero carrier during that run) before deciding whether it invalidates any existing conservation evidence for that run.

## Disposition

`unresolved` for both findings -- diagnosis only, no fix applied, per this project's discipline against fixing blind. Independent of, and does not reopen, any of issue-060 through issue-067.
