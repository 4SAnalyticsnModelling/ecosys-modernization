# Run 022 -- `issue-098`'s fix is VALIDATED in production, and it exposes a deeper defect at the same hour, 2026-09-22

**Status: THE FIX WORKS. `MineralNitrogenInZeroWaterDomain` is gone. The frontier does NOT advance -- hour 3,275 now fails on `HourlyCellConservationFailure` instead, which the nitrogen abort was masking.** This is the same pattern already recorded for `issue-078` -> `issue-089`: removing the outer abort reveals the inner one.

## What was changed

`soil/biogeochemistry/mineral_nitrogen_transport.zig`, `publishMatrix`: when a band zone's volume fraction is zero and its amount is nonzero, the band amount is folded into its non-band counterpart and the band is zeroed -- `hour1.f:4970-4973` for the NH4 family and the `:5057` NO3 mirror, applied to all four band species.

The fold is in **amount space**, deliberately. `issue-098` records why: the stranded mass arrives by addition to `amount_mol` *after* `initializeMatrix` packed it, so it is not represented in any concentration, and a zero-volume zone's concentration carries no mass -- a concentration-space blend would have silently destroyed it.

`publishMatrix`'s `self` changed from `*const State` to `*State`; all three production callers already hold a mutable pointer, so no call site changed.

Two regression tests added: one reproducing hour 3,275's exact numbers (`1.1539999579320571e-7` mol against `fraction = 0e0` and `water_m3 = 7.061016156018221e-3`) and asserting mass is conserved to the last bit with the band emptied; one asserting a band **with** volume is left untouched, so the fold cannot erase a live band's concentration contrast.

**Suite: 4,378 passed / 1 skipped / 0 failed** (total rose 4,377 -> 4,379 for the two new tests). Zero regressions.

## Result: the nitrogen abort is gone

| | before (`run-021`) | after (`run-022`) |
|---|---|---|
| failing hour | 3,275 | 3,275 |
| error | `MineralNitrogenInZeroWaterDomain` | `HourlyCellConservationFailure` |
| wall clock | 556 s | 581 s |

`census_positive_control entries=3275 first_hour=1 last_hour=3275` on both. So the fix is confirmed correct and confirmed **not sufficient** to advance the frontier -- it removed a real defect that was standing in front of another one at the same hour.

**The frontier number is unchanged and should not be reported as progress.** What is progress: one source-verified science defect fixed, production-validated, with regression coverage and no regressions.

## The newly exposed defect: an external input booked but not applied

```
error: hourly cell conservation failure: cell=2 quantity=phosphorus
  before=4.1385007653583244e1  after=4.138512614717944e1
  external_inputs=5.000454772802566  external_outputs=3.3627920637213936e-4
  internal_production=0  internal_consumption=0
  residual=-4.9999999999999964  normalized_relative=9.998418146247833e-1
  effective_limit=5.000908115323741e-9

error: hourly cell conservation failure: cell=2 quantity=calcium
  before=1.6835573903075448e2  after=1.6835567715446925e2
  external_inputs=8.161072354057172e-2  external_outputs=1.0274385355498689e-3
  residual=-8.064516129025165e-2  normalized_relative=9.758828035885635e-1
  effective_limit=8.312066937640322e-11
```

The signature is unambiguous in both rows: **the residual is almost exactly minus the external input.**

- phosphorus: `residual = -4.9999999999999964` against `external_inputs = 5.000454772802566`
- calcium: `residual = -8.064516129025165e-2` against `external_inputs = 8.161072354057172e-2`

Meanwhile the storage barely moves -- phosphorus `after - before = +1.185e-4` where the booked input is 5.0. So the ledger counts an external input of ~5.0 units of P and ~0.0816 of Ca into cell 2 that **never arrives in the cell's storage**. Both residuals are 8 to 9 orders of magnitude outside their effective limits, so this is not a tolerance question.

**Both are at `cell=2`, the layer that carries the active ammonium band** (`run-021` measured its band fraction as 1.6447e-2). And the deck's day-137 banded line `17051998 0 0 0 0 1.65 0 0 0 0 5.0 ...` carries **`5.0`** in field 10 -- matching the phosphorus external input to four significant figures. The calcium figure is consistent with the Ca carried by monocalcium phosphate, the banded P species this deck applies.

So the working hypothesis is: **the day-137 banded fertilizer application books its phosphorus and calcium as external inputs but does not deposit them into the layer's inventory.** That is the mirror, in the phosphate family, of the nitrogen-side band-routing problems this session has been tracking -- and note `issue-098` already established that the phosphate amalgamation writes to discarded scratch (40 of the 46 pool arrays are phosphorus-family), which is an adjacent and possibly the same wiring fault.

**Not yet verified**: which code books the input and which should deposit it. The 5.0-vs-field-10 match is strong but is a numeric coincidence until the fertilizer parse is read. That is the next step.

## Limitations

Single run, no repeat. The wall clock (581 s against `run-021`'s 556 s) is one sample and includes different failure handling, so it is **not** a performance measurement and must not be compared with `run-021`'s criterion-3 figures. The conservation numbers are quoted verbatim from the run's own ledger; no independent recomputation was done. The hypothesis about the day-137 application is stated as a hypothesis. `check_gate.py` owns gate status and nothing here changes it -- the run still does not complete, so criterion 1 remains unverifiable beyond 1.25% of the horizon.
