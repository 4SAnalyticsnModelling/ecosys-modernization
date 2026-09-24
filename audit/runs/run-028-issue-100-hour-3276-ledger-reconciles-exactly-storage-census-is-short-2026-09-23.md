# run-028 -- issue-100: at the failing hour 3,276 the ledger reconciles exactly; the storage side is short by 0.0677 g N (2026-09-23)

Task `20260923-231724-7fa23089`. The prediction was registered in `audit/handoff.md` before the run.

## Run identity

- Binary: the same exe as run-027 (SHA256 prefix `24C04885821572F6`; build receipt `audit/runs/issue-100-n100e-build/receipt.json`). Source is HEAD `6944efe` plus the TEMP_DIAGNOSTIC re-gate in `ecosys-ng/src/ecosys_ng.zig` and `ecosys-ng/src/validation/hourly_cell_conservation.zig`.
- Deck: a fresh staged copy of the required `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/`, with no checkpoints (`runottawa` SHA256 `6A3691C8...`, `runtime,4,1,1e-8,1e-11,200,0.5`).
- Receipt `audit/runs/issue-100-n100f-run/receipt.json`: exit 1, 2,045.4 s. stderr SHA256 `B547C3A872C351367EB80223F5CB28787DDE2127FB40562CFEB48A88B6D8D6C6`.
- The frontier reproduces the recorded one: `census_positive_control entries=3275`, `across 3276 simulated hour(s)`, `fertilizer_application entries=2 first_hour=2508 last_hour=3252`, terminal `HourlyCellConservationFailure`. The row values are identical to run-025's, including `residual=-6.76655385993683e-2`.

## Prediction: CONFIRMED

stderr line 12014: `n_ledger[at_evaluate]: site=accept_hour_evaluate invocation=1 executed_weather_hours=3275 trace_hour=3276 ... cell0_in=1.6566363548027827e0 cell0_out=4.033074007076744e-16`. That is one invocation, and it matches the failing row's `external_inputs` bit for bit (line 12015).

## Complete hour-3,276 nitrogen booking for cell 0 (stderr lines 12000-12013)

| Line | Path | in (g N) | out (g N) |
|---|---|---|---|
| 12000 | `accumulate` (fertilizer publish) | 1.65 | 0 |
| 12009-12011 | `accumulateCells` x3 | 0 | 4.03e-16 total |
| 12013 | `accumulate` (second producer, unnamed) | 6.63635480278274e-3 | 0 |
| **sum** | | **1.6566363548027827** | **4.033074007076744e-16** |

The sum equals the evaluated row exactly, so **the boundary ledger is correct and complete for the failing hour**. With `before=641.8057163733818` and `after=643.3946871895852`, storage rose by 1.5889708 g N against a net input of 1.6566364. **0.0676655 g N (4.10% of the 1.65 g fertilizer N) is booked as input but absent from the after-hour storage census.** The layer row (layer_scope 2, line 12024) loses the same 0.06766553859959 g N, so the shortfall sits in soil layer 2.

## Counter-observation resolved

stderr line 12001: `n_ledger[fertilizer_dispatch]: executed_weather_hours=3275 any_application=true cell0_ledger_in=1.65e0`. Hour 3,276 does dispatch fertilizer. There is no third `fertilizer_application` census entry because the census is committed only for accepted hours (`ecosys_ng.zig:8236-8243`), and hour 3,276 is rejected. The hour-3,252 application is the second census entry.

## Consequences

- Earlier records conclude "ledger vs storage" from the hour-3,275 probe. Those figures describe the last accepted hour and are superseded for the failing hour by this record.
- The next falsifiable question is on the storage side. Which soil-layer-2 nitrogen pool(s) that receive the 1.65 g application (banded/non-band NH4+, NH3, urea, NO3-) are omitted from, or under-read by, the hour-end cell nitrogen storage census? Is 0.0677 g N one species' share of the application? The TEMP_DIAGNOSTIC probes stay in place until that is answered.
- No gate changes. The frontier stays at 3,275 accepted, with the failure on attempted hour 3,276.
