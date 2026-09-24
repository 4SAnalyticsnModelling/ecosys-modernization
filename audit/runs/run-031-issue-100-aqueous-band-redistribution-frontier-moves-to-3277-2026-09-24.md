# run-031 -- issue-100: aqueous band-activation redistribution; hour 3,276 is ACCEPTED and the frontier moves to 3,277 (2026-09-24)

Task `20260924-040425-db7ece4d`.

## Change

This completes the legacy band-activation redistribution that run-030 began for the exchange term.

- NH4 activation: `chemistry.aqueous` `ammonium_*` and `ammonia_*` (`hour1.f:326-332`, `ZNH4S/B`, `ZNH3S/B`) now use the same layer-mean-concentration rule as exchange (`redistributeZoneConcentrationPair`). Both zones share the layer's water carrier.
- NO3 activation: `chemistry.aqueous` `nitrate_*` (`hour1.f:379,381,383`) uses the same rule. Nitrite, which is already extensive in `reactive_nitrogen`, is split by the new fractions (`:380,382,384`, `redistributeExtensivePair`).
- The input is an optional `NitrogenApplyContext.soil_aqueous`. Production passes `initial_chemistry_state.aqueous`, and callers that supply neither ISSUE-100 field keep the previous behaviour.
- Motivation, measured in run-030 (`audit/runs/issue-100-fix-run/stderr.log`): between the publish and `prepareHour`, `aq_nh4_nb_g` and `aq_nh3_nb_g` each fell by exactly 0.016447398 = 1 - f_nb_new, while the band stayed at 0. `captureHourStartMatrix` (`hourly_process_driver.zig:276`) rebuilds zone-extensive amounts as `C * water * f` (`mineral_nitrogen_transport.zig:113-118`) from the unchanged concentrations.
- Two new regressions: the aqueous NH4 creation case reproducing run-030's -4.986336e-4 g N pre-fix loss and conserving `C*W*f` to 1e-16, and the extensive nitrite split in both directions.

## Verification

- Full unit suite: `audit/runs/issue-100-fix2-tests/receipt.json`, exit 0, 2,351.2 s, **4385 passed / 1 skipped / 0 failed** (all 5 ISSUE-100 tests `OK`). One root, Debug, one platform.
- ReleaseSafe build: `audit/runs/issue-100-fix2-build/receipt.json`, exit 0, 1,010.6 s. exe SHA256 prefix `04FB320754646DDA`.
- Prod-deck run, fresh staged copy of `ecosys-ng-prod-examples/`, no checkpoints: `audit/runs/issue-100-fix2-run-log/receipt.json`, exit 1, 2,095.9 s. stderr SHA256 `E2354056D128778557CCB57D7869748E8B75F9D074982FC36E79A093512EC99F`. The first launch was rejected because `run_logged.py` refuses an existing `--out` directory, and it did not execute.

## Result

- **Hour 3,276 accepted.** `census_positive_control entries=3276 first_hour=1 last_hour=3276`, `across 3277 simulated hour(s)`, `fertilizer_application entries=3 first_hour=2508 last_hour=3276`. The banded application is now a committed census entry.
- Hour-3,276 probes: publish step -1e-13 and publish->`prepareHour` step 0 (was -5.171e-4). The chemistry step is 0 (was -1.55e-6). The NITRO/uptake ±0.00933 transient still cancels.
- **New frontier: 3,276 accepted, failing on attempted hour 3,277** with `HourlyCellConservationFailure`. The cell-0 nitrogen row has `external_inputs=2.6558452440355318e-2`, `residual=-1.0368401319391096e-6`, `effective_limit=2.7987316826793356e-11` (37,000x over the limit). Layer scopes: layer 1 `residual=-1.0265947631427075e-6` (99.0%), layer 2 `-1.0245355078208895e-8`.

## Prediction check (registered before the run: `audit/runs/issue-100-fix2-run/prediction-registered-before-run.txt`, mtime before this run's receipt)

- Predicted: publish->prepare goes to ~0. **Confirmed.**
- Predicted: hour 3,276 STILL fails with residual ~ -1.55e-6 from the chemistry step. **Refuted.** The chemistry step also went to 0 and hour 3,276 passed. So the -1.55e-6 was a downstream consequence of the unredistributed aqueous state, not an independent defect. I did not predict that.

## Open

- The hour-3,277 failure is a new, 1.04e-6 g N question, 99% in soil layer 1. It is filed as the next falsifiable question and not assumed to share this mechanism.
- The TEMP_DIAGNOSTIC probes remain and are still gated on hour 3,276, so they are silent at 3,277. Re-gating or removing them belongs to the next task.
- The NITRO/uptake ±0.00933 transient (a pool the census does not read between those points) is unexplained but conserves across the hour.

No gate is promoted. Frontier on the required deck: 3,276 accepted.
