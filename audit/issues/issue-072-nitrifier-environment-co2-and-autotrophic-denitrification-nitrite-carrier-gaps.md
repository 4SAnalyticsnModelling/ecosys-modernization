# Issue 072 -- two more siblings of the "ZEROS2/ZEROS mistranslated as exact-zero carrier guard" defect class, found by the same live-water-field consumer sweep as issue-071, but distinct from and not covered by issue-071's own three findings

Status: DIAGNOSIS ONLY, NOT FIXED. Read-only/no-build/no-run pass (a concurrent peer session had an active build/run in progress; this pass did not compete for CPU/build resources and modified no `ecosys-ng/src/` file). Both findings are diagnosed by direct reading of current source and cross-reference to the cited legacy Fortran lines only; neither has a synthetic regression test or a live production re-run yet.
Owner: unassigned
Discovered by: independent read-only sweep, this session, 2026-09-20, tasked with searching by consumer of the LIVE water fields (`matrix_liquid_water_m3`, `liquid_water_m3`, `macropore_liquid_water_m3`) across the whole `ecosys-ng/src/` tree -- the same brief given concurrently and independently to a different session, whose output is `issue-071-live-water-field-sweep-topsoil-microbial-exchange-fertilizer-band-carrier-gaps.md`.

## Numbering note (concurrent-agent collision, two rounds)

Both this session and the peer session that produced `issue-071-live-water-field-sweep-topsoil-microbial-exchange-fertilizer-band-carrier-gaps.md` were given essentially the same brief at the same time. Both independently used the number 070 first; when this session discovered the peer's own `issue-070-*.md` already on disk (via `git status --short`), this file was renumbered to 071 -- at almost the same moment the peer, seeing *this* session's now-abandoned `issue-070-nitrifier-denitrifier-zone-water-concentration-exact-zero-guard-cluster.md` (deleted once this file existed), renumbered its own file from 070 to 071 too, producing a second collision at 071. This file is renumbered to 072 to resolve that second collision (`Get-ChildItem audit/issues/issue-07*.md` re-checked immediately before this commit). The peer's own file still refers to this file by its earlier name/number ("issue-070") in a few places (its own "Numbering note" and Finding B caveat) -- that is a known, harmless byproduct of two independent sessions renumbering in the same window and is left uncorrected here rather than editing the peer's file.

It does not reopen or duplicate any of issue-071's three findings -- see the reconciliation below.

## Reconciliation against issue-071's own three findings (why this is not a duplicate)

Issue-071's Finding B lists four sibling files sharing this defect's shape (a concentration&harr;mass conversion keyed off the raw live water field, guarded by an exact-zero check or no guard at all, instead of the shared `negligible_water_volume_m3` floor) plus one narrowed line in `nitrification_step.zig`: `nitrification_step.zig` (line 94 only), `nitrogen_exchange_step.zig`, `phosphorus_exchange_step.zig`, `topsoil_mineral_exchange_step.zig`. This issue's two findings below are **not** among those, and are not the `chemodenitrification_step.zig`/`nitrification_step.zig`-line-93 sites either (those are covered by a third, now-superseded document this session no longer has a copy of but which the peer's issue-071 explicitly still credits and does not re-file). Finding B below specifically **corrects** a claim the peer's issue-071 (citing that same superseded document) makes only as an unelaborated caveat.

## Finding A (HIGHEST severity/reachability of any finding in this defect-class family so far -- no floor parameter exists at all in this file): `ecosys-ng/src/soil/microbial/nitrifier_environment_step.zig`

```zig
// applyTile, lines 85-88
const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
const co2_index = try gas.massIndex(layer, .carbon_dioxide, context.gas_state.cell_count);
const co2_concentration = if (water_m3 > 0) context.gas_state.dissolved_mass_g[co2_index] / water_m3 else 0;
const co2_activity = co2_concentration / (co2_concentration + environment.aqueous_co2_half_saturation_g_c_per_m3);
```

`ApplyContext` (lines 52-69) has **no** `negligible_water_volume_m3` field at all -- not merely an unfloored guard at one call site, but no floor material anywhere in this file to reuse. Legacy's exact analog is `hour1.f:3777-3787`: `IF(VOLW(L,NY,NX).GT.ZEROS(NY,NX))THEN CCO2S(L,NY,NX)=AMAX1(0.0,CO2S(L,NY,NX)/VOLW(L,NY,NX)) ... ELSE CCO2S(L,NY,NX)=0.0` (and again at `hour1.f:4605-4615` for the litter/layer-0 case) -- a cell-area-scaled `ZEROS` floor, not the bare `ZERO` constant used elsewhere for genuinely discrete (not tiny-but-nonzero) conditions. This Zig port uses `water_m3 > 0`, an exact-zero-only guard, mistranslating that floor.

**Downstream effect, confirmed non-canceling.** `co2_activity = C/(C+K)` is a genuine Michaelis-Menten-shaped saturation term. When `water_m3` is tiny-but-nonzero (an ordinary drying/freeze-drying soil layer, not exactly dry), `co2_concentration` spikes (division by a near-zero denominator) and `co2_activity` saturates toward its maximum of `1` -- exactly when legacy's floor-gated behavior would zero the concentration and suppress downstream activity. `co2_activity` feeds `context.environment.aqueous_co2_activity[unit]`, consumed by both `soil_nitrification_step.applyTile` (`nitrification_step.zig:46`) and `soil_autotrophic_denitrification_step.applyTile` (`autotrophic_denitrification_step.zig:55`, feeding `nitrite_demand_g_n` at `denitrification.zig:198`). Net effect: nitrifier and autotrophic-denitrifier growth/reaction potential are spuriously **boosted**, not suppressed, in drying soil -- backwards from the physically correct direction, and reaching two other production stages beyond this file's own.

**Reachability.** `nitrifier_environment_step.applyTile` is wired unconditionally into production at `stages/biogeochemistry_batches.zig:24-25`, run every hour for every active soil layer. Dissolved CO2 mass is essentially never exactly zero in a real soil layer, so this triggers whenever a layer's water content is small but not exactly zero -- an ordinary condition, not a rare edge case.

## Finding B (corrects a claim made only as an unelaborated caveat in the peer's issue-071): `ecosys-ng/src/soil/microbial/autotrophic_denitrification_step.zig`'s own `makeZone` still has the unfloored guard, two lines below where the file's own floor parameter is already threaded through

The peer's `issue-071` (Finding B, its own caveat paragraph) cites this file's `applyTile` (lines 38-39) as one of two siblings (alongside `heterotrophic_denitrification_step.zig`) that already have the correct floor-based skip:

```zig
const water_m3 = context.model_grid.matrix_liquid_water_m3[layer];
if (water_m3 <= context.negligible_water_volume_m3) continue;
```

and separately notes, citing a now-superseded document rather than its own independent derivation, that this file's `makeZone` helper has a residual gap. This issue derives that gap directly and in full.

That outer per-layer skip is correct as far as it goes -- but it only protects the *total* `water_m3` from collapsing near zero. It does not protect `makeZone` (called at lines 51-52, defined at lines 74-96), which computes its own nitrite concentration from a *further-scaled* water quantity with no floor at all:

```zig
// makeZone, lines 82, 90
const nitrite_volume = water_m3 * nitrite_fraction;
...
.nitrite_concentration_g_n_per_m3 = if (nitrite_volume > 0) nitrite_amount / nitrite_volume else 0,
```

`nitrite_fraction` (the non-band/band zone split) can be tiny while total `water_m3` stays comfortably above the floor, still driving `nitrite_volume` into the unguarded near-zero band. This value feeds `denitrification.zig:200`: `raw_capacity[index] = zone.nitrite_fraction * nitrite_demand_g_n * monod(zone.nitrite_concentration_g_n_per_m3, parameters.nitrite_half_saturation_g_n_per_m3)` -- confirmed non-canceling (Monod, not a linear rate law) -- which feeds `capacity` after a `product_factor` that is itself correctly floor-gated (`inputs.biologically_active_water_m3 > inputs.negligible_water_volume_m3`, `denitrification.zig:201`) but does not protect the `monod(...)` term computed one line earlier. Compare `heterotrophic_denitrification_step.zig`'s own `makeZone` (line 134), which gets the *identical*-shaped `zone_water`/`nitrite_amount` division right: `if (zone_water > context.negligible_water_volume_m3) nitrite_amount / zone_water else 0`. `autotrophic_denitrification_step.zig` already has `context.negligible_water_volume_m3` in scope inside `makeZone` (it is a field of `ApplyContext`, the function's own first parameter) -- the exact fix, and the exact field needed to apply it, are already present in the same function, two lines above the unfixed line.

**Reachability.** Wired into production at `stages/biogeochemistry_batches.zig:142,160`, run every hour for every active soil layer's ammonia-oxidizer unit.

## What this is not

- **Not a reopening of issue-060 through issue-071, and not a duplicate of any of issue-071's three findings.** `metabolism_state_update.zig` (issue-071 Finding A) and `soil_chemistry_convergence.zig`'s `updateFertilizerBandGeometry` (issue-071 Finding C) are untouched by this issue. Issue-071's Finding B's files (`nitrification_step.zig` line 94, `nitrogen_exchange_step.zig`, `phosphorus_exchange_step.zig`, `topsoil_mineral_exchange_step.zig`) are also untouched here. `nitrification_step.zig` line 93 and `chemodenitrification_step.zig`'s `zone()` helper were independently found by this session too, during the same sweep, but are left to whichever filing already covers them rather than re-filed here.
- **Not execution-confirmed.** Both findings are diagnosed by static reading, cross-reference to the cited legacy Fortran lines, and hand-traced downstream call chains, per this pass's read-only budget. No synthetic reproduction, unit test, or production run was added or executed this pass.
- **Not a claim of exact reachability magnitude** in the Ottawa deck's own hour range -- only that the mechanism is reachable under ordinary drought/freeze-drying conditions soil layers routinely experience.

## Recommended fix pattern (not applied here)

1. Add `negligible_water_volume_m3: f64` to `nitrifier_environment_step.zig`'s `ApplyContext`, threaded the same way `autotrophic_denitrification_step.zig`/`heterotrophic_denitrification_step.zig` already do, deriving it via the shared `legacyNegligibleWaterVolumeM3(cell_area_m2)` helper centralized in `core/legacy_water_negligible_floor.zig`.
2. Widen Finding A's `water_m3 > 0` (`nitrifier_environment_step.zig:87`) to `water_m3 > context.negligible_water_volume_m3`.
3. Widen Finding B's `nitrite_volume > 0` (`autotrophic_denitrification_step.zig:90`) to `nitrite_volume > context.negligible_water_volume_m3` -- no new context field required; `context.negligible_water_volume_m3` is already in scope in this exact function.
4. Add a synthetic OLD/NEW regression test per finding before considering either fixed, matching this defect class's own established test pattern (a near-zero-but-nonzero water/zone-volume case showing the old guard manufactures a spurious activity/capacity spike and the new guard suppresses it, matching legacy's explicit floor-triggered zero).
5. Fix this issue's two findings together with issue-071's own findings, since all are in the same file family and the same production stage batch (`biogeochemistry_batches.zig`); confirm via targeted `zig test --test-filter` only, not a full production ReleaseFast cycle, per this project's contract and the concurrent-run constraint both this issue and issue-071 were filed under.

## Disposition

`unresolved` for both findings. Independent of, and does not reopen or duplicate, any of issue-060 through issue-071.
