# issue-100: the failing conservation invocation is NOT the one the hour-3275 probes observed (2026-09-23)

Task `20260923-203925-5f8b9e80`. Source/evidence deduction only: no source change, no build, no run.
**No execution order is inferred from log-line position** (a rejected approach in `audit/handoff.md`).
Every step below uses source structure, or counts and values from the raw log.

## Evidence identities

| artifact | sha256 |
|---|---|
| `audit/runs/run-025-n100d-raw/combined.log` (run-025 raw log, copied from an earlier session's ephemeral scratchpad `.../58345113-.../scratchpad/n100d/combined.log`) | `c9d110f1c9b3e734023e99f43ee3d989a7f178469637e4496b1381406a09cfbb` |
| `ecosys-ng/src/ecosys_ng.zig` | `a7ff10dab37c9c25b8b99064627dcf0becaba9fa6ef1eb7553499df6424ab7ce` |
| `ecosys-ng/src/validation/hourly_cell_conservation.zig` | `a539abe98e733f039fe29785ec01e53b3f756de3cf4400816725f074285d4524` |
| `ecosys-ng/src/validation/layer_local_conservation.zig` | `af5f33d1c44d19ea032022f78b989b60f7887299c6d6b02750a89af015cd03f1` |

Source equivalence: `ecosys_ng.zig` was last changed in commit `8df913d` (issue-101 fix + issue-100 instrumentation) and is clean in the working tree.
That commit's message states it is the run-025 probe state, with the issue-101 relabel written afterwards.
The probe, gate and evaluate lines cited below are therefore those of the run-025 (n100d) and run-026 binaries.
**This rests on the commit message; the binaries were not rebuilt or disassembled.**

## Deduction

1. **The probe and the only production cell evaluation read identical data within one invocation.**
   - `acceptHourAndPublish` (`ecosys_ng.zig:5831`, sole caller `:7913`) prints the `at_evaluate` probe from `driver_context.hourly_cell_boundary_ledger.*.cells` at `:5881-5895`.
   - It then passes that same slice to `hourly_cell_conservation.evaluate` at `:5896-5906`, with no statement in between.
   - `transaction` maps nitrogen one-to-one: `.external_inputs = activity.nitrogen_input_g` (`hourly_cell_conservation.zig:2504`).
   - `evaluate` has exactly one production caller, and a source test enforces that count (`hourly_cell_conservation.zig:2647`). The other textual caller, `stages/hourly_heat_water_solute.zig:1342`, is inside a test.
2. **The probed invocation cannot have emitted row 0.**
   - The probe printed `cell0_in=0e0 cell0_out=1.4674866533175493e-2`.
   - Row 0 (`hourly cell conservation failure: cell=0 quantity=nitrogen`) reports `external_inputs=1.6566363548027827e0 external_outputs=4.033074007076744e-16`.
   - The same invocation would have printed `external_inputs=0`, so row 0 came from a **different** `acceptHourAndPublish` invocation.
3. **Row 0 is still a cell-evaluator row.** Only the cell evaluator uses the `.hourly` tag in production. Run-026 (relabelled binary) prints row 0 as `hourly cell ... cell=0` and row 2 as `hourly_layer layer_scope ... layer_scope=2`.
4. **The probe fired once.** The raw log contains exactly 1 `n_ledger[at_evaluate]` line and exactly 2 `conservation failure:` lines. These are counts, not order.
5. **The gate value of the failing invocation is not 3275.**
   - The gate is set per hour to `executed_weather_hours + 1` at the ledger reset (`ecosys_ng.zig:6884-6889`).
   - `executed_weather_hours` changes only at acceptance (`:6539`, inside `acceptHourAndPublish` after `:5896`) and at checkpoint restore (`:653`). Those are the only assignments.
   - A retry of the same hour would keep gate 3275 and fire the probe a second time, which did not happen.
   - So the invocation gated at 3275 was **accepted**, and the failing invocation was gated at **3276**.
6. **The census gives the same count independently.**
   - `observeHour(scene_weather_hours + 1)` runs **before** each hour (`:8236`).
   - `census_positive_control` is recorded only after `advanceHour` returns (`:8237-8243`, recorded at `:310`).
   - The log's `census_positive_control entries=3275 first_hour=1 last_hour=3275` and `across 3276 simulated hour(s)` therefore mean 3,275 hours accepted, with the failure during the attempt at hour **3,276**.

## Consequences (stated, not yet acted on outside this record)

- **The frontier is 3,275 accepted hours; the failure is on attempted hour 3,276.** Numbering is 1-based, as used by the census and the `executed+1` gate. The current handoff and the release-contract transcription say "3,274 accepted / failure on attempted 3,275"; both need correcting in a separately scoped edit.
- **Every `== 3275`-gated `TEMP_DIAGNOSTIC` in run-024, run-025 and run-026 observed the last *accepted* hour, not the failing hour.** These are the ledger mutation trace, the `accumulate`/`accumulateCells` traces, the `at_evaluate` probe and the two-allocation pointer table. That explains, without a new mechanism, why run-024's traced terms (`in=0, out=1.4675e-2`) "matched neither row". They were a different hour's ledger. None of those probe figures is evidence about the failing hour.
- Figures that **are** from the failing invocation:
  - both failure rows;
  - the post-NITRO trace, which is printed only inside `if (!hourly_cell_conservation_report.accepted())` (`ecosys_ng.zig:5908`, emitter `:5925-5926`).
- Layer scope 2 under `Layout.index` (`layer_local_conservation.zig:222-240`, production layout `ecosys_ng.zig:10822-10826`) is `soil_layer, cell 0, layer 2`, given `soil_layer_capacity > 2`. Run-025's "index 0 is a whole-domain *layer* scope" reading is superseded: row 0 is the single grid cell, which is the whole domain because `cells.len=1`.

## Unresolved counter-observation (not explained here)

The deck's third application (`17051998`, day 137; fields `1.65` band NH4 and `5.0`) would fall at census hour 136*24+12 = 3276. The earlier two sit at hour 12 of their days: census `2508` = day 105 and `3252` = day 136.
Fertilizer dispatch (`advanceFertilizerManagement`, called at `ecosys_ng.zig:7787`) records `fertilizer_application` via `recordCurrent` (`:7353`) when `any_application` is true, and no census restore was found.
Yet the census shows `entries=2 last_hour=3252`. So either:
- the day-137 dispatch in hour 3,276 produced `any_application == false`;
- it did not run before the failure; or
- this source-position reading is wrong.

This is **not** used as corroboration. It also bears on commit `0c9f3a9`'s "deposit happens at hour 3275": which counter gated that probe was not checked.

## Next bounded action

Re-gate the issue-100 probes to the failing hour. Add a call-site ID, a per-invocation counter, `executed_weather_hours` and `scene_weather_hours` to the `at_evaluate` probe and to the fertilizer dispatch. Then run one ReleaseSafe diagnostic to the frontier while D: is healthy. The prediction is falsifiable: with gate `== 3276`, the `at_evaluate` probe reports `cell0_in = 1.6566363548027827`.

## Limitations

- Source-structure deduction plus log counts; no new execution.
- Binary/source equivalence rests on commit `8df913d`'s message and the clean working tree.
- Single-threaded execution of `acceptHourAndPublish` is assumed from the code shown, not proven.
- `check_gate.py` owns gate status. Nothing here changes a gate. Release remains NOT_ASSESSED.
