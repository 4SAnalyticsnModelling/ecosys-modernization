# Run 010 -- Cumulative per-hour overhead check on ordinary (non-degenerate) hours from this session's water-carrier-floor/guard/backtracking batch, 2026-09-20

**Status: MEASURED. NO measurable cumulative overhead found.** Over a matched, retry-ladder-light, early-in-run window (hours 96-504 of 1998, 408 hours), the current `main` binary (git HEAD `10bd69a`, includes the full water-carrier-floor threading, the new `FloorDiscard`/`renormalization_floor_discard_megajoules_by_layer` ledger, the three solver-domain guards, and the two `phase_solver.zig` backtracking mechanisms) is, if anything, mildly **faster** than a binary built from immediately before this session's fix chain started (git commit `37989ca`, the last commit before `issue-058` was even filed) -- median -0.86%, mean -2.49% -- and that apparent difference is smaller than the pre-session binary's own repeat-to-repeat noise (10.4% spread vs. the post-session binary's 3.2% spread). This is a distinct question from `run-008`/`run-009` (which measured the hard-hour/retry-ladder tail near hour 2,568-2,895 and found the fix batch's *net* wall time there flat-to-improved); this run specifically targets whether the batch's ~10+ newly threaded floor-substitution call sites and new checks impose a broad, small, per-ordinary-hour tax that a tail-focused measurement could miss. None was found.

## Task and scope

This session added a substantial number of new checks/guards/floor-substitutions to code that runs every hour for every cell, not just hard/degenerate hours: `legacyNegligibleWaterVolumeM3` threaded into ~10+ functions across `erosion_chemistry_bridge.zig`, `aqueous_transport_bridge.zig`, `water_carrier_rebase.zig`, `landscape_mass_inventory_*.zig`, `litter_ammonia_phase_bridge.zig`, `mineral_nitrogen_transport.zig`, and others; the `FloorDiscard`/`renormalization_floor_discard_megajoules_by_layer` ledger; three solver-domain guards in `solver_solve.zig`/`phase_solver.zig`; two backtracking mechanisms in `phase_solver.zig`. Each was verified individually as "a no-op for normal cases," but nobody had measured whether the *cumulative* overhead of all these additions, even if each is individually cheap, adds up to a measurable tax on an ordinary, non-degenerate hour. `run-008` already showed the fix batch's *net* wall time to the hour-2,894/2,895 hard-hour boundary is flat-to-improved, but that measurement is dominated by a handful of expensive stiff-convergence hours (peak: hour 2,592, ~14-16 s alone) and could hide a small broad tax under that noise floor. This run isolates an early, ordinary window specifically to check for that broad tax directly.

## Method

### Choosing the "before" commit

Per the task's instruction, searched `git log` for a commit predating this session's fix chain. `issue-058` ("make `boundedRecoveryFallback` array-driven, close recurring drift gap") is the first commit of the batch `run-008`/`run-009` already characterized. Its own filing commit is `2f9ebb0` ("File issue-058: `recovery_substep_counts` has two inconsistent consumers..."). The commit immediately before that filing is:

```
37989ca689e79a0b743de2b9fc7797979486cc8b  2026-09-19 09:12:22 -0600
"issue-024 round 7: forced 1/80h substep experiment crashes (access violation);
 reveals recovery_substep_counts consumer inconsistency; inconclusive on candidate 2"
```

This is the last commit before the water-carrier-floor/guard/backtracking chain (`issue-058` through `issue-068`, plus `run-008`/`run-009`) began, and is used as the "before" build. Confirmed via `git show 37989ca:ecosys-ng/src/ecosys_ng.zig` that the pre-existing day-boundary logging (`"day advanced: scene_weather_hours={d} final_hour_elapsed_ms={d}"`, fired every 24 hours) and the `--verbose-diagnostics`/`PERF_HOUR_TRACE` infrastructure already existed at this commit -- i.e., the measurement instrumentation itself is not part of what changed, so both binaries can be timed the same way.

### Building both binaries

- **"Before"**: extracted the `ecosys-ng/` subtree at `37989ca` via `git archive -o old.tar 37989ca -- ecosys-ng` (repo root is `D:\ecosys-modernization`; `ecosys-ng/` is a subdirectory, not a separate repo) into the session scratchpad, then `zig build -Doptimize=ReleaseFast` (Zig `0.16.0`) there, with no changes to the tracked working tree. Result: `ecosys_ng.exe`, 11,651,584 bytes, SHA-256 `5212E69972BFFD6BAA54B3666E2CD1FEFC6893422F8509EB673525A4468A89EF`.
- **"Current"**: git HEAD `10bd69afeabdd5f129bb2bc0bce5b9e1c275b8e0` (`run-009`'s own commit; `git status --short` clean before build) via `zig build -Doptimize=ReleaseFast` in the tracked `ecosys-ng/` directory. Result: `ecosys_ng.exe`, 12,257,792 bytes, SHA-256 `CA708F624C59E608C58C211C9A5CF8D1A1C2F19A9578ABD89DCD4C34CDEF7A80` -- **byte-identical to `run-008`'s and `run-009`'s own binary hash**, confirming no source drift since those runs' own measurements (this run's "current" binary is the exact same artifact they measured the hard-hour tail with).

**Disclosed concurrent-agent note**: partway through this run's measurement phase, `main` advanced two further commits (`40ba6e0`, `89e17ba`, `issue-069`: "fix `pond_chemistry_transfer` and `gatherTillageSurfaceAmounts` exact-zero carrier guards") by a different concurrent agent, per this project's multi-agent-coordination model. This run's "current" binary does **not** include that commit; it measures `10bd69a` only, which was the actual current `main` HEAD when this run's build started and matches `run-008`/`run-009`'s own measured artifact. No source file was touched by this run itself (`git status --short` clean throughout).

### Hardware/power state

Same machine as every prior run in this series: 13th Gen Intel Core i9-13950HX, Windows 11 Enterprise 10.0.26100. Checked before the measurement block: `powercfg /getactivescheme` **Balanced** (`381b4222-f694-41f0-9685-ff5bb260df2e`), `Win32_Battery` **on AC, 100%** -- unchanged throughout. No other `zig`/`gfortran`/`ecosys` process running before any repeat (explicitly checked and, where a transient post-kill race was observed, reconfirmed clean one poll later before starting the next repeat).

### Deck and window choice

Fresh `robocopy /E` scratch copies of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/` per repeat (10 total: 5 "before" + 5 "current"), untruncated (all 6 scenes present in the deck file, since this run only needs the first ~500 hours of scene 1 and kills the process well before any scene transition). Invocation matches the established methodology (`run-003`/`run-007`/`run-008`): `ecosys_ng.exe --threads 1 --execution-evidence <tag>_evidence.json runottawa`, single-threaded, no `--verbose-diagnostics` (avoids `run-004`'s known logging-overhead confound; the always-on day-boundary line is sufficient).

**Window: hours 96-504 (day 4 to day 21 boundary, 408 hours)**, deliberately *not* hours 1-96: a narrow, pre-existing, unconditional debug trace (`THERMAL_PAIRED`, gated `executed_weather_hours.* < 8`, confirmed present unchanged in the `37989ca` source too, so not part of this session's additions) and genuinely more expensive early-January freeze/thaw physics make hours 1-~90 atypically slow and noisy (observed per-hour cost 200-300 ms in that stretch, vs. ~50-90 ms once past hour ~100). Measuring the **delta** between the hour-96 and hour-504 day-boundary log timestamps (rather than wall time from process start) cancels out this early-window effect and any startup/parse cost, isolating exactly the ordinary, later, steady-state portion of the run the task asked for ("hour 100-500, well before any degenerate-layer issues," which per `run-008`/`run-009` begin only past hour ~2,568).

Timestamps were captured by launching each binary via `System.Diagnostics.Process`/`Start-Process` with stderr redirected to a log file, then polling that file (`Select-String -SimpleMatch -Quiet`, 40 ms interval) against the exact literal strings `"scene_weather_hours=96 final_hour_elapsed_ms"` and `"scene_weather_hours=504 final_hour_elapsed_ms"`, recording a `Stopwatch`-relative timestamp at first match, then killing the process immediately after the hour-504 line was found (no need to run further). Each repeat used a fresh deck copy and was preceded by an explicit check that no stray `ecosys_ng` process was already running (a real bug caught and fixed mid-run: an earlier script version tried to bound the kill point with a non-day-boundary hour marker that never appears in the log, causing three early repeats to run unbounded until a 150 s timeout and leak concurrent processes into the next repeat; those three contaminated repeats were discarded and are not included in the results below -- all reported numbers are from the corrected script with verified clean single-process isolation per repeat).

## Results: 5 repeats each, hours 96-504 window (408 hours)

| repeat | before (`37989ca`) window (ms) | current (`10bd69a`) window (ms) |
|---|---|---|
| 1 | 23,889.48 | 21,964.42 |
| 2 | 22,032.79 | 22,218.62 |
| 3 | 21,577.57 | 22,195.58 |
| 4 | 22,752.05 | 21,719.36 |
| 5 | 22,154.15 | 21,512.63 |

| | before | current |
|---|---|---|
| median (ms) | 22,154.15 | 21,964.42 |
| mean (ms) | 22,481.21 | 21,922.12 |
| min (ms) | 21,577.57 | 21,512.63 |
| max (ms) | 23,889.48 | 22,218.62 |
| spread (max-min, ms / % of median) | 2,311.91 / 10.43% | 705.99 / 3.21% |
| implied rate (median ms / 408 h) | 54.3 ms/hour | 53.8 ms/hour |

**Current vs. before**: median **-189.7 ms (-0.86%, current faster)**; mean **-559.1 ms (-2.49%, current faster)**. Both deltas are smaller in magnitude than the *before* binary's own repeat-to-repeat spread (10.43%), and smaller than or comparable to the *current* binary's own spread (3.21%). There is no direction- or magnitude-consistent signal of added overhead; the small apparent difference, such as it is, points the *opposite* way from a regression.

## Behavioral cross-check: is this window actually representative and unaffected by hard-hour machinery?

Directly inspected repeat 1's full stderr logs for both binaries over this window (600 lines each):

- **One retry-ladder escalation episode occurs inside the window** (`bounded fixed external hour recovery rejected`/`accepted`, `error=HeatInducedPhaseChangeRequiresQuarterHourSubsteps`), appearing **at the identical log line number and with identical field values in both binaries** (8 matching lines total: 4 rejected + 4 accepted events each). This is a legitimate, small, early-winter freeze-thaw episode -- not the hour-2,568+ hard-hour frontier `run-006`/`run-008`/`run-009` characterized -- and because it occurs identically in both binaries, it does not bias the before/after comparison.
- The new/flagged solver-safety guard, `implausible surface conductive flux` (per `run-008`, one of this session's three new solver-domain guards), fires **96 times in this window, identically in both the before and current binary** (same count, same line numbers, same values on direct diff). This was unexpected given `run-008`'s framing of the guard as new to this session's `issue-058..068` batch -- either the guard (or an equivalent check with the same trigger and message) already existed at `37989ca`, or it was added in a way that reproduces byte-identical behavior for this window's exact input trajectory. Either way, it demonstrates the check imposes **no observable behavioral or timing difference** between the two binaries here.
- `renormalization_floor_discard_megajoules_by_layer`/`FloorDiscard` log output: **zero occurrences** in this window on the current binary -- the new ledger mechanism is dormant for this entire 408-hour ordinary stretch, consistent with it being a no-op absent the floor-substitution condition it exists to handle.
- The two logs are **not** byte-identical overall (270 of 600 lines differ, expected: numerous correctness fixes landed in this batch and should shift downstream ledger/conservation values slightly), but line *counts* match exactly (600 vs. 600) and the specific hard-hour-adjacent event counts above match exactly -- consistent with "same control flow, same amount of work, slightly different computed values," not "extra work added."

## Interpretation

This directly answers the task's step 5 question for the *typical-hour* case specifically (as distinct from `run-008`/`run-009`'s hard-hour-tail answer): **no measurable (>2-3%) cumulative per-hour overhead was found** in an ordinary, non-degenerate 408-hour window early in the run. The measured difference (current binary 0.86-2.49% faster, depending on median vs. mean) is smaller than the "before" binary's own run-to-run measurement noise (10.4%) and does not exceed the task's own stated threshold for a reportable finding. This extends `run-008`'s hard-hour-tail finding ("the correctness fix batch did not add net wall-time cost on this workload -- if anything it is mildly faster") to the specific case that measurement could have missed: broad, small-but-cumulative tax on ordinary hours from ~10+ newly threaded floor-substitution call sites and new guards. None was found. The "no-op for normal cases" claim made individually for each addition during this session's fix batch is **confirmed at the aggregate, measured level**, not just structurally/logically.

## Honest caveats

1. **Sample size**: 5 repeats per side, not a larger statistical sample. The spread reported (10.4% "before" / 3.2% "current") is itself only a 5-point empirical range, not a formal confidence interval; a larger repeat count could in principle narrow the noise floor below the observed 0.86-2.49% delta, but 5 repeats is already above this project's stated minimum of 3, and the direction of the delta (current faster, not slower) argues against a hidden regression rather than for one.
2. **Single window, single deck, single machine, single session** -- consistent with every prior run in this series; no cross-machine or cross-season reproduction attempted. A different, later-in-year window could show a different absolute per-hour rate (this window's ~54 ms/hour is below `run-008`'s ~92 ms/hour average sampled over the much longer hour-24-2,568 stretch, which includes some costlier periodic hours `run-006` already flagged), but the before/after *comparison* at a fixed matched window is the relevant quantity for this task, not the absolute rate.
3. **One retry-ladder episode falls inside the chosen window** (hours ~103-ish, inferred from log line position). This was not avoidable while also satisfying the task's "early, hour 100-500" guidance, since even ordinary early-winter hours include occasional legitimate freeze-thaw substep escalation (per `run-006`'s established characterization, this is not exclusive to the hour-2,568+ frontier). Its identical occurrence in both binaries means it does not confound the relative comparison, but the window is not a perfectly quiescent, escalation-free 408 hours.
4. **A concurrent agent landed a further commit (`issue-069`, `89e17ba`) on `main` during this run's measurement phase.** This run's "current" binary is `10bd69a` (matching `run-008`/`run-009`'s own measured artifact), not `89e17ba`. `issue-069` is, per its own commit message, another instance of the same water-carrier exact-zero-carrier-guard defect class this task is about, so a future remeasurement including it would be a reasonable follow-up, but is out of this run's bounded scope.
5. **No source, test, or configuration change was made in this run** -- measurement only, per the task's explicit instruction.

## Disposition and next action

- The task's core question -- "does the cumulative overhead of this session's ~10+ floor-substitution call sites, the new `FloorDiscard` ledger, three solver-domain guards, and two backtracking mechanisms add a measurable tax to ordinary hours" -- is answered **no**, at the aggregate/measured level, corroborating (not merely repeating) the individual "no-op for normal cases" claims already made for each addition.
- No performance fix is needed or attempted as a result of this run.
- If a future session wants a larger-N confirmation, the exact repro is: build `37989ca` and current `main` in `ReleaseFast`, run the isolation/window/kill recipe above with `>=5` repeats each. Given the direction found here (current mildly *faster*), this is a low-priority follow-up, not an open risk.

## Evidence paths

- `<scratchpad>/old-37989ca/ecosys-ng/` -- extracted pre-session source tree (via `git archive 37989ca -- ecosys-ng`) and its `ecosys-ng-bin/ecosys_ng.exe` build (SHA-256 `5212E69972BFFD6BAA54B3666E2CD1FEFC6893422F8509EB673525A4468A89EF`).
- `ecosys-ng/ecosys-ng-bin/ecosys_ng.exe` -- current binary used (SHA-256 `CA708F624C59E608C58C211C9A5CF8D1A1C2F19A9578ABD89DCD4C34CDEF7A80`), git HEAD `10bd69afeabdd5f129bb2bc0bce5b9e1c275b8e0`.
- `<scratchpad>/run_typical_window3.ps1` -- the corrected, verified-isolated repeat-runner script (single-process-checked, kills immediately on reaching the end-of-window day-boundary line rather than depending on a non-boundary "kill" marker).
- `<scratchpad>/r10-old-rep{1..5}/`, `<scratchpad>/r10-new-rep{1..5}/` -- isolated per-repeat deck copies and their `r10old{n}_stderr.log` / `r10new{n}_stderr.log` / `_evidence.json` outputs.
- All scratchpad artifacts are retained in the session scratchpad only, per the standing root-cleanliness instruction, not committed to the repository.
