# Issue 106 -- executable-root test 71 expects substep ladder {1,20,32,64}; code gives {4,20,32,64}

Status: **OPEN** (found in run-034, `audit/runs/issue-104-exe-root-full2/stderr-snapshot-before-stop.log`).

- Test: `stages/hourly_heat_water_solute.zig:10555` `fixed external hour recovery escalates through the full chain and stops on hard defects`. It asserts `expectEqualSlices(..., &.{ 1, 20, 32, 64 }, ...)` and observes `{ 4, 20, 32, 64 }`.
- History: the test dates from `514dd68` (initial import). `99234f1` "Implement Fortran wthr.f NFH=4 universal substep baseline (issue-024)" later raised the baseline. The test is in the executable root, which did not compile or run (issue-104), so it was never reconciled.
- Question: is NFH=4 the verified legacy baseline (`wthr.f`)? If yes, the expectation is stale and should cite `wthr.f`. If no, `99234f1` is the defect. Decide from legacy (f77query) before touching either. Do not relax the test to pass.

## Measured again 2026-10-15 (Zig 0.17 migration, cycle 00001) — worse than a stale expectation

`audit/runs/zig017-test-20261014-4/stdout.log`/`stderr.log` (Zig 0.17.0, `zig build test --cache-dir .zig-cache
--summary all`, 4518/4520 passed, 1 skipped, **1 crashed** — this test is that one crash). The executable root now
*compiles* under 0.17 (the `build.zig` `std.Build.args` passthrough removal), so this test body executes for what is
believed to be the first time, and it does not even reach the comparison: it panics inside the fixture.

- Now at `src/stages/hourly_heat_water_solute.zig:10676` (line drifted from the `:10555` cited above).
- `panic: index out of bounds: index 4, len 4` at `src/stages/hourly_heat_water_solute.zig:10686`
  `self.schedules[self.attempts] = substep_count;` — the fixture declares `schedules: [4]u8` (`:10678`) while
  `recoverFixedExternalHour` walks the whole ladder, which is **8** rungs:
  `pub const recovery_substep_counts = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64 };`
  (`src/soil/water/heat_step.zig:515`, already 8 rungs at `HEAD`/pre-migration, so this is not migration drift).
- So the 5th attempt (`16`) writes past the fixture array. The stale `{ 1, 20, 32, 64 }` expectation is a symptom; the
  fixture sizing was never reconciled with the ladder either.
- Migration decision: **untouched in this cycle** (the cycle's scope is the toolchain migration and it must not answer
  the legacy question below). The crash is carried as the single known crash in the G2 evidence, unchanged in
  behaviour, and is not counted as a migration regression: on 0.16 the step did not build, so nothing here got worse
  — one previously-unrunnable test step (120 tests, 119 now pass) is now running.
- What the fix will need (still gated on legacy): size the fixture from the ladder
  (`[recovery_substep_counts.len]u8`) and state the expectation the test name claims (every rung of the production
  ladder, in ladder order) — that is *stronger* than `{ 1, 20, 32, 64 }`, plus the separate `wthr.f` verdict on which
  ladder is legitimate. `src/soil/water/heat_step.zig:1044-1056` already cites `wthr.f:568-571` (`ICHKV`) and records
  that the purely reactive ladder was found structurally different from legacy; read that before deciding.

