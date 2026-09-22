# Run 023 -- `issue-099`'s fix is VALIDATED: phosphorus and calcium conservation restored at hour 3,275; nitrogen is now the blocker, 2026-09-22

**Status: THE FIX WORKS AND IS RE-LANDED. The phosphorus and calcium `HourlyCellConservationFailure` rows are gone. Hour 3,275 now fails on NITROGEN with an ~8% residual instead of a 100% loss.** And the "regression" I attributed to this fix never existed -- see below, because that misattribution is the more important lesson.

## The fix

`mineral_fertilizer_inventory.publishSoil` converts phosphate amounts using **zone** water (`water_m3 * zone_fraction`) rather than full layer water, matching the census's own recovery in `landscape_mass_inventory_phosphorus_ions.phosphateImmobileInventory` and the legacy convention stated six times at `hour1.f:3826-3858` (`CNH4B = ZNH4B/(VOLW*VLNHB)`). A zone with no volume cannot hold solute, so its amount is amalgamated into the surviving zone per `hour1.f:4970-4973` instead of being divided away. Applied to monocalcium phosphate **and** hydroxyapatite, which share the same zone split and had the identical defect.

Suite: **4,380 passed / 1 skipped / 0 failed.** Two new mass-conservation tests pin the zero-volume and nonzero-volume round trips; two pre-existing tests encoded the superseded full-layer-water divisor and were corrected with the legacy citation plus explicit `amount_in == concentration_out * water * f_zone` assertions.

## Result

| | before the fix (`run-022`) | after the fix (`run-023`) |
|---|---|---|
| failing hour | 3,275 | 3,275 |
| phosphorus row | `external_inputs=5.000454772802566`, `residual=-4.9999999999999964` (**100% lost**) | **gone** |
| calcium row | `external_inputs=8.161072354057172e-2`, `residual=-8.064516129025165e-2` (**100% lost**) | **gone** |
| nitrogen row | not reported | `before=5.04112824263519e1 after=5.1993688088010714e1 external_inputs=1.7186002174175976e0` |

`census_positive_control entries=3275 first_hour=1 last_hour=3275`, terminal error `HourlyCellConservationFailure`.

**The nitrogen residual is a different shape.** Storage rises by `1.5824` against a booked input of `1.7186`, so the residual is about **-0.136, roughly 8% of the input** -- not the full-input annihilation signature the phosphate defect produced. The deck's day-137 line carries `1.65` in field 5, which `hour1.f:231` reads as `Z4B`, **banded NH4**, so banded ammonium is applied the same hour. An 8% partial discrepancy is a materially different defect from a 100% loss and should not be assumed to share a cause.

**The frontier number is still 3,275 and must not be reported as progress.** What is progress: a 100% mass-loss defect on two elements is fixed, production-validated, and covered by regression tests.

## The misattribution, which is the more useful record

I previously landed this exact change, saw the frontier apparently collapse to hour 4, reverted it, and wrote up a mechanism (a vanishing-but-nonzero band fraction becoming the divisor). **All of that was wrong.**

- A probe firing only for `0 < phosphate_band < 1e-3` fired **zero times**. No such fraction occurs.
- Rebuilding the **identical** code and running it reached hour 2,184 at 180 s -- normal throughput -- and ran on to 3,275. The code never caused an hour-4 stop.
- So the two earlier runs died for an external reason. Their logs were byte-identical at 65,738 bytes, which I read as determinism; that was consistent with an external kill at the same early point, and 65,738 is not a buffer boundary either.

Two further claims of mine collapsed along the way: the `THERMAL_PAIRED` volume was **not** solver distress (`hourly_heat_water_solute.zig:6948` gates it on `executed_weather_hours.* < 8` and fires unconditionally, so dense tracing in hours 1-4 is normal, and `run-022` produced the same 32 lines), and `validateSoilStateUpdate` was **not** the culprit either (recovered from git and inspected: also a no-op with an empty inventory).

**The lesson is narrow and worth keeping: I reverted a correct fix on the strength of two runs I had not established were valid experiments.** The revert itself was defensible -- leaving a suspected regression in the tree is worse -- but the write-up asserted a mechanism it had no evidence for, and three subsequent analyses were spent on a phenomenon that never happened. Re-running the unchanged code was the cheap check that should have come first, before any mechanism was proposed.

## Limitations

Single run, no repeat. The nitrogen residual is quoted verbatim from the run's own ledger and was not independently recomputed. The `Z4B` identification is a field-position match against `hour1.f:231` plus the deck line; the ecosys-ng nitrogen application path has **not** been read, so it is an identification, not a traced cause. `check_gate.py` owns gate status and nothing here changes it -- the run still stops at 1.25% of the horizon, so criterion 1 remains unverifiable and criterion 3 is untouched.
