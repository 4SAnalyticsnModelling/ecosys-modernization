# Issue 089 -- unbooked heat and water transfer from the top soil layer into the SURFACE (litter) scope at hour 3,253

Status: **FIXED AND VALIDATED IN PRODUCTION (2026-09-21).** Hour 3,253 is cleared, the frontier advanced to hour **3,276**, and the run reports **zero** conservation failures. Full suite 4375 passed / 1 skipped / 0 failed (zero regressions); `ReleaseFast` exit 0, binary `C653A546...BB1B`. Record: `audit/runs/run-018-issue-089-ledger-fix-validation-2026-09-21.md`. The fix was bookkeeping only -- two `accumulateLitterSoilLocalTransfer` calls declaring the cascade's surface leg -- and the reviewer independently confirmed the sign, noting a reversal would have doubled the gap rather than cancelling it. The new blocker at hour 3,276 is `MissingFertilizerRecipientWaterVolume`, unrelated to this issue.

Prior status: **OPEN -- ROOT CAUSE FOUND AND FULLY LOCALIZED. It is a LEDGER-WIRING defect, not a physics defect: `litter_soil_water_flux_m3` is published by the displacement cascade and has ZERO consumers, so a conservative soil-layer-0 -> surface transfer is never declared to the layer-local ledger. Fix is bookkeeping only. See "ROOT CAUSE" below.** Scope 17 is the SURFACE scope, not an inactive soil layer -- this issue's original framing is corrected below. (Filed 2026-09-21, adversarial Claude/Pi session; corrected the same session by an instrumented rerun.)

## ROOT CAUSE (experiment 2, instrumented rerun `run-017`) -- the physics is right, the BOOKKEEPING is missing

**This is a ledger-wiring defect, not a physics defect.** Binary SHA-256 `40D7C96A4FE140E4DCA82A8C1D566B3EF9737152BB4A41909ADC4F5AD8D88BB2`, surface-scope owners traced at all five stage boundaries. The full chain, measured:

**Step 1 -- hour 3,252, tillage legitimately empties the litter.** Across `applyDeferredTillageSoil`:

```
before_apply_deferred_tillage_soil  litter_water_m3=4.414122164330099e-3  surface_heat_capacity=1.8497050528607305e-2
after_apply_deferred_tillage_soil   litter_water_m3=4.414122164330099e-6  surface_heat_capacity=1.8497050320534597e-5
```

**Identical mantissa, exponent shifted by exactly three** -- a pure factor of 1000, with `surface_temperature_k` unchanged. That is `redistribution/tillage/surface_biomass_transfer.zig:77`:

```zig
const remaining_fraction = if (surface_heat_capacity_megajoules_k > residue_heat_capacity_threshold_megajoules_k)
    @max(0.001, soil_mixing_remaining_fraction) else 1.0;
```

With a deep tillage event `XCORP` is ~0 (`day.f:348`: `CORP=AMIN1(1.0,AMAX1(0.05,ITILL/10.0))`, `XCORP=1.0-CORP`, so `ITILL=10` gives exactly 0), the `0.001` floor binds, and 99.9% of the surface residue is incorporated into the soil. **This is intended, legacy-faithful behaviour and is not the defect.** It does, however, leave the litter nearly empty and the top soil layer overfilled.

**Step 2 -- hour 3,253, the displacement cascade correctly refills the litter.** Between `start_of_prepare_accepted_hour_storage_before_refresh` and `before_geometry_disturbance_finalize`, i.e. during hourly science:

```
litter_water_m3      4.414122164330099e-6  ->  3.1508646318483594e-3
surface_temperature_k  3.1029112752241826e2 -> 2.9914919488515073e2
```

Those are **exactly** the `before` and `after` storage values the conservation failure reports for scope 17. The mover is the accepted upward-displacement cascade at `stages/hourly_heat_water_solute.zig:4539-4570`, which terminates in the surface litter via `routePhaseDisplacementIntoSurfaceRecipient` and is the genuine `FLQR` analogue for the displacement path. **This too is correct physics** -- relieving an overfilled column into the litter is exactly what `watsub.f:3683-3685` does.

**Step 3 -- the transfer is never booked.** The cascade publishes its result: `self.litter_soil_water_flux_m3[cell] = -(carry.matrix_liquid_water_m3 + carry.macropore_liquid_water_m3)` (`:4568`), carried through the transport replay at `:2542` and `:2793-2799`. But **`litter_soil_water_flux_m3` has no consumer**: a search across `ecosys_ng.zig` and `validation/layer_local_conservation.zig` finds **zero** references. Nothing accumulates it into `hourly_layer_boundary_ledger`.

So the layer-local audit sees soil layer 0 lose `4.2752681740391765` MJ and the surface scope gain `+4.2752681740404` MJ -- equal and opposite to ~11 figures, because the transfer really is conservative -- with **no boundary activity declared on either side**, and correctly aborts.

### The fix, and why it is small

**Accumulate the already-published `litter_soil_water_flux_m3` (and its paired enthalpy) as a layer-local boundary activity between soil layer 0 and the `.surface` scope.** No physics changes, no tolerance changes, no solver changes. The quantity is already computed, already conservative, and already stored -- it simply is not declared to the ledger.

Pattern to follow: `accumulateTillageActivity` (`ecosys_ng.zig:4027`, `layer_local_conservation.accumulateTillageActivity`) is exactly this shape for the tillage transfer, which *is* booked -- which is why step 1 passes its own hour's audit and step 2 does not.

Required with the fix: the enthalpy leg must be booked too, not only water (the heat residual is the larger of the two failures), and a regression test should stage an overfilled top layer with a near-empty litter, run the cascade, and assert the ledger balances on both scopes.

**Do not** "fix" this by widening a tolerance or by suppressing the surface scope from the audit. The audit is right and is the only thing that caught this.

## CORRECTION (experiment 1, instrumented rerun) -- scope 17 is the SURFACE, and that changes everything

This issue was first filed on the assumption that `cell=17` in the conservation report was an **inactive soil layer** (the deck runs `layer_count=12`). **That assumption is refuted.** The instrumented rerun (`run-016`, binary SHA-256 `1470ACA642959B47A8752E9350B6AB52A503167368933C4255438C494B93BEC4`) widened `stages/diagnostics.zig`'s existing hour-3,248-3,254 probe to raw grid index 17 and it **never printed**, because the probe's own `index >= context.grid.layer_count` guard skipped it. `grid.layer_count` is 12. Index 17 does not exist in the grid's layer arrays at all, so it cannot be a soil layer, active or inactive.

The conservation report indexes a **different** array: the layer-local ledger's own scope enumeration, whose length is `hourly_cell_conservation.zig:2305`'s `storage_before.len` = `layer_local_conservation.zig:217-220`'s

```
scopeCount() = soilCount() + snowCount() + cell_count * 2
```

and whose ordering is fixed by `layer_local_conservation.zig:222-240`:

```zig
.soil_layer => cell * soil_layer_capacity + layer,
.snow_layer => soil_count + cell * snow_layer_capacity + layer,
.surface    => soil_count + snow_count + cell,
.canopy     => soil_count + snow_count + cell_count + cell,
```

With `cell_count=1` and `soil_layer_capacity=12` (confirmed: `grid.layer_count=12`, and the probe skipped 17), scope 17 is the **`.surface`** scope and scope 18 is `.canopy`. That requires `snow_layer_capacity=5`, which is the legacy `JS=5` snow extent; it is fixed by the arithmetic rather than read directly from the config, and is the only value that places `.surface` at 17.

**So the corrected finding is: heat and water move from soil layer 0 into the SURFACE (litter) scope, and neither side books the transfer.**

### Why the correction makes this far more important

That is precisely the **`FLQR` leg** -- `watsub.f:3670-3685`, the top-soil-layer-to-litter flux which in the oracle also carries the donor-bounded mechanical excess-relief term:

```fortran
IF(VOLP1ZN.LT.0.0)THEN
FLQR=FLQR+AMIN1(0.0,AMAX1(-VOLW1N*XNPZX,VOLP1ZN))
ENDIF
```

`issue-083` independently established, from the solver side and before this run existed, that **ecosys-ng has no `FLQR` counterpart anywhere in `src`** -- it has `FLQRQ`/`FLQRI` (rain and irrigation to litter) but not `FLQR`. Two independent routes have now arrived at the same missing leg:

1. `issue-083`, by reading the oracle's three relief legs and finding the third unported.
2. This issue, by measuring an unbooked soil-layer-0-to-surface transfer in a production run.

And it closes a chain that previously had a gap:

- the top soil layer is chronically overfilled (`issue-024`; quantified by `run-014` as `WTR_1` bias **+0.2585 m3 m-3**, candidate systematically wetter);
- at the day-136 tillage hour the displacement finally occurs, soil layer 0 -> surface;
- ecosys-ng has no `FLQR`-analogue ledger leg for that face, so the transfer is unbooked;
- the hour-3,253 conservation audit catches it.

**This makes `issue-083`'s litter terminus the single highest-value fix for the production frontier, now backed by direct run evidence rather than inference.** It also revises `issue-083`'s own guidance: that issue concluded the terminus should be ported *together with* the donor-only relief change. This run suggests the terminus is needed **on its own merits**, independently of the relief change, because the transfer across that face is already happening and merely goes unrecorded.

### What is still not established

- **Which code performs the soil-0-to-surface move.** The probe fired 108 times across the four existing stage boundaries but only for grid indices 0, 1 and 2, so it did not observe the surface scope. The next rerun must trace the **surface** owners (`surface_precipitation.litter_water_m3`, `surface_litter_ice_m3`, `surface_heat_capacity_megajoules_per_k`, `grid.surface_temperature_k`) alongside soil layer 0, at the same four boundaries plus the tillage bracket added this round.
- Whether the mover is the tillage adapter, the geometry/relayering transaction, or the accepted-displacement cascade at `stages/hourly_heat_water_solute.zig:4539-4570` -- which *does* terminate in the surface litter and *is* the `FLQR` analogue for the phase-displacement path, and which `issue-083` noted fires only for phase-change displacement. If it is that cascade firing on a tillage-induced displacement, the transfer may simply be missing its ledger entry rather than being illegitimate.

The last possibility is the most likely and the cheapest to check first, and it would make the fix a **ledger** fix rather than a new physical mechanism.

## Original framing, retained for provenance (scope 17 misread as an inactive soil layer) This is the real hour-3,253 blocker. It was masked until now by `issue-078`'s entry-capacity guard, whose domain contradicted the oracle and which aborted first; with that guard corrected (`run-015`), this is what the run fails on. Diagnosis budget 0 of 3 spent.

## The finding

Fresh-from-hour-1 `ReleaseFast` run, Ottawa production deck, binary SHA-256 `7944903E4B8E9A0FAF843880C11475092F1E4E8E18B10B24F5BDC6194D7E8377`. Accepted hour 3,252; failed at hour 3,253 with `HourlyLayerConservationFailure` (`validation/layer_local_conservation.zig:4345`).

Exactly **four** conservation failures, on exactly **two** layer slots:

| slot | quantity | before | after | residual |
|---|---|---|---|---|
| 0 | water | 5.690384395061972e-3 | (reported) | (reported) |
| 0 | heat | 7.27782706332724e0 | 4.161966836177862e0 | **-4.2752681740391765e0** |
| 17 | water | 4.414122164330099e-6 | 3.1508646318483594e-3 | +3.0732378540248265e-3 |
| 17 | heat | 5.739470599797588e-3 | 3.949405471206189e0 | **+4.2752681740404e0** |

## Three facts that localize it

1. **The heat residuals are equal and opposite to ~11 significant figures** (`-4.2752681740391765` against `+4.2752681740404`). This is not drift, tolerance, or accumulation. It is a **transfer between two layer slots that no ledger booked** -- the exact defect class this audit exists to detect. Whatever moved it conserved it globally and simply failed to declare it.

2. **Slot 17 is not an active layer.** The run's own `STARTE chemistry beginning: cell_count=1 layer_count=12` line fixes the profile at twelve active soil layers. Slot 17 enters the hour effectively empty (`water=4.414e-6`, `heat=5.739e-3`) and leaves it holding real material (`water=3.151e-3`, `heat=3.949`). Material is being written into a slot the model does not consider part of the profile.

3. **The second tillage event fires at exactly hour 3,252**, the hour immediately before. The stage census shows `tillage_soil_application entries=2 first_hour=2532 last_hour=3252` -- day 106 and day 136. `issue-078`'s dynamic diagnosis independently recorded tillage at 3,252. Slot 0 is the chronically overfilled top layer (`water before=5.690e-3`, consistent with the elevated top-layer water `issue-024` has tracked throughout), and slot 17 gains `~3.07e-3` of water, a substantial fraction of it.

So the working picture is: the day-136 tillage event displaces material out of the overfilled top layer into an inactive layer slot without booking the transfer, and the next hour's conservation audit catches it.

## What is NOT yet established

**Which code writes slot 17.** The candidates, in the order their call sites reach this point:

- `redistribution/tillage/runtime_adapter.zig`'s `apply` (which `issue-078` already established writes `matrix_liquid_water_m3` directly, post-science, and is per-layer-capacity-unaware);
- the end-of-hour geometry/relayering transaction (`soil/profile/relayering.zig`'s `applyEndOfHourGeometry` -> `heat_layer_remap.transferLayerFractions`), which `issue-078`'s dynamic diagnosis instrumented and found moving only ~1e-10 m3 in an ordinary hour -- but a tillage hour is not ordinary;
- `soil/profile/runtime_material_refresh.zig` itself, though this is unlikely: `run-015` changed only its guard predicate and the guard now passes, so the refresh is reaching code that previously never ran for this state.

**Do not assume tillage from the correlation alone.** The hour-3,252 coincidence is strong but the geometry transaction also runs at the end of that hour, and `issue-012`/`GEOM-SUBSIDENCE-001` documents a *separate* known defect in the relayering/SOC boundary legs. Two plausible writers with a known defect each is exactly the situation where a guess costs an experiment.

## Recommended first experiment

A **bounded instrumented rerun**, gated to hours `[3250, 3254]`, cell 0, slots 0 and 17 only, logging `matrix_liquid_water_m3` and the heat carrier immediately before and after each of: `applyDeferredTillageSoil`, `applyEndOfHourGeometry`/`transferLayerFractions`, and `refreshAcceptedHour`. The before/after difference at each boundary names the writer in one run. This is the same narrowly-gated pattern `issue-078`'s dynamic diagnosis and `stages/diagnostics.zig:305`'s `traceIssue078SoilPoreOverfill` already use, and that trace can very likely be widened to slot 17 rather than written fresh.

Do **not** spend an experiment on a source-reading search for "who writes layer 17" before this. The equal-and-opposite pair means the writer books nothing, so there is no ledger entry to grep for, and three candidate call sites all legitimately touch layer arrays.

## Why this matters more than its hour

`issue-085` established that this deck's editor selects output columns for layers beyond the twelve-layer runtime profile, and that ecosys-ng emits nothing for them. If material can be *written* into those inactive slots, then:

- it is invisible in output (no column is emitted for slot 17), so it would never have been caught by the output comparison in `run-014`;
- it is real mass and energy leaving the modelled profile without a boundary entry, which bears directly on the conservation and "no science gap" criteria, not merely on this one hour;
- the conservation audit is the *only* thing that sees it. That the audit caught it precisely, with an 11-figure equal-and-opposite pair, is a strong argument for the audit's design and for `redist.f`'s own commented-out mass-balance check having been a real gap in the legacy (see `feature-009`'s finding that the legacy whole-ecosystem balance check is 100% dead code).

## Relationship to other records

- `issue-078` -- the entry-capacity guard that masked this. Its domain correction is what exposed this; see `run-015`.
- `issue-083` -- the relief-term half, still reverted. Unrelated to this defect.
- `issue-012` / `GEOM-SUBSIDENCE-001` -- a separate, already-documented defect in the relayering SOC/erosion boundary legs. One of this issue's candidate writers. Do not conflate them.
- `issue-080` -- legacy applies tillage mixing `24*NFH` times on a tillage day and ecosys-ng once. Same event, different question, and it may interact: a single large dose is a larger per-call displacement than 96 small ones.
