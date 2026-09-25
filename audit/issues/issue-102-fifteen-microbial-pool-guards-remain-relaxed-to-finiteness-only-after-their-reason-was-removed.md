# Issue 102 -- fifteen microbial-pool guards remain relaxed to finiteness-only after the defect that motivated them was fixed another way

Status: **OPEN (filed 2026-09-23; distribution claim CORRECTED 2026-09-23 by task `20260923-205755-0455a53b`).** The 62 clamp events are NOT confined to the failing hour. They span at least 17 invocations of the hourly biogeochemistry stage, and only 6 fall in the failing attempt (hour 3,276). See `audit/analysis/issue-102-clamp-events-span-many-hours-not-the-failing-hour-2026-09-23.md`. The magnitudes and the clamp-over-strict conclusion stand. Identified by reading the reference `docs/discrepancy_register.md`, which records this cleanup as explicitly **not done**. The six named modules all still exist in this tree (verified). **Nothing here has been confirmed against the current source** -- this is a worklist item with a precise citation, not a measurement.

## Why this is a criterion-2 item, not housekeeping

The register's own conclusion is a science statement, not a guard-tuning note:

> "Thirteen links with no visible end is itself the finding: **the Zig design assumes non-negative microbial pools throughout, while the oracle does not.**"

Fifteen validity guards were relaxed from domain checks to **finiteness-only** in order to chase a negative microbial carbon value through the call chain. The defect was then fixed a different way -- by clamping at the write and booking the deviation to CO2 -- which made the relaxations unnecessary. **They were never reverted.** So the tree currently carries a permanently widened accepted state space for the whole organic/microbial subsystem, retained for a reason that no longer exists.

The register is unambiguous that this is wrong to leave:

> "The fifteen relaxations are now **unnecessary** for this defect -- the negative no longer reaches them. They remain in the tree and should be restored to strict."

> "They should be **reverted together** when (B) lands, not left alongside it -- keeping both would preserve the widened state space for no reason."

## The enumerated list, quoted from the register

Thirteen individually cited (of fifteen total; the remaining two are not itemised in the passage read):

```
soil/microbial/state.zig                          2  (validateNonstructuralPool)
soil/nutrients/nitrogen_state_update.zig          1  (production duplicate)
soil/microbial/layer_mixing.zig                   2
surface/topsoil_microbial_mixing.zig              3  (cell totals, validatePool, result)
soil/microbial/inventory_bridge.zig               2  (both mirror halves)
validation/landscape_mass_inventory_support.zig   4  (organic aggregation domain checks)
```

**All six paths verified present in this tree on 2026-09-23.** The error class walked the entire chain as each guard was relaxed:

```
InvalidMicrobialStatePool -> InvalidSoilMicrobialStateUpdate
-> InvalidMicrobialLayerMixingPool -> InvalidSurfaceTopsoilMicrobialMixingPool
-> InvalidSurfaceTopsoilMicrobialMixingResult
-> InvalidSoilMicrobialInventoryBridgePool -> NegativeSurfaceOrganicInventory
-> InvalidOrganicCarbonState
```

## The fix that replaced them IS live in this tree

This is the one thing here that is directly corroborated by this session's own evidence rather than by the register alone. The replacement fix clamps the nonstructural pool at the write and debits CO2, and `run-024`/`run-025`'s logs show exactly that clamp firing repeatedly at hour 3,275:

```
info: microbial nonstructural carbon clamped to zero, debited from CO2:
      layer=2 substrate=3 population=5 clamped_g_c=3.2109626236786393e-6
      carbon_gain=-7.465879640764944e-6
```

So the clamp is present and active, which is the precondition the register names for reverting the relaxations. **It also shows the clamp firing far more than the register's "`1.3e-7` g C once in 2,677 hours"** -- there are multiple clamp events in a single hour at magnitudes up to `3.2e-6`, i.e. more than an order of magnitude larger and vastly more frequent than the quantity that justified choosing a clamp over strictness. **That is a genuine new concern about the trade, and it is unquantified**: I have not summed the clamped mass over the run.

## MEASURED 2026-09-23: the clamp magnitude, and where the events actually occur

Summed from `run-026`'s log (`n101a/combined.log`, 12,048 lines), which needs no compiler:

| quantity | measured | register's stated basis | ratio |
|---|---|---|---|
| clamp events | **62** | "once" | 62x |
| total clamped | **7.0924083184463e-5 g C** | `1.3e-7` g C | **546x** |
| largest single event | **3.57077119241048e-6 g C** | `1.3e-7` g C | **27x** |
| mean event | `1.14393682555586e-6 g C` | -- | -- |

> **CORRECTED 2026-09-23 (task `20260923-205755-0455a53b`). The paragraph below is WRONG and is kept only for the record.** Key `layer=1 substrate=3 population=5` occurs 17 times. The emitter logs each key at most once per invocation of the serial single-cell hourly stage. So the events span at least 17 invocations, not one hour. Under same-stream log order, 10 events fall on or before the end of day 136 (line 11931, `scene_weather_hours=3264`), 46 in hours 3,265-3,275, and **6 in the failing attempt, hour 3,276**. The conservation rows at 12013/12022 belong to hour 3,276, not 3,275. Full argument: `audit/analysis/issue-102-clamp-events-span-many-hours-not-the-failing-hour-2026-09-23.md`. Provenance: the `n101a/combined.log` cited above is absent from the repo. The preserved `audit/runs/run-025-n100d-raw/combined.log` reproduces 62 events and 7.0924083184463e-5 g C exactly.

~~**But the distribution is the real finding: all 62 events fall inside the single failing hour.** They occupy log lines **11911-12011**, immediately before the hour-3,275 conservation rows at 12013 and 12022. **Zero clamp events occur in the preceding 3,274 hours.**~~

### What that does and does not change

**It does NOT overturn the register's A-versus-B judgement.** The deciding argument was that a bounded, logged, fully-booked deviation beats permanently widening the accepted state space. Against the run's own carbon inventory -- `organic_carbon_g_c = 4516.65` plus `residue_carbon_g_c = 1394.74`, about `5,911` g C -- the total clamped mass is a relative **`1.2e-8`**. That is negligible, the deviation is booked to CO2 so carbon conservation stays exact, and every event is logged. **The conclusion is robust even though its stated basis was understated by two and a half orders of magnitude.** I am not recommending revisiting the choice, which reverses the concern I raised when filing this issue.

**What it does change** is the characterisation. "`1.3e-7` g C once in 2,677 hours" described a different regime -- the register's frontier was hour 2,677, *before* the day-137 event this tree now reaches. Near the frontier the behaviour is qualitatively different: not a rare rounding artefact but **62 negative-carbon events recurring over at least 17 hourly invocations from day 136 onward** (corrected 2026-09-23; this previously read "concentrated in one hour"). So the quantity in the register is not wrong for its era; it is simply no longer the operative number, and anyone citing it to justify the clamp today should cite these figures instead.

### A lead for `issue-100`, offered as correlation only

> **WEAKENED 2026-09-23 (task `20260923-205755-0455a53b`).** The premise that the clamps and the failure share one hour is refuted. Under same-stream order, only 6 of 62 events (`9.19e-6` g C) fall in the failing attempt, hour 3,276. The clamp also fires in accepted hours that close nitrogen successfully, so co-occurrence does not single out the failing hour. The text below is retained unedited for the record.

**The 62 clamp events and the nitrogen conservation failure occur in the same hour** -- hour 3,275, the deck's day-137 banded NH4 + phosphate application, which `audit/analysis/frontier-hour-3275-...md` establishes is the frontier event for `issue-099` and `issue-100` alike. Microbial nonstructural carbon going negative 62 times in exactly the hour whose nitrogen closure fails is worth knowing.

**This is co-occurrence in a single hour, not a mechanism.** The clamp is on **carbon** and the residual is in **nitrogen**; the clamp is fully booked so it cannot itself be the nitrogen leak; and one hour is one sample. It is recorded as a lead because `issue-100` currently has none, not because it is evidence.

## Why it must NOT be reverted blind

The register states the caution itself, and it is the reason this is filed rather than fixed:

> "the clamp covers the **nonstructural** pool only, so structural pools could in principle still go negative by another route, and restoring blind would risk re-opening a blocker without evidence."

## Bounded next action

1. Sum the clamped carbon over a full run to hour 3,275 and compare against the `1.3e-7` g figure that justified the clamp. If the total is material, the A-versus-B judgement was made on a magnitude that no longer holds and should be revisited -- **this is the higher-value half of this issue.**
2. Restore the fifteen guards to strict **together**, then confirm the frontier holds at 3,275. The register says the commits are contiguous and individually titled, so a single range revert recovers them -- but those commits are in the reference repository's history, not necessarily this one, so the revert may have to be done by hand here.
3. Both steps require a working compiler. **Blocked**: see `issue-101` -- `D:` read latency has collapsed and no build completes on this host.

## Limitations

**Everything except the clamp-firing log lines is quoted from the reference `docs/discrepancy_register.md`, which is NOT in this repository** (`issue-097`), and none of it has been verified against the current source. I have not opened any of the six modules to confirm a guard is in fact relaxed, nor counted them, nor established that this tree's history is the same history the register describes -- the frontier differs (register 2,677 h, this tree 3,275 h), so the trees have diverged. The "two remaining" relaxations of the fifteen are not itemised in the passage read. The claim that the clamp fires more than the register's magnitude is read off log lines at one hour and is not a total.

## Bearing on `issue-097`

This is concrete evidence for the standing user decision. The reference docs are **not** merely historical: this entry names an actionable, unresolved liability in code that is live in this tree today, and the register's frontier of 2,677 h is close to this tree's 3,275 h. Whatever else importing `docs/` would bring, it demonstrably contains work items that this repository has no record of.
