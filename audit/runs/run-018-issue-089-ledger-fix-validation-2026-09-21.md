# run-018 -- the hour-3,253 frontier is CLEARED; frontier advances to hour 3,276

Date: 2026-09-21. Lane: editor (Claude Code), adversarial Claude/Pi session. One heavy run at a time respected.

## Result: the first genuine frontier advance of this session

**Hour 3,253 is cleared. `HourlyLayerConservationFailure` is gone -- zero conservation failures anywhere in the run -- and the deck now advances to hour 3,276** before failing on a new and unrelated error.

| | before this fix | after |
|---|---|---|
| last accepted hour | 3,252 | **3,275** |
| failing hour | 3,253 | **3,276** (day 137, 17 May, hour 12) |
| failure | `HourlyLayerConservationFailure` | `MissingFertilizerRecipientWaterVolume` |
| conservation failures in log | 4 | **0** |

`census_positive_control entries=3275 first_hour=1 last_hour=3275`. Both tillage events are behind us (`tillage_soil_application entries=2`, hours 2,532 and 3,252), so the tillage-triggered blocker that occupied `issue-078`, `issue-083` and `issue-089` is genuinely behind the run rather than merely deferred.

## What the fix was

Bookkeeping only -- no physics, tolerance, solver, or acceptance change. In `advanceAcceptedPhaseDisplacement`'s surface terminus (`stages/hourly_heat_water_solute.zig:4539-4570`), the accepted upward-displacement cascade now **declares** its soil-layer-0-to-surface transfer to the layer-local ledger, via two `accumulateLitterSoilLocalTransfer` calls (water and heat), mirroring exactly what the transport-replay litter-topsoil producer already does at `:8369-:8378`:

```
water = carry.matrix_liquid_water_m3 + carry.macropore_liquid_water_m3
heat  = surface.heat_capacity * surface.temperature - old_capacity * old_temperature
```

both passed **negated**, because that helper's convention is positive = surface-to-topsoil and this displacement arrives *at* the surface. The old surface temperature and heat capacity are captured before the routing overwrites their owners, which is what makes the enthalpy delta computable.

The quantity was already computed, already conservative, and already stored in `litter_soil_water_flux_m3`; it was simply never declared. `run-017` had shown the audit's two scopes disagreeing by `-4.2752681740391765` and `+4.2752681740404` MJ -- equal and opposite to ~11 significant figures **because the transfer was genuinely conservative all along**.

## Evidence

- Full suite `zig test src/module_index.zig`: **4375 passed, 1 skipped, 0 failed, exit 0** -- identical to the documented baseline, zero regressions.
- Targeted: `--test-filter "litter"` 393/393, `--test-filter "conservation"` 210/210, both exit 0.
- `zig build -Doptimize=ReleaseFast` exit 0, binary SHA-256 `C653A546285A7AE8C1474E782E60D6EF9590FB7D908486B9A288F9F893ADBB1B`.
- Run: fresh from hour 1, no checkpoint, `robocopy /E` scratch deck copy with `runottawa_output_files` recreated empty; tracked deck never written.
- Sign verified independently on both sides rather than assumed: the helper at `:8001-8004` routes `signed > 0` to `litter_soil_surface_to_topsoil_total` and `signed < 0` to `litter_soil_topsoil_to_surface_total`, and `layer_local_conservation.zig:1195-1198` maps the latter to `accumulateTransfer(topsoil, surface, ...)`. Reviewer round 23 returned **SOUND**, independently confirmed the sign, and noted that reversing it would have **doubled** the gap from 4.275 to 8.55 MJ rather than cancelling it -- a useful check, because a sign error here would have looked like "the fix made it worse" rather than like a sign error.

## The chain that is now closed

Four issues, resolved in sequence, each one exposing the next:

1. **`issue-078`** -- the hour-3,253 entry-capacity guard whose domain contradicted the oracle (`watsub.f:211-217`'s signed `VOLP1Z` beside the clamped `VOLP1`). Corrected in `run-015`; the abort disappeared with no regression.
2. **`issue-083`** -- the relief-term half, which regressed the frontier when applied with the guard in `run-013`. Stays reverted; `run-015` proved it was the regressing half. This run also settles its remaining question: the `FLQR` path is **not** missing from ecosys-ng after all -- `hourly_heat_water_solute.zig:4539-4570` *is* it. Only its ledger leg was missing.
3. **`issue-089`** -- the unbooked surface transfer the guard had been masking, localized across two instrumented reruns (`run-016` corrected my own "inactive soil layer" misreading; `run-017` measured the full chain).
4. Now **`MissingFertilizerRecipientWaterVolume`** at hour 3,276, which is new, unrelated to any of the above, and untouched by this session.

## Honest status

**The production-run criterion is still not met**: 3,275 of 262,920 hours (1.25%). The advance is +23 accepted hours, which is small in absolute terms. What matters more is that a blocker that had absorbed four issues, five production runs, and two escalations to human sign-off is now **resolved with a bookkeeping change and zero regressions** -- and that the `FLQR`-terminus port `issue-083` had escalated as a solver-architecture decision turns out **not to be needed at all**.

Also worth recording: the `0.001` residue-incorporation floor at `redistribution/tillage/surface_biomass_transfer.zig:77` produced a 1000x drop in litter water that looked exactly like a unit bug (identical mantissa, exponent shifted by three) and is in fact intended, legacy-faithful behaviour (`day.f:348`, `ITILL=10` gives `XCORP=0`). Anyone re-reading that trace should not re-file it.

## Next bounded action

Diagnose `MissingFertilizerRecipientWaterVolume` at hour 3,276. Note from the log that the hours immediately before it emit repeated `microbial nonstructural carbon clamped to zero, debited from CO2` notices across layers 2-4, which may or may not be related and should not be assumed either way. The diagnostic instrumentation from `run-016`/`run-017` is still in place and gated to hours 3,248-3,254, so it will need re-gating (or removing) before it is useful for hour 3,276.
