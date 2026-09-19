# Issue 059 -- `TransportReplay.time_step_hours` is a hardcoded `[64]f64` buffer sized independently of `recovery_substep_counts`; extending the ladder past 64 substeps overflows it and crashes the production binary

Status: **OPEN, ROOT CAUSE IDENTIFIED this pass (2026-09-19); NOT FIXED (diagnosis-only pass, per explicit instruction).** Filed out of `issue-015`'s "## Substep-ladder extension experiment (2026-09-19)" addendum, which reproduced a `STATUS_ACCESS_VIOLATION` (exit `-1073741819`) twice when `heat_step.zig`'s `recovery_substep_counts` was extended from `[1,2,4,8,16,20,32,64]` to `[1,2,4,8,16,20,32,64,128]` and the production Ottawa deck was replayed through the retained hour-2,578/2,579 frontier, but did not identify the exact mechanism. This pass reproduced the same crash under `-Doptimize=ReleaseSafe` instead of `ReleaseFast` (a diagnostic-build substitution, chosen over `Debug` to keep wall-clock time inside this pass's budget) and obtained a fully symbolized panic instead of a silent access violation, pinpointing the exact line, buffer and mechanism below.

Owner: unassigned
Candidate/input hashes: `audit/manifest/candidate-001-snapshot.json` sha256 `79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979` (same candidate as `issue-015`/`issue-058`; current tracked source is byte-identical to that snapshot for the two files this issue touches -- see "Reachability" below)
Cross-references: `audit/issues/issue-015-hour-2578-frontier-needs-human-design-decision.md` (originating experiment, "## Substep-ladder extension experiment" section); `audit/issues/issue-058-recovery-substep-counts-two-inconsistent-consumers-crash-risk.md` (same recurring defect *shape* -- a substep-count constant hardcoded independently of `recovery_substep_counts` -- but a *different* consumer/file/field than the one issue-058 fixed; issue-058's fix does not cover this one).

## Failure signature and first bad time/location/process

Same production frontier as `issue-015`'s addendum: Ottawa deck, hour 2,579 (day 108, hour 11), after the SOLUTE reaction-network solver's non-convergence at 64 substeps (`maximum_scaled_residual~=1.16e3`, matching `run-001`) triggers escalation to the new 128-substep tier via `issue-058`'s now-correctly-array-driven `boundedRecoveryFallback`. Partway through the 128-substep loop (after roughly 85 consecutive `error: implausible surface conductive flux` diagnostic lines, the same pre-existing non-fatal `temperature_solver.zig:764-767` log line noted in `issue-015`'s addendum), the process crashes.

Under `-Doptimize=ReleaseFast` (the mode `issue-015`'s addendum used): silent `STATUS_ACCESS_VIOLATION`, exit code `-1073741819` (`0xC0000005`), no panic message -- exactly as previously documented, because `ReleaseFast` compiles out the bounds check that would otherwise catch this.

Under `-Doptimize=ReleaseSafe` (this pass, same one-line array edit, same deck, same binary otherwise): the bounds check fires and produces a clean, symbolized panic:

```
thread <tid> panic: index out of bounds: index 64, len 64
D:\ecosys-modernization\ecosys-ng\src\stages\hourly_heat_water_solute.zig:2663: 0x... in beginSubstep (ecosys_ng_zcu.obj)
    self.time_step_hours[self.count] = time_step_hours;
D:\ecosys-modernization\ecosys-ng\src\stages\hourly_heat_water_solute.zig:4153:51: 0x... in prepareSubstep (ecosys_ng_zcu.obj)
    try self.transport_replay.beginSubstep(time_step_hours);
D:\ecosys-modernization\ecosys-ng\src\soil\water\heat_step.zig:685:38: 0x... in advanceMappedDeferred (ecosys_ng_zcu.obj)
    hooks.prepare_substep(hooks.context, time_step_hours) catch |err| {
D:\ecosys-modernization\ecosys-ng\src\stages\hourly_heat_water_solute.zig:12346:89: 0x... in solveSoilHeatWaterAndSoluteTransportAttempt__anon_196270 (ecosys_ng_zcu.obj)
    var accepted_soil_water_heat = try ecosys.soil_water_heat_step.advanceMappedDeferred(...)
D:\ecosys-modernization\ecosys-ng\src\stages\hourly_heat_water_solute.zig:11755:60: 0x... in run (ecosys_ng_zcu.obj)
    solveSoilHeatWaterAndSoluteTransportAttempt(...)
D:\ecosys-modernization\ecosys-ng\src\stages\hourly_process_driver.zig:727:65: 0x... in executeHourlyScience__anon_194142 (ecosys_ng_zcu.obj)
    try group_snow_energy.solveSnowSurfaceEnergyAndSoilTransport(...)
D:\ecosys-modernization\ecosys-ng\src\ecosys_ng.zig:7657:25: 0x... in advanceHour__anon_143622 (ecosys_ng_zcu.obj)
D:\ecosys-modernization\ecosys-ng\src\ecosys_ng.zig:8043:32: 0x... in runTimeline__anon_119117 (ecosys_ng_zcu.obj)
D:\ecosys-modernization\ecosys-ng\src\ecosys_ng.zig:14210:24: 0x... in main (ecosys_ng_zcu.obj)
```

Process exit code under `ReleaseSafe`: `3` (Zig's standard panic exit code), reproduced twice (once without the PDB present, giving unsymbolized `???:?:?` frames but the same `index out of bounds: index 64, len 64` panic message; once with `ecosys_ng.pdb` copied alongside the exe, giving the fully symbolized trace above). Both runs took ~5 minutes 51 seconds wall-clock to reach the crash, well inside a 15-minute per-run budget.

## Root cause (confirmed by direct source read, not inference)

`ecosys-ng/src/stages/hourly_heat_water_solute.zig`:

- **Line 2295**: `const maximum_transport_replay_substeps: usize = 64;` -- a hardcoded literal, independent of `recovery_substep_counts` (`heat_step.zig:483`). No `comptime` assertion or shared derivation ties it to the ladder's actual maximum, unlike the constants `issue-058` fixed (`maximum_bounded_recovery_substeps`, `stiff_heat_direct_recovery_substeps`).
- **Line 2325**: `time_step_hours: [maximum_transport_replay_substeps]f64 = @splat(0),` -- a fixed-length **inline array field** on the generic `TransportReplay`-shaped struct (`Self`), sized by that hardcoded `64`, not allocated at runtime.
- **Line 2324, 2338-2340**: `substep_capacity: usize` is a separate, *runtime* field, set via `validatedTransportReplaySubstepCapacity(exact_substep_count)` (lines 2300-2304), which validates only that `exact_substep_count` is a member of `recovery_substep_counts` -- it accepts **any** ladder member, including a newly added `128`, with no upper bound tied to `maximum_transport_replay_substeps`.
- **Lines 2519, 2653, 2669, 2683**: every write/read guard in this struct (`pendingSnapshot`, `beginSubstep`, `stageAcceptedFluxes`, `acceptSubstep`) checks `self.count >= self.substep_capacity` (or `std.debug.assert(self.count < self.substep_capacity)`) -- i.e. against the *dynamic, ladder-derived* capacity, not against `time_step_hours.len` (`maximum_transport_replay_substeps`). With the ladder extended to include `128`, `substep_capacity` can legitimately become `128`, so these guards all pass for `self.count` in `[64, 127]` -- and then **line 2663**, `self.time_step_hours[self.count] = time_step_hours;`, indexes a `[64]f64` array at an index up to `127`, which is exactly the panic observed (`index out of bounds: index 64, len 64`, the first overflow, at `self.count == 64`).

This is the same recurring defect *shape* `issue-058` named and fixed ("a substep-count-shaped constant hardcoded independently of `recovery_substep_counts`, with no mechanism forcing it to stay in step") -- but a **different, previously-unaudited consumer**. `issue-058`'s fix specifically closed the gap in `boundedRecoveryFallback`'s three named constants and the `minimum_freeze_flow_coupling_substeps` floor; it did not touch `TransportReplay`'s `time_step_hours` field, `maximum_transport_replay_substeps`, or `validatedTransportReplaySubstepCapacity`, none of which this issue's predecessor searched. Other array-shaped fields in the same struct (`accepted_values`, `accepted_surface_geometry_values`, `litter_soil_water_flux_m3`, allocated at lines 2387-2404 via `allocator.alloc(..., substep_capacity, ...)`) are correctly, dynamically sized to `substep_capacity` at construction time and are **not** affected -- `time_step_hours` is the only fixed-size inline array in this struct, which is why it alone overflows.

**Why `ReleaseFast` crashed silently instead of panicking**: `ReleaseFast` compiles out `index out of bounds` safety checks. The out-of-bounds write at `time_step_hours[64..127]` (a `[64]f64` = 512-byte inline array embedded in the larger `Self` struct) silently overwrites whatever struct fields/memory follow it, corrupting state that surfaces as an unrelated-looking `STATUS_ACCESS_VIOLATION` later rather than failing at the actual defect site -- consistent with `issue-015`'s observation that the log "simply stops" with no diagnosable message under `ReleaseFast`.

## What was ruled out (this pass and the prior pass, not re-litigated)

- `issue-015`'s addendum already ruled out the two `[64]`-sized traces in `solver_solve.zig:944` and `reaction_solve.zig:1496-1497` (both explicitly length-guarded via `if (trace_len < trace.len)` before every write, and indexed by Newton/Anderson iteration count, not substep count). Independently re-confirmed by this pass's own read of `solver_solve.zig:944,978-981` -- the guard is present and correct; not the cause.
- `minimum_freeze_flow_coupling_substeps` (`heat_step.zig:954`) was left untouched at its committed value (`4`) for this reproduction, exactly as in `issue-015`'s addendum -- confirming this is not a recurrence of `issue-024` round 7's original crash (which required raising that floor too).
- `issue-058`'s own fix (`boundedRecoveryFallback`, `maximum_bounded_recovery_substeps`, the two comptime membership guards) is confirmed working exactly as designed: the ladder correctly escalated to the new `128` tier and the production run entered real physics at that tier, which is precisely what let this second, independent defect get exercised.
- A broader grep of `heat_step.zig`, `hourly_heat_water_solute.zig`, `solver_solve.zig`, and `reaction_solve.zig` for other `[8]`-length arrays (matching the *old array's element count*, as opposed to its maximum *value*) found only test-only fixtures (`schedules: [4]u8`/`[3]u8`/`[2]u8` mock buffers in existing unit tests, already flagged as a separate test-only regression in `issue-015`'s addendum) and unrelated fixed-species arrays (`soil_mineral[8]`, mineral-species indices) -- none reachable from the production escalation path. The actual defect is sized to the ladder's old *maximum value* (`64`), not its old *element count* (`8`).

## Minimal reproducer

1. In `ecosys-ng/src/soil/water/heat_step.zig`, change line 483 from `pub const recovery_substep_counts = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64 };` to `pub const recovery_substep_counts = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64, 128 };` (single line, `u8`-safe, structurally clean per `issue-058`'s fix -- no other source edit needed to compile).
2. Build (cwd `ecosys-ng`, Zig 0.16.0): `zig build -Doptimize=ReleaseSafe`. (`ReleaseFast` reproduces the original silent access violation; `ReleaseSafe` is the recommended diagnostic substitution -- it keeps bounds-check safety like `Debug` while running close to `ReleaseFast` speed, so the ~2,579-hour replay finishes in well under the 15-minute per-run budget. A `Debug` build was not attempted this pass because it would very likely have exceeded that budget for a run this deep into the deck.)
3. Copy `ecosys-ng-bin/ecosys_ng.exe` (and, for a symbolized trace, `ecosys-ng-bin/ecosys_ng.pdb`) into an isolated copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON` (e.g. via `robocopy /E`).
4. From that isolated deck directory, run: `.\ecosys_ng.exe --execution-evidence <path> runottawa`.
5. Expected/observed result: reaches the hour-2,578/2,579 frontier, escalates through the ladder to the new 128-substep tier, then panics with `index out of bounds: index 64, len 64` at `hourly_heat_water_solute.zig:2663` (exit code `3` under `ReleaseSafe`; silent `STATUS_ACCESS_VIOLATION`/exit `-1073741819` under `ReleaseFast`).

## Disposition

Cause: **confirmed this pass**, by direct source read plus a bounded, successful diagnostic reproduction (see above). `maximum_transport_replay_substeps` (`hourly_heat_water_solute.zig:2295`) sizes the inline array field `time_step_hours` (`:2325`) independently of `recovery_substep_counts`, while the struct's own bounds guards check against the ladder-derived `substep_capacity` instead of against `time_step_hours.len` -- so extending the ladder past `64` makes those guards pass while the fixed buffer itself overflows.

Reachability: **not reachable under the presently committed source** (ladder capped at `64`, `maximum_transport_replay_substeps` also `64` -- the two values coincide today, exactly as `issue-058` described for its own now-fixed defect). This is dormant unless a future change extends `recovery_substep_counts` past `64` without also widening `maximum_transport_replay_substeps` (or restructuring `time_step_hours` to be allocated dynamically like its sibling fields `accepted_values`/`accepted_surface_geometry_values`/`litter_soil_water_flux_m3`).

Before/after results: n/a -- **no fix applied this pass**, per this pass's explicit diagnosis-only instruction (matching the caution already established for this solver-frontier area). The temporary one-line array edit used for reproduction was reverted immediately after the diagnostic run; `git status --short`/`git diff` at the end of this pass show zero changes under `ecosys-ng/` or anywhere else in the tracked repository.
Regression added and actually executed: none (diagnosis-only pass).
Invalidated evidence: none. `issue-015`'s addendum and `issue-058`'s own evidence stand unchanged; this issue adds a root-cause explanation for `issue-015`'s previously-unexplained crash, it does not contradict either.
Independent reviewer: not yet done.

Final disposition: **`unresolved`** -- root cause is now known and precisely located, but no fix has been designed, reviewed, or applied. A future fix should most likely either (a) widen `maximum_transport_replay_substeps` to be derived from `recovery_substep_counts`'s actual maximum (mirroring `issue-058`'s `maximum_bounded_recovery_substeps` fix exactly), with a comptime assertion tying the two together, or (b) allocate `time_step_hours` dynamically at construction time from `substep_capacity`, exactly like the struct's other three per-substep buffers already do -- decided by a reviewer, not unilaterally here, per this project's established caution around solver-schedule design changes in this exact area (`issue-015`, `issue-024`, `issue-058`). Extending `recovery_substep_counts` past `64` therefore remains unsafe until one of these is implemented and regression-tested; this issue is the concrete blocker for `issue-015`'s still-open convergence question (does the SOLUTE residual keep falling past 64 substeps?).
