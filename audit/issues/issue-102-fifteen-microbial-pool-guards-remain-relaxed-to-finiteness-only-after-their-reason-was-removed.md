# Issue 102 -- fifteen microbial-pool guards remain relaxed to finiteness-only after the defect that motivated them was fixed another way

Status: **OPEN, NOT INVESTIGATED IN THIS REPO (filed 2026-09-23).** Identified by reading the reference `docs/discrepancy_register.md`, which records this cleanup as explicitly **not done**. The six named modules all still exist in this tree (verified). **Nothing here has been confirmed against the current source** -- this is a worklist item with a precise citation, not a measurement.

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
