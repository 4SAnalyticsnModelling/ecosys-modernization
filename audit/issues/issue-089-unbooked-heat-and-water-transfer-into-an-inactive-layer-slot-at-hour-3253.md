# Issue 089 -- unbooked heat and water transfer from the top layer into an INACTIVE layer slot at hour 3,253

Status: **OPEN, CONFIRMED by a production run, cause not yet localized to a writer (filed 2026-09-21, adversarial Claude/Pi session).** This is the real hour-3,253 blocker. It was masked until now by `issue-078`'s entry-capacity guard, whose domain contradicted the oracle and which aborted first; with that guard corrected (`run-015`), this is what the run fails on. Diagnosis budget 0 of 3 spent.

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
