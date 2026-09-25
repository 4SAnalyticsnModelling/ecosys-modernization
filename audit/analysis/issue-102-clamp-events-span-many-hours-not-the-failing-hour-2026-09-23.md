# issue-102: the 62 clamp events span at least 17 hour invocations, not the single failing hour

Task `20260923-205755-0455a53b`. Evidence only: no source change, no build, no run.
Raw input: `audit/runs/run-025-n100d-raw/combined.log`, 12,048 lines, SHA256 `c9d110f1c9b3e734023e99f43ee3d989a7f178469637e4496b1381406a09cfbb`.

## Claim under test

`issue-102` (section "MEASURED 2026-09-23"): "all 62 events fall inside the single failing hour ... **Zero clamp events occur in the preceding 3,274 hours.**" Its lead for issue-100 rests on the same claim ("the 62 clamp events and the nitrogen conservation failure occur in the same hour").

**Result: REFUTED.** Two independent arguments follow. Argument A uses only counts and source structure. Argument B uses same-stream log order and is stated separately, with its dependency spelled out.

## Provenance note

issue-102 says its figures came from `run-026`'s `n101a/combined.log` (12,048 lines). No such file exists in this repository (`**/n101a*/**/combined.log`: no match). The preserved run-025 log has the same line count and reproduces issue-102's totals exactly: 62 events, sum `7.0924083184463e-5` g C. So every figure here is recomputed from the run-025 file, and the n101a attribution is recorded as unverifiable.

## A. Count and source argument (no log order used)

Emitter: `ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig:623-630`, inside `state_updateLayer` (`:86`). There is one log line per clamped (layer, substrate, population) unit per call. `applyTile` (`:81-83`) calls `state_updateLayer` once per layer in its range.

The call chain as far as it was traced:
- `hourly_sediment.zig:394` calls `routeBiogeochemistryAndSolutes` once.
- That calls `biogeochemistry_batches.runSoilBiogeochemistryBySerialTile` once (`hourly_sediment.zig:1071`).
- That loops tiles **serially** (`biogeochemistry_batches.zig:415-421`) into `runSoilBiogeochemistryBatch`.
- The batch invokes `soil_nitrogen_state_update.applyTile` once (`:376-377`, `.timestep_h = 1`).
- The log shows `cells.len=1`, i.e. one grid cell and therefore one tile. `compute.zig:931-933` states that "no worker boundary can split the vertical column of one grid cell".

So each hourly-sediment invocation logs any given (layer, substrate, population) key **at most once**.

Key multiplicities in the log:

| key (layer/substrate/population) | events |
|---|---|
| 1/3/5 | 17 |
| 2/3/5 | 15 |
| 3/3/5 | 14 |
| 4/3/5 | 11 |
| 0/1/5 | 3 |
| 1/1/5 | 2 |
| **total** | **62** |

Key 1/3/5 occurs 17 times, so the clamp fired in **at least 17 distinct invocations** of the hourly biogeochemistry stage. The claim that all 62 events belong to one hour holds only if one hour invokes this hourly stage 17 or more times.

**Not traced in this task:** the link from the hour driver to `hourly_sediment.zig:394`, and whether a rejected hour attempt is ever re-executed. With the census's 3,276 simulated hours for 3,275 accepted (failure terminates the run), hour-level retry is not indicated, but it is not excluded from source here.

## B. Segment attribution (depends on same-stream log order)

This argument assumes that `std.log` lines from this serial-tile, single-cell run appear on the single combined stream in program order. That assumption is exactly why it is kept separate from A.

Two anchors are fixed by count rather than position:
- **Line 11931:** `day advanced: scene_weather_hours=3264`. This is the 136th `day advanced` line (136 in total; 136 x 24 = 3,264). The 136th of 136 `daily conservation accepted` lines (day=136, hour=24) is line 11930.
- **Line 12004:** the only `n_ledger[at_evaluate]` line. Task `20260923-203925-5f8b9e80` (Pi PASS, `audit/reviews/20260923-203925-5f8b9e80-r1.json`) established it observes accepted hour 3,275.

| segment | clamp events | hours (under assumption B) |
|---|---|---|
| lines < 11930 (on or before end of day 136) | **10** | <= 3,264 |
| 11931 < line < 12004 | **46** | 3,265 - 3,275 (accepted) |
| line > 12004 | **6** | 3,276 (the failing attempt) |

The six events in the failing attempt are lines 12006-12011 and sum to `9.1934454452108e-6` g C, about 13% of the 62-event total. Between the anchors, the clamp groups are separated by paired `n_ledger[init]` lines. The totals are consistent with two inits per hour (6,556 inits against 3,276 simulated hours), and the per-key magnitudes rise group to group. That is corroboration only, not proof.

## Consequences for issue-102

- The magnitude table (62 events, 7.09e-5 g C, 546x the register basis, relative 1.2e-8 of about 5,911 g C) is unchanged. So is the conclusion that the clamp-over-strict judgement is robust.
- "Concentrated in one hour" and "zero in the preceding 3,274 hours" are withdrawn. The clamp is a recurring multi-hour regime: at least 17 invocations by A, and under B hours up to and including day 136 through the failing hour 3,276.
- The issue-100 co-occurrence lead weakens. By argument B only 6 of 62 events fall in the failing attempt, and clamps also fire in the accepted hours before it. The co-occurrence does not single out the failing hour.
- Onset, under assumption B: the log carries `day advanced` for every day from day 1 (line 501, `scene_weather_hours=24`) to day 136 (line 11931). The earliest clamp line, 11911, follows the day-135 advance (line 11688, `scene_weather_hours=3240`). So no clamp fires in days 1-135 (hours 1-3,240), and the regime begins on day 136 (hours 3,241-3,264), the day before the day-137 fertilizer event. Its exact onset hour is not established.
