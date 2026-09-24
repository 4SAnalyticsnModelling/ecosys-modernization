# Issue 103 -- hour 3,277: 1.0368e-6 g N of nitrate is lost in the after_uptake -> after_chemistry interval

Status: **OPEN -- LOCALIZED** (run-032, task `20260924-055505-f4a901f5`). The loss is a fraction re-base at `refreshMatrixFromReactionState`, caused by a SECOND NO3/PO4 band growth (`soil_chemistry_convergence.updateFertilizerBandGeometry` -> `fertilizer_band_nitrate_phosphate.updateLayer`, "hour1.f 4992-5200") that runs outside the band coordinator and discards its repartitioned pools. `prepareHour` already ports the single legacy `DO 9986` growth (`hour1.f:4888-5151`). Next: adjudicate the faithful pass against legacy and remove or merge the duplicate. See `audit/runs/run-032-issue-103-duplicate-no3-band-growth-in-chemistry-stage-rebases-nitrate-2026-09-24.md`.

## Observation (run-031, `audit/runs/issue-100-fix2-run-log/stderr.log`, SHA256 `E2354056...`)

- 3,276 hours accepted. Attempted hour 3,277 fails `HourlyCellConservationFailure`. Cell-0 nitrogen: `before=6.434623521436938e2`, `after=6.43488909559294e2`, `external_inputs=2.6558452440355318e-2`, `residual=-1.0368401319391096e-6`, `effective_limit=2.7987316826793356e-11`.
- Layer scopes: layer 1 `residual=-1.0265947631427075e-6` (99.0%), layer 2 `-1.0245355078208895e-8`.
- No fertilizer application at hour 3,277. The hour-3,276 banded application's NH4 and NO3 bands exist, and 3,277 is the first hour those bands can grow (`prepareHour` / `fertilizer_band_state.zig:482-485` source->destination layer moves).

## Decomposition from the existing failure trace (exact `Fraction` arithmetic over the post-NITRO six-pool trace)

The six-pool sum at `after_surface_gas` minus the row's `after` is -4.35e-13.

| Interval | Change (g N) | Pools |
|---|---|---|
| hour start -> `after_nitro` | -0.00869621520707 | (NITRO transient; see below) |
| `after_post_watsub` -> `after_uptake` | +0.008696215 | NH4 +9.4513e-3, NO3 -7.5511e-4 (cancels the NITRO step) |
| **`after_uptake` -> `after_chemistry`** | **-1.036840e-6** | **NO3 -1.0368e-6**, NH4 +2e-14 |
| `after_chemistry` -> `after_transport` | +0.02655845 | N2 +2.6559e-2 = booked input |

**The whole residual is a nitrate loss inside the chemistry (SOLUTE) interval.** Hour 3,276 showed the same signature before the aqueous fix (chemistry step -1.55e-6 NO3, run-029/030), and that one disappeared once activation redistributed aqueous nitrate (run-031).

## Next

A probe (`diagnostics.traceIssue103LayerNitrate`, layers 1-2) is placed at the chemistry-stage brackets in `soil_chemistry_convergence.zig` (`validateCarrierVolumesScaled`, `refreshMatrixFromReactionState`, `exportChemistry`, `consumeUndissolved`) and at the issue-100 sites. It is gated on hour 3,277. The prediction registered before the run is in `audit/runs/issue-103-probe-prediction/prediction-registered-before-run.txt`.

## Localization (run-032)

See the run record. Prediction CONFIRMED: at the refresh bracket, layer 1 loses -1.0266e-6 and layer 2 nets -1.03e-8, which sum to the residual.
