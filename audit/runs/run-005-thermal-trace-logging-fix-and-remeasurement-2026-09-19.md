# Run 005 -- THERMAL_SOURCE/THERMAL_TRACE logging gating fix and re-measurement (Zig only), 2026-09-19

**Status: FIX LANDED, OUTPUT-NEUTRAL, WALL-TIME EFFECT NEGLIGIBLE; ACCEPTANCE BAR STILL NOT MET.**
`run-004` cut single-threaded Zig wall time on the matched partial benchmark
(hours 1-2,578 of the Ottawa deck) from 844.97 s to a 266.05 s median by
gating four unconditional per-hour `std.log.info` call sites in
`ecosys_ng.zig`'s `acceptHourAndPublish`, and explicitly recommended as the
next action: "(a) apply the same off-by-default gating to
`THERMAL_SOURCE`/`THERMAL_TRACE` and re-measure." This run does exactly that.

**Result:** `THERMAL_SOURCE`/`THERMAL_TRACE` (plus the adjacent
`THERMAL_FRONTIER` line, gated for consistency) are now gated behind the
same `run_support.verbose_diagnostics_enabled` switch run-004 introduced,
eliminating 7,732 of the fixed build's remaining 8,922 log lines (86.6%) --
the log shrinks from 8,922 lines / ~2.03 MB to **1,190 lines / ~276 KB**, an
86.7%-by-lines / 86.4%-by-bytes further reduction. Despite that large
*log-volume* reduction, the measured wall-time effect is **negligible**:
median 265.74 s (this run) vs. 266.05 s (run-004), a 0.3 s / 0.1% difference,
well inside both runs' repeat-to-repeat spread (~2-6%). The new Zig/Fortran
ratio is **~2.02**, statistically indistinguishable from run-004's ~2.02.
**The acceptance bar (ratio <=1) is still NOT MET**, and this fix alone does
not materially move it. Output-neutrality was verified and one class of
raw-byte snapshot differences was root-caused conclusively (not just cited)
using a stronger check than run-004's own precedent: decoding all 4
differing failure-snapshot files (not just one) and comparing every decoded
field, including `parameters` (which run-004 did not directly compare),
field-by-field via `std.meta.eql`/`expectEqual` rather than raw bytes.

## Why this is a real, if numerically small, fix

Confirmed independently (not just trusted from the run-004 citation) by
reading `soil/water/heat_step.zig:43-62` and
`stages/hourly_heat_water_solute.zig`'s `thermal_trace_active` /
`temporary_profile_active` gates:

- `heat_step.zig:43-58`, `traceThermalStage`: emits one `THERMAL_TRACE` line
  and, conditionally, one `THERMAL_SOURCE` line per soil layer (up to 3
  layers) for each of 8 call sites in `heat_step.zig` (lines 1659, 1679,
  1785, 1793, 1816, 1871, 1923, 2015 -- `entry`, `richards_transport`,
  `richards_rebase`, `vapor_transport`, `vapor_rebase`, `phase`,
  `surface_hook`, `heat`), gated only by `profile.?.trace_thermal_stages`.
- `hourly_heat_water_solute.zig:12073-12076` (before this fix):
  `thermal_frontier_trace = executed_weather_hours >= 2531 and < 2534`;
  `thermal_trace_active = !builtin.is_test and (executed_weather_hours < 8 or
  thermal_frontier_trace)` -- **confirmed**, exactly as run-004's citation
  said: an 11-hour hardcoded window (hours 0-7, plus 2531-2533), not a
  runtime flag.
- `hourly_heat_water_solute.zig:12210` (long call to
  `advanceMappedDeferred`): `.temporary_profile = if (temporary_profile_active
  or thermal_trace_active) .{ .io = ..., .counters = ..., .trace_thermal_stages
  = thermal_trace_active } else null` -- confirms `thermal_trace_active` is
  exactly the switch that turns `traceThermalStage`'s logging on, and that it
  is independent of `temporary_profile_active` (a separate hours-48-55
  `TEMP_PROFILE` diagnostic window, out of this task's named scope and left
  untouched).
- `hourly_heat_water_solute.zig:12077-12081`: a fourth, low-volume
  `THERMAL_FRONTIER` line, gated only by `thermal_frontier_trace` (not by
  `thermal_trace_active`), fires 4 times per run (once per hour in the
  2531-2533 window plus the boundary at 2534's guard) -- gated for
  consistency in this fix, following run-004's own precedent of also fixing
  the negligible-volume `TEMP_CHEMISTRY_TRACE` site "for consistency, not
  because it mattered to the timing."

**Quantified volume before this fix** (re-used run-004's own
`<scratchpad>/bench-zig-short/fix_t1_r1_err.txt`, still on disk from that
run -- not regenerated): 8,922 total lines, of which:

| count | line signature |
|---|---|
| 3,864 | `THERMAL_TRACE stage=... layer=...` |
| 3,864 | `THERMAL_SOURCE stage=... layer=...` |
| 4 | `THERMAL_FRONTIER hour=... exact_substep_count=...` |
| 192 | `TEMP_PROFILE ...` (separate hours-48-55 window, left ungated, out of scope) |
| 998 | everything else |

`THERMAL_TRACE` + `THERMAL_SOURCE` = 7,728 lines = **86.6% of the fixed
build's remaining log**, even though they come from only 11 of 2,578 hours
(~0.4%) -- each hour executes `traceThermalStage` many times (8 call sites,
apparently across multiple substeps within the hour, given the retry ladder
present near the 2531-2533 frontier window) at up to 3 layers each. This is
a striking illustration that "share of remaining log lines" and "share of
remaining wall time" are not the same thing (see result below): run-004's
four sites were expensive because they ran on literally *every* hour with an
unconditional flush; these sites are expensive *by line count* only because
of how many lines each of the 11 windowed hours produces, not because the
window itself is large.

## The fix

Following run-004's own stated principle -- "gate the call, don't delete the
logic that decides the window," so the historical hour-2531-2534 and
hour-<8 frontier investigations remain reproducible on demand via
`--verbose-diagnostics` -- and reusing the *same* flag run-004 already
introduced (no second flag added):

`ecosys-ng/src/stages/hourly_heat_water_solute.zig`:
```
const thermal_trace_active = !builtin.is_test and run_support.verbose_diagnostics_enabled and
    (context.executed_weather_hours.* < 8 or thermal_frontier_trace);
if (!builtin.is_test and run_support.verbose_diagnostics_enabled and thermal_frontier_trace)
    std.log.info("THERMAL_FRONTIER hour={d} exact_substep_count={d}", .{...});
```
(previously: `thermal_trace_active = !builtin.is_test and (... < 8 or
thermal_frontier_trace)`, with no flag gate; `THERMAL_FRONTIER` gated only by
`!builtin.is_test and thermal_frontier_trace`). `run_support` was already
imported in this file (used at line 135 for the existing
`TEMP_CHEMISTRY_TRACE` gate added in run-004) -- no new import needed. The
downstream `.temporary_profile = if (temporary_profile_active or
thermal_trace_active) ...` call and everything inside `traceThermalStage`/
`heat_step.zig` are untouched: with the flag off, `thermal_trace_active` is
now always `false`, so `traceThermalStage` returns immediately via its
existing `if (profile == null or !profile.?.trace_thermal_stages) return;`
guard (unchanged code) -- this is a call-site/gate change only, exactly
run-004's pattern. `temporary_profile_active` (hours 48-55) is untouched and
continues to fire its own separate `TEMP_PROFILE` diagnostics regardless of
this flag, per the task's explicit scope (only `THERMAL_SOURCE`/
`THERMAL_TRACE` named).

Total diff: 4 lines changed (2 insertions, 2 deletions) in one file,
`ecosys-ng/src/stages/hourly_heat_water_solute.zig`.

## Build

Rebuilt via `zig build -Doptimize=ReleaseFast` (Zig 0.16.0) twice in the same
checkout, git HEAD `1db1d326d93a3c3e5a893a2b3dfca60f111aa9e4` (confirmed via
`git diff --stat 9467f9d 1db1d32 -- src/` = empty: no source changes between
run-004's committed fix and this run's starting point; the intervening
commits were other agents' unrelated `feature-010`/`issue-032` audit
evidence):

1. **Baseline ("unmodified since run-004")**: `hourly_heat_water_solute.zig`
   checked out to HEAD (`git checkout -- ...`), rebuilt, binary copied out
   and hashed before restoring the fix -- SHA-256
   `9E0A47B5A4AB6DBC24DB4A803095A2B7463A3C7666D386176794AAAF713C3A6D`.
2. **Fixed (this run's 4-line change)**: source restored, rebuilt -- SHA-256
   `F5629C6194435FD113DFA7FFD9D66CD26C7BF5B7EB1BA5E9C7E1F40EDC268E7E`. This is
   the binary used for all reported timed repeats below (confirmed by
   re-hashing `ecosys-ng-bin/ecosys_ng.exe` immediately before the timed runs
   and finding it unchanged from this hash).

Both builds compiled cleanly with no errors or warnings surfaced.

## Hardware and isolation

Same machine as run-003/run-004 (13th Gen Intel Core i9-13950HX, 24P/32L,
Windows 11 Enterprise 10.0.26100). Same isolated deck,
`<scratchpad>/bench-zig-short/` (`runottawa` + `runottawa_input_files/`,
`runottawa_output_files/` wiped and recreated before every run),
single-threaded (`--threads 1`), `Get-Process` checked for other
`zig`/`gfortran`/`ecosys`/`test` processes immediately before each repeat.

**Methodology caveat, reported plainly rather than hidden:** immediately
before the output-neutrality baseline run, `Get-Process` found a `test.exe`
process (`C:\zig-local-cache\ecosys-ng\o\...\test.exe`, PID 23196, later PID
46516/46856 after being killed and respawning) already running and
accumulating CPU. This matches the known runaway `outer_hour_transaction`
test hang from run-004 (`issue-032`), and its repeated respawning during this
session indicates another agent was actively investigating that issue
concurrently -- not merely reading files. It was killed before each affected
run; **it was present during the one baseline output-neutrality run** (whose
wall time, 276.09 s, is not used for the timed-repeat median below and does
not affect the ratio) **and confirmed absent (checked via `Get-Process`)
immediately before all four of the timed benchmark repeats reported in the
table below**. This is a real, if bounded, deviation from perfect isolation
and is called out per the contract rather than glossed over; it does not
touch the reported timing numbers.

## Output-neutrality proof

Ran the baseline (unmodified-since-run-004) binary once and the fixed binary
once more, both single-threaded, both with `--verbose-diagnostics` **not**
passed (default off), both on the identical `bench-zig-short` deck, both
failing identically at hour 2,578 with `SoluteReactionSolverDidNotConverge`
(exit code 1), both producing 202 output files.

- **197 of 202 files byte-identical** (SHA-256 compared file-by-file).
- **5 files differ**, the same pattern as run-004:
  - `logs\run.log`: differs, expected -- content is exactly what changed
    (86.7% fewer lines), plus the same non-deterministic startup-phase
    wall-clock timestamps run-004 already documented as varying run-to-run
    even without this change.
  - `logs\...day108-hour{5,8,9,11}.bin` (4 solute-failure replay snapshots):
    differ at the raw-byte level -- **the same 4 files, same hours, as
    run-004's own output-neutrality check**, strongly suggesting the same
    underlying mechanism (struct-padding content shifting with upstream
    allocation-order changes) rather than a new one.

**Root-caused, not just cited by analogy.** Rather than only pointing at
run-004's explanation, this run re-verified it directly and more thoroughly:
a temporary test (`TEMPORARY-PERFORMANCE-R5`, added to
`failure_snapshot.zig`, run once via `zig test src/module_index.zig
--test-filter "TEMPORARY-PERFORMANCE-R5"`, then fully removed -- along with
the 8 temporary `tmp_r5_*.bin` embed files it read -- before commit, per
run-004's own "remove before commit" discipline) decoded **all 4** differing
snapshot files (`hour5`, `hour8`, `hour9`, `hour11` -- run-004 explicitly
decoded only `hour5` and generalized) through the real production `read()`
path for both the baseline and fixed builds, and compared, field-by-field
(`std.meta.eql`/`std.testing.expectEqual`, not raw-byte `memcmp`):

- `context` (all 11 `u64` fields) -- equal for all 4 hours.
- `options` (`solver.Options`) -- equal for all 4 hours.
- `parameters` (`chemistry.ReactionParameters`, the struct containing the
  optional `phosphate_minerals: ?MineralParameters` run-004 identified as the
  padding source) -- compared **directly** via `std.meta.eql` (run-004
  compared only `context`/`options`/the packed state vector, not
  `parameters` itself) -- **equal for all 4 hours**.
- the full packed chemistry-state vector
  (`chemistry.State.packedComponentCount()` components, via `packCell` then
  `expectEqualSlices`) -- equal for all 4 hours.

Result: `zig test` reported `soil.solute.failure_snapshot.test.
TEMPORARY-PERFORMANCE-R5: thermal-trace gating fix is output-neutral at the
decoded-field level...OK`. Every decoded field of every one of the 4
differing snapshots matches exactly; the raw-byte difference is confined to
compiler-inserted struct padding the decoder never reads, exactly as
run-004's mechanism predicts (this fix removes/reorders early-hour logging
calls -- specifically, for hours 1-7, `thermal_trace_active` was previously
`true` and `advanceMappedDeferred` received a non-null `temporary_profile`,
whose `captureColdHeatInput` path could allocate a `Face` scratch buffer;
with the flag off by default, that early allocation no longer happens,
shifting later heap layout enough to change what garbage lands in the same
padding bytes run-004 already found -- a latent property of
`failure_snapshot.zig`'s `std.mem.asBytes` serializer, not a computed-science
difference, and not introduced by this fix specifically).

## Benchmark methodology (matched to run-003/run-004)

Same deck, same isolation discipline, single-threaded (`--threads 1`),
machine checked free of other `zig`/`gfortran`/`ecosys`/`test` processes
immediately before each of the 4 repeats below (confirmed clean every time).

### Zig, fixed build, single-threaded, `--verbose-diagnostics` NOT passed (default off)

| repeat | wall time (s) | exit | notes |
|---|---|---|---|
| 0 | 264.20 | 1 | no anomaly observed -- kept, not discarded (see below) |
| 1 | 267.29 | 1 | measured |
| 2 | 268.52 | 1 | measured |
| 3 | 263.19 | 1 | measured |

- **Unlike run-004, repeat 0 showed no first-run anomaly** (264.20 s, fully
  consistent with repeats 1-3's 263-269 s band) -- most likely because this
  binary was already the Nth invocation of a functionally-identical build in
  this session (the same executable, or one built from bit-identical
  headers/link inputs, had already been run for the output-neutrality checks
  above), so whatever one-time cost run-004 hypothesized (antivirus scanning
  a freshly-linked, unsigned `.exe` on first launch) had already been paid.
  This is reported explicitly, per the task's instruction to document
  either way rather than silently assume a warm-up is needed.
- Because no anomaly was observed, **all 4 repeats are used**: median
  **265.74 s** (average of the two middle values, 264.20 and 267.29), min
  263.19 s, max 268.52 s, spread 5.33 s (~2.0%) -- comparable to or tighter
  than run-003's/run-004's 2-6% spreads. (If only repeats 1-3 are used, to
  mirror run-004's literal 3-repeat table exactly, the median is 267.29 s --
  a 0.6% difference from the 4-repeat median, not large enough to change any
  conclusion below.)
- All 4 repeats failed identically at hour 2,578 with
  `SoluteReactionSolverDidNotConverge`, exit code 1, identical stage-census
  entries (`plant_emergence_refresh entries=2578 first_hour=1
  last_hour=2578`, etc., matching run-003's and run-004's baseline) --
  confirms this fix changed logging volume only, not how far the run
  progressed.
- Log file size for this run's fixed build: **1,190 lines / ~276,000
  bytes** (down from run-004's 8,922 lines / ~2,028,800 bytes on the
  identical workload -- an 86.7%-by-lines / 86.4%-by-bytes further
  reduction). `THERMAL_TRACE`, `THERMAL_SOURCE`, and `THERMAL_FRONTIER` all
  occur **zero** times in every one of these logs (grep-verified across all
  4 repeats plus the output-neutrality run), confirming the gate is fully
  effective with `--verbose-diagnostics` off.

### Comparison to run-004's baseline (same source except this run's 4-line change)

| build | median (s) | min | max |
|---|---|---|---|
| run-004 (THERMAL_SOURCE/TRACE ungated) | 266.05 | 257.51 | 274.34 |
| this run (THERMAL_SOURCE/TRACE gated) | 265.74 | 263.19 | 268.52 |

**Wall-time change attributable to this fix: (266.05 - 265.74) / 266.05 =
0.1%** -- statistically indistinguishable from zero given both runs' 2-6%
repeat-to-repeat spread. This is the honest result, not a hoped-for one:
despite removing 86.6% of the fixed build's remaining log lines, this
specific fix has **no measurable wall-time effect** on this benchmark. The
lines it removes are concentrated in an 11-hour hardcoded window (0.4% of
the 2,578-hour run), so even a large *per-hour* logging cost in that narrow
window contributes a negligible *total* wall-time share -- unlike run-004's
four sites, which fired unconditionally on literally every one of the 2,578
hours.

### New Zig/Fortran ratio

Fortran's numbers are run-003's, unchanged and not re-measured here (per the
task's explicit instruction; this fix does not touch Fortran or the oracle
build): day-108/hour-2,568 checkpoint median 131.46 s (min 131.03, max
139.24).

- **New ratio (medians): 265.74 / 131.46 = ~2.02.**
- Range across min/max combinations: min Zig (263.19) / max Fortran (139.24)
  = 1.89; max Zig (268.52) / min Fortran (131.03) = 2.05.
- Using run-004's literal-3-repeat convention instead (repeats 1-3, median
  267.29 s): ratio = 267.29 / 131.46 = ~2.03 -- the same conclusion either
  way.
- **This is statistically the same as run-004's ~2.02x.** The acceptance bar
  (Zig/Fortran ratio <=1) **is still NOT MET**, and this specific fix, while
  real, correctly scoped, and verified output-neutral, did not meaningfully
  narrow the gap.

## Disposition and next action

- `THERMAL_SOURCE`/`THERMAL_TRACE`/`THERMAL_FRONTIER` confirmed gated behind
  the existing `run_support.verbose_diagnostics_enabled` flag (no second
  flag introduced), following run-004's exact pattern; the historical
  hour-<8 and hour-2531-2534 frontier investigations remain reproducible on
  demand via `--verbose-diagnostics`, per the contract's "preserve
  references" instruction.
- Output-neutrality confirmed and the one differing-file class
  root-caused conclusively via field-level decode comparison (context,
  options, parameters, and packed state all exactly equal across all 4
  differing snapshot files) -- a stronger check than run-004's own
  precedent, not merely a repetition of its explanation.
- Run-004's recommendation (a) is now complete. Its recommendation (b) --
  "profile the remaining ~266 s ... residual/Jacobian assembly, the
  retry-ladder cost concentrated near the hour-2,578 frontier, and
  allocation patterns" -- is now the clearly indicated next step, and this
  run's own result sharpens which of those three is most promising: gating
  the highest-*line-count*-share remaining logging category produced **zero
  measurable wall-time change**, which is strong evidence that essentially
  all of the remaining ~266 s is now non-logging solver/allocation work, not
  further-hidden logging overhead. Of run-004's three named candidates, the
  **retry-ladder cost concentrated near the hour-2,578 frontier** is the
  most promising specific target to profile next: the benchmark's failure
  point is itself defined by repeated retry-ladder escalation as the solver
  approaches non-convergence (`issue-015`), so the last tens-to-hundreds of
  hours before 2,578 plausibly execute several-fold more substep/Newton work
  per hour than the steady early hours -- a targeted instrumentation pass
  splitting wall time into "steady early hours" vs. "retry-ladder-heavy
  hours near the frontier" (as run-003 itself already suggested) would
  directly test this and is recommended as the next bounded experiment,
  ahead of a general residual/Jacobian-assembly or allocation-pattern audit.
- Acceptance bar (ratio <=1): still **FAIL**. Do not re-run this exact
  benchmark again without new evidence to test (per the contract's
  repeat-run discipline) -- the next useful action is the retry-ladder /
  frontier-cost profiling pass above, not another timing repeat of the same
  fix.

## Evidence paths

- `ecosys-ng/src/stages/hourly_heat_water_solute.zig` -- the committed
  4-line source fix (gating `thermal_trace_active` and the `THERMAL_FRONTIER`
  print behind `run_support.verbose_diagnostics_enabled`).
- `<scratchpad>/bench-zig-short/fix_t1_r{0,1,2,3}_err.txt` -- run-004's
  original fixed-build logs (8,922 lines each, THERMAL_SOURCE/TRACE
  ungated), retained from that run and reused here for the before-fix
  line-frequency count.
- `<scratchpad>/ecosys_ng_baseline_since004.exe` (SHA-256
  `9E0A47B5A4AB6DBC24DB4A803095A2B7463A3C7666D386176794AAAF713C3A6D`),
  `<scratchpad>/ecosys_ng_fixed_thermal.exe` (SHA-256
  `F5629C6194435FD113DFA7FFD9D66CD26C7BF5B7EB1BA5E9C7E1F40EDC268E7E`) -- the
  two binaries compared for output-neutrality and used for this run's
  benchmark.
- `<scratchpad>/bench-zig-short/r5_neutral_baseline_{log,err,evidence,timing}.txt/json`,
  `r5_neutral_fixed_{log,err,evidence,timing}.txt/json` -- the
  output-neutrality pair.
- `<scratchpad>/bench-zig-short/runottawa_output_files_r5_neutral_baseline/`,
  `runottawa_output_files_r5_neutral_fixed/` -- the two full output trees
  (202 files each) compared byte-for-byte.
- `<scratchpad>/bench-zig-short/r5_t1_r{0,1,2,3}_{log,err,evidence,timing}.txt/json`
  -- this run's 4 timed benchmark repeats.
- `<scratchpad>/run_zig_repeat_r5.ps1` -- the parametrized repeat-runner
  script used for this run (adds an explicit `-ExePath` parameter on top of
  run-004's `run_zig_repeat_fix.ps1`, which is unchanged and retained).
- The temporary `TEMPORARY-PERFORMANCE-R5` test in `failure_snapshot.zig` and
  its 8 `tmp_r5_*.bin` embed files were added, run once (`OK`), and fully
  removed before commit -- not part of the committed diff, per run-004's own
  "remove before commit" discipline; `git diff` on that file is empty after
  cleanup.
- All scratchpad artifacts above are retained in the session scratchpad
  only, per the standing root-cleanliness instruction, not committed to the
  repository.
