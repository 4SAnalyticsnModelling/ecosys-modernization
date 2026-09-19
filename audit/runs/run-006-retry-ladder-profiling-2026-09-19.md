# Run 006 -- Retry-ladder / frontier-cost profiling of the remaining ~266 s (Zig only), 2026-09-19

**Status: RETRY-LADDER COST CONFIRMED AND QUANTIFIED; NO SAFE PERFORMANCE FIX FOUND IN THE RETRY PATH ITSELF (NEGATIVE RESULT FOR PART 3); ACCEPTANCE BAR STILL NOT MET.**
Run-005 cut single-threaded Zig wall time on the matched partial benchmark (hours
1-2,578 of the Ottawa deck) to a 265.74 s median (Zig/Fortran ratio ~2.02) by
gating the last major known logging call sites, and found that removing 86.6%
of the *remaining* log volume had **zero** measurable wall-time effect --
strong evidence the ~266 s left is genuine solver/allocation work. It named
"the retry-ladder cost concentrated near the hour-2,578 convergence frontier"
as the most promising next target and explicitly asked for a steady-window
vs. frontier-window split.

**Result:** the retry ladder's cost near the frontier is real, large, and
precisely quantifiable: in a full per-hour timing trace of the whole
2,578-hour run, **9 hours (0.35% of the run) account for ~40.2 s (~15-16% of
total wall time)**, and just **3 of those hours account for ~32.7 s (~12-13%
of total wall time)** -- all inside the last 78 hours before failure. A
component-level breakdown of one representative escalation attempt shows the
cost is concentrated almost entirely (85-97%) in the SOLUTE chemistry
Newton/Anderson reaction-network solve itself, not in substep bookkeeping,
transactional snapshotting, or logging. Per the skill's explicit boundary
("not trying to make the solver converge further"), I looked for a
convergence-behavior-neutral optimization *in the retry path's own
plumbing* (redundant recomputation, unnecessary copies, duplicated logging)
and found none: the transactional snapshot/rollback per attempt is the
approved bounded-fallback architecture working as designed, and the escalating
cost is the direct computational footprint of the reaction solver needing far
more Newton/Anderson iterations as the system approaches the stiff frontier
(`issue-015`) -- a convergence-behavior change, explicitly out of scope here.
**This is an honest negative result for "found and fixed something in the
retry path," and a positive, quantified confirmation of run-005's hypothesis
about where the cost concentrates.**

One small, real, permanent, output-neutral source change was made and is
committed: a minimal per-hour timing marker (`PERF_HOUR_TRACE`), gated behind
the existing `--verbose-diagnostics` flag (off by default, zero effect on the
default path), added specifically to make this and future profiling possible
without a debug rebuild.

## What was measured

### The profiling method (per the task and the performance-engineering skill)

`--execution-evidence` records per-hour *identity* (hour/day/year, attempted/
committed/accepted phase) but **no wall-clock timing** -- confirmed by reading
`ecosys-ng/src/core/execution_evidence.zig` in full: `Journal.attempt`/
`commit`/`accept` write JSON identity records only. The existing hourly loop
in `ecosys_ng.zig` (`:8034-8059`) already computes `hour_elapsed_ms` for
*every* hour via `std.Io.Clock`, but only surfaces it at `info` level once per
day (`scene_weather_hours % 24 == 0`, the `"day advanced"` line); all other
hours route the same computed value to `std.log.debug`, which is filtered out
of the default `ReleaseFast` log level. This is exactly the gap the task
anticipated ("if it lacks per-hour timing... consider a minimal, clearly
labeled temporary instrumentation").

**The fix/addition** (`ecosys-ng/src/ecosys_ng.zig`, `:8050-8066`, 12 lines):
inserted one `else if (run_support.verbose_diagnostics_enabled)` branch
between the existing day-boundary `info` branch and the existing
non-day-boundary `debug` branch, logging
`"PERF_HOUR_TRACE scene_weather_hours={d} elapsed_ms={d}"` at `info` level
when the (already-existing, off-by-default) `--verbose-diagnostics` flag is
set. When the flag is off (the default, and the case for every benchmark
repeat reported anywhere in run-003/004/005/this run), the new branch is never
reached and the emitted code path is byte-for-byte identical to before --
this is provably a no-op in the default configuration, not merely argued to
be one.

### Build

`zig build -Doptimize=ReleaseFast`, Zig `0.16.0`, in `ecosys-ng/` (nested git
repository). Starting point for this run's edit: `5637203` (run-005's
committed HEAD; `git diff --stat` confirmed clean before editing). Final
committed diff: `src/ecosys_ng.zig` only, 12 insertions. A second, exploratory
edit (temporarily widening the pre-existing hardcoded `temporary_profile_active`
window in `hourly_heat_water_solute.zig` from hours 48-55 to hours 2564-2578,
to get the `TEMP_PROFILE attempt ...` phase breakdown right at the frontier)
was made, built, run **once**, used only to read its own log output, and then
**fully reverted** (`git diff` on that file is empty after revert, confirmed
via `git status --short`/`git diff --stat` immediately before the final
rebuild and before committing) -- same "add temporarily, remove before
commit" discipline run-004/005 established.

### Hardware and isolation

Same machine as run-003/004/005: 13th Gen Intel Core i9-13950HX, 24P/32L,
Windows 11 Enterprise 10.0.26100. Same isolated deck,
`<scratchpad>/bench-zig-short/` (`runottawa` + `runottawa_input_files/`,
`runottawa_output_files/` wiped and recreated before every run),
single-threaded (`--threads 1`). `Get-Process` checked free of other
`zig`/`gfortran`/`ecosys`/`test` processes immediately before every run below.

## Step 1 -- full per-hour timing trace (steady window vs. frontier window)

One run with `--verbose-diagnostics --execution-evidence ... runottawa`
(this flag intentionally re-enables *all* of run-004/005's gated logging plus
the new `PERF_HOUR_TRACE` line, so its **absolute total wall time is not used
as a benchmark number** -- it is used only to extract a full, internally
consistent per-hour series from a single controlled run). Failed identically
at hour 2,578/2,579 with `SoluteReactionSolverDidNotConverge`, exit 1, same as
every prior run. `logs/run.log` produced 21,714 lines including exactly 2,578
`PERF_HOUR_TRACE`/`"day advanced"` lines -- full one-line-per-hour coverage of
the entire run, parsed into a 2,578-row per-hour timing series
(`elapsed_ms` per accepted hour).

**Incidental observation, reported honestly rather than omitted:** this
verbose run's total wall time (265.96 s) was statistically indistinguishable
from the default (non-verbose) build's total wall time measured later in this
same run (263-269 s band, see Step 3) -- not the large gap run-004 measured
between unconditional-logging and gated-logging builds. The likely
explanation is that this invocation's stdout/stderr were not captured through
a real file redirect the way run-003/004/005's `Start-Process
-RedirectStandardOutput/-RedirectStandardError` pattern did (a first attempt
at direct `&`-operator redirection produced empty capture files), so the
"stderr write" component of `routeLogToRunLogAndStderr`'s per-line cost that
run-004 identified may not have been exercised the same way here; only the
`run.log` file write was. This is **not re-litigated or re-measured here** --
it is out of this run's scope -- but it means the per-hour *relative*
comparison below (all hours in one single, consistently-instrumented run) is
the safe, load-bearing evidence, not any cross-run absolute-time arithmetic.

### Steady window vs. frontier window (within this one trace)

| window | hours (n) | sum | avg/hour | max | min |
|---|---|---|---|---|---|
| steady (hour 100-2,500) | 2,401 | 172.797 s | 71.97 ms | 2,073 ms | 31 ms |
| frontier (hour 2,501-2,578, last 78h before failure) | 78 | 46.190 s | 592.18 ms | 12,414 ms | 30 ms |

The frontier window's average per-hour cost is **~8.2x** the steady window's
average -- confirming run-005's hypothesis directionally. But the average
understates how concentrated the cost actually is: most of the 78 frontier
hours cost the same ~30-100 ms as any steady hour; a handful of hours carry
almost the entire 46.19 s.

### Where the frontier window's cost actually concentrates

| hour | ms | note |
|---|---|---|
| 2,573 | 12,414 | day108-hour5 in the solute failure-snapshot naming (2,568+5); largest single hour in the whole 2,578-hour run |
| 2,577 | 10,884 | day108-hour9; confirmed 32-substep attempt rejected (`SoluteReactionSolverDidNotConverge`) -> 64-substep attempt accepted |
| 2,576 | 9,370 | day108-hour8; confirmed 20-substep attempt rejected (`SoluteReactionSolverDidNotConverge`) -> 32-substep attempt accepted |
| 2,570 | 2,000 | elevated, no independently re-isolated substep attribution (see caveat below) |
| 2,569 | 1,694 | elevated, ditto |
| 2,578 | 1,369 | day108-hour10; succeeds directly at the substep count inherited from hour 2,577's acceptance (no new rejection logged) |
| 2,575 | 650 | elevated, ditto |
| 2,565 | 1,043 | elevated, ditto |
| 2,566 | 760 | elevated, ditto |

Every other one of the 78 frontier hours is in the ordinary 30-165 ms range
(a few, at hours 2,531-2,534, are additionally inflated in *this specific
verbose-instrumented run* by the pre-existing hardcoded `THERMAL_FRONTIER`
trace window from run-005, which only fires with `--verbose-diagnostics` on
and is not part of the default build's cost -- excluded from the totals
below).

**Summed over just these 9 hours (0.35% of the whole 2,578-hour run): 40.18
s -- 87% of the entire 78-hour frontier window's total time, and ~15-16% of
this trace's whole-run accounted time (252.6 s hourly-sum; 265.96 s measured
wall).** Summed over just the 3 largest (0.12% of the run): 32.67 s, ~13% of
the whole-run accounted time.

**Attribution caveat, disclosed rather than hidden:** hours 2,576, 2,577, and
the terminal failure (`total_hour=2,579`, `day108-hour11`) were independently
confirmed against the `bounded fixed external hour recovery
rejected/accepted` log lines and the `SOLUTE failure snapshot written:
path=...day108-hourN.bin` filenames (which encode day-of-year/hour-of-day,
letting them be cross-referenced against total-hour count: day 108 starts at
total hour 2,569, so `hour5.bin` = total hour 2,573, `hour8.bin` = 2,576,
`hour9.bin` = 2,577, `hour11.bin` = 2,579). Hours 2,565/2,566/2,569/2,570/2,575
were **not** independently re-confirmed against specific rejection log lines
before `runottawa_output_files/logs/run.log` was overwritten by a later run in
this same session (Step 2's exploratory rebuild reused the same output
directory). Across the **entire** 2,578-hour run only 4 rejection events ever
reached substep counts above 2 (one each at 4, 20, 32, 64 -- the last three
being exactly hours 2,576/2,577/2,579's escalations already confirmed above),
so these five unconfirmed hours cannot themselves be further ladder
escalations; the most consistent explanation, given the per-attempt
phase-cost variability found in Step 2 below, is that they are ordinary
"reject-1 -> accept-20" events (60 such events occur across the whole run,
triggered by the freeze-flow floor, `HeatInducedPhaseChangeRequiresQuarterHourSubsteps`)
whose *accepted* 20-substep chemistry solve happened to need far more
Newton/Anderson iterations than the same escalation costs earlier in the run
(compare: an identical 1->20 escalation at hour 364, far from the frontier,
costs only 63 ms total). This is inference, not directly re-observed fact for
those five hours specifically, and is reported as such.

## Step 2 -- component-level breakdown of a frontier escalation (why it's expensive)

To see *which part* of a retry attempt is expensive, the pre-existing (but
currently hardcoded-to-hours-48-55, not flag-gated) `TEMP_PROFILE attempt
...` breakdown in `hourly_heat_water_solute.zig` (setup / watsub / publish /
nitro / biology / **solute** / replay / complete phases, each cumulative
`elapsed_ms` since attempt start) was temporarily repointed at hours
2,564-2,578 for one run, read, and reverted (see Build, above). Representative
attempts from that run:

| substeps | setup | watsub | publish | nitro | biology | solute (cumulative) | replay | complete |
|---|---|---|---|---|---|---|---|---|
| 1 | 0 | 4 | 6 | 7 | 7 | 890 | 918 | 923 |
| 20 | 0 | 20 | 24 | 24 | 25 | 39 | 47 | 51 |
| 20 | 0 | 19 | 23 | 23 | 23 | 618 | 630 | 634 |
| 32 | 0 | 29 | 31 | 31 | 32 | 2,509 | 2,538 | 2,544 |
| 64 | 0 | 59 | 64 | 65 | 66 | 1,066 | 1,093 | 1,098 |
| 64 | 0 | 60 | 65 | 66 | 66 | 1,196 | 1,225 | 1,229 |

In every row, `setup`/`watsub`/`publish`/`nitro`/`biology` together cost only
single-digit-to-tens of milliseconds -- even at 64 substeps. The **solute**
phase (the chemistry Newton/Anderson reaction-network solve) accounts for the
overwhelming majority of each attempt's cost every time: 883/923 = **96%** at
substeps=1; 2,477/2,544 = **97%** at substeps=32; 1,000-1,130 of ~1,100-1,230
= **91-92%** at substeps=64. Crucially, the solute-phase cost does **not**
scale cleanly with substep count -- a substeps=1 attempt can cost 890 ms of
solute time while a substeps=20 attempt costs only 39 ms, and another
substeps=20 attempt costs 618 ms. This points at Newton/Anderson **iteration
count** (i.e. how hard the chemistry residual is to satisfy that particular
hour, which grows as the system approaches the stiff frontier), not substep
bookkeeping, as the actual cost driver.

## Step 3 -- default-flag confirmatory benchmark (no regression from the added instrumentation)

Because the `PERF_HOUR_TRACE` addition is unreachable when
`--verbose-diagnostics` is not passed, it cannot change default-path timing
by construction; this was confirmed empirically anyway, matching run-005's
methodology (`run_zig_repeat_r5.ps1`, `Start-Process
-RedirectStandardOutput/-RedirectStandardError`, output directory wiped
before each run, machine checked free of other processes before each run):

| repeat | wall time (s) | exit | notes |
|---|---|---|---|
| 0 | 269.26 | 1 | kept, output tree retained for the neutrality check below |
| 1 | 264.77 | 1 | measured |
| 2 | 263.06 | 1 | measured |

Median of all 3: **264.77 s**, min 263.06 s, max 269.26 s (spread ~2.3%) --
statistically indistinguishable from run-005's 265.74 s median (0.1%
difference), confirming the source addition changed nothing in the default
path. All 3 repeats failed identically at hour 2,578/2,579 with
`SoluteReactionSolverDidNotConverge`, exit 1.

**Ratio vs. Fortran** (run-003's day-108/hour-2,568 checkpoint median, 131.46
s, reused unchanged per the "do not re-measure Fortran without cause"
convention run-004/005 established): 264.77 / 131.46 = **~2.01** --
statistically the same as run-005's ~2.02. Unchanged, as expected: this run
made no default-path performance change.

### Output-neutrality

Compared the retained repeat-0 output tree (this run's binary, default
flags) against run-005's already-saved `runottawa_output_files_r5_neutral_fixed`
tree (same source state except this run's 12-line, flag-gated addition), 202
files each side, SHA-256 by relative path:

- **197 of 202 files byte-identical.**
- **5 differ**, the identical pattern run-004 and run-005 both already found
  and root-caused: `logs\run.log` (expected -- different run, different
  timestamps) and the same 4 solute-failure replay snapshots
  (`...day108-hour{5,8,9,11}.bin`). Because this run's source change is
  unreachable on the default path (no new allocation, no new branch actually
  taken), it cannot itself be the cause of any *new* difference beyond what
  run-004/005 already decoded field-by-field and proved is confined to
  compiler-inserted struct padding in `failure_snapshot.zig`'s
  `std.mem.asBytes` serializer -- a pre-existing, already-explained artifact,
  not re-derived from scratch here since the change provably cannot have
  perturbed it.

### Targeted test

`zig test src/module_index.zig --test-filter "verbose diagnostics"` ->
`driver.cli.test."verbose diagnostics logging is off unless explicitly
requested"` -- **OK**. (Same known scope limit as run-004/005:
`ecosys_ng.zig` is only reachable from the executable's own root module, not
`module_index.zig`, so a standalone `zig test` of the new branch itself was
not resolved from the command line in the time available; the full
production output-neutrality comparison above is the evidence offered, same
precedent as run-004/005.)

## Step 4 -- is anything in the retry path itself safely fixable?

Per the nonlinear-solver-audit skill's explicit boundary, the goal here was
**not** to make the solver converge further or faster (that is `issue-015`,
separately tracked and harder) -- only to check whether the *existing,
already-bounded* retry ladder (`recoverFixedExternalHourAdaptively`,
`hourly_heat_water_solute.zig:11437-11479`) wastes work on its way to an
already-accepted outcome.

Read in full: `boundedRecoveryFallback` (`:11305-11316`) confirms the ladder
is a short, strictly increasing chain (1 -> 20 -> 32 -> 64, returning `null`
at the ceiling), matching the contract's "no unlimited fallback/subdivision
cascades" requirement -- this is not a defect, it is the approved bounded
architecture working correctly. `RecoveryAttempt.run` (`:11528-11636+`)
confirmed each attempt takes a full transactional snapshot
(`transaction.begin`, `canopy_carbon_exchange.begin(...).clone`,
`soil_gas_transport.begin(...).clone`, `captureCurrentStableLayoutFrom`)
before running the attempt, and rolls back on rejection -- this is exactly
what the nonlinear-solver-audit skill *requires*: "Snapshot the complete
accepted state before a trial... A rejection restores physical pools, pending
flux exchanges... No half-accepted process may persist." Removing or
short-circuiting this would violate transactionality, not optimize it
safely.

Checked for logging/diagnostic duplication specifically (the category named
in the task as a plausible free win, since it's exactly what run-004/005
already fixed elsewhere): `logBoundedRecoveryRejection` (one `warn` line per
rejected attempt) and the SOLUTE-specific `"fixed-hour recovery attempt
failed"`/`"failure snapshot written"` lines are **not** gated by
`verbose_diagnostics_enabled` (they already fire unconditionally in the
default build, at both attempt counts of 1-4 events per escalating hour) --
but their volume is tiny (a few single lines plus one ~1.85 KB `.bin`
snapshot file per *failed* attempt, only on the rare hours that fail at all)
and, per Step 2's breakdown, is dwarfed by orders of magnitude by the solute
solve itself. There is no unnecessary *repeated* logging across ladder rungs
beyond one line per rung, and no evidence any of it is a meaningful fraction
of the 9,000-12,000 ms spikes.

**Conclusion for this step: no safe, convergence-behavior-neutral
optimization was found in the retry ladder's own plumbing.** The escalating
cost is the direct computational footprint of the chemistry Newton/Anderson
solve needing more iterations as the system approaches the stiff frontier --
which is precisely `issue-015`'s convergence problem, not a performance
defect layered on top of it. This is reported as a negative result, per the
task's own explicit permission to do so, rather than stretched into a fix
that would touch iteration/convergence behavior out of scope for this pass.

## Arithmetic requested by the task, stated plainly

Only ~3% of the workload (78/2,578 hours) is the frontier window, and it
carries ~18% of this trace's accounted per-hour time (46.19/252.6 s). Within
that 3%, just 9 hours (0.35% of the whole run) carry ~16% of total time, and
3 hours (0.12% of the whole run) carry ~13% of total time. This **does**
explain a large fraction of the remaining ~266 s from a tiny sliver of hours,
confirming the hypothesis run-003/004/005 built up to. It does **not** mean
the other ~84-87% of wall time is free of solver cost, though: the "steady"
window itself averages ~72 ms/hour (this trace) and Step 2's breakdown shows
even ordinary attempts spend the large majority of their time in the solute
phase -- so a *general* residual/Jacobian-assembly or allocation-pattern
audit of the chemistry solver (not retry-specific) remains a legitimate,
separate next lever, exactly as run-003 originally flagged as the alternative
if retries didn't fully explain the gap. They explain a disproportionate
share, not the whole thing.

## Disposition and next action

- Retry-ladder cost near the hour-2,578/2,579 frontier: **CONFIRMED and
  quantified** as a large, disproportionate contributor (9 hours / 0.35% of
  the run carry ~15-16% of total wall time; 3 hours / 0.12% carry ~13%).
- Root cause: the SOLUTE chemistry Newton/Anderson reaction-network solve's
  iteration count grows sharply as the system nears the stiff frontier --
  the same underlying difficulty tracked as `issue-015`. This is genuine,
  currently-unavoidable-without-solver-redesign compute, not waste.
- Safe fix search in the retry path's own plumbing (transactional snapshots,
  per-attempt logging, ladder structure): **negative result** -- nothing
  found that can be removed or streamlined without touching approved
  transactional or convergence architecture. Do not raise iteration/substep
  limits or alter the ladder to "try to make this converge further" -- that
  is explicitly out of scope and belongs to `issue-015`, not this
  performance pass.
- One small, real, permanent, output-neutral, off-by-default instrumentation
  addition (`PERF_HOUR_TRACE`, gated behind the existing
  `--verbose-diagnostics` flag) is committed as source, distinct from this
  evidence file, so future profiling passes do not need a debug rebuild to
  get full per-hour timing.
- Acceptance bar (Zig/Fortran ratio <=1): still **FAIL** (~2.01-2.02x,
  unchanged from run-005 -- this run made no default-path performance
  change, as expected, since it was a profiling pass).
- Recommended next actions, in order: (a) a general residual/Jacobian-assembly
  or allocation-pattern profiling pass on the chemistry Newton/Anderson solve
  across ordinary (non-retry) hours, since Step 2 shows the solute phase
  dominates even single-attempt hours, not only escalating ones; (b) treat
  closing `issue-015`'s convergence problem as the only way to eliminate the
  frontier-specific ~13-16% share identified here, and recognize that fixing
  it is a correctness/science task with a performance side-benefit, not a
  performance task; (c) if a full 30-year comparison is ever attempted before
  `issue-015` closes, expect this same escalation pattern to recur at any
  future stiff frontier, not just this one at hour 2,578.

## Evidence paths

- `ecosys-ng/src/ecosys_ng.zig` (`:8050-8066`) -- the committed 12-line
  source addition (`PERF_HOUR_TRACE`, gated behind the pre-existing
  `run_support.verbose_diagnostics_enabled`).
- `<scratchpad>/ecosys_ng_r6_perftrace.exe` (SHA-256
  `A6E7950063826B45A4FF13D78829CC988BC680A7E0CDC1235AFC73B1871D5978`) -- the
  binary used for the full per-hour trace (Step 1) and the 3 default-flag
  timed repeats (Step 3).
- `<scratchpad>/bench-zig-short/r6_perhour.csv` -- the parsed 2,578-row
  per-hour timing series extracted from Step 1's `run.log`.
- `<scratchpad>/bench-zig-short/r6_profile_evidence.json` -- the
  `--execution-evidence` journal from the Step 1 profiling run (identity
  records only, no timing, per the finding above).
- `<scratchpad>/ecosys_ng_r6_frontierprofile_TEMP.exe`,
  `<scratchpad>/bench-zig-short/r6_frontierprofile_TEMP_err.txt`,
  `r6_frontierprofile_TEMP_timing.json` -- the one-off Step 2 run with the
  temporarily-repointed `temporary_profile_active` window (source fully
  reverted before commit; this binary/log is a throwaway artifact of a
  reverted edit, retained only for this evidence trail).
- `<scratchpad>/bench-zig-short/r6_default_r{0,1,2}_{log,err,evidence,timing}.txt/json`
  -- Step 3's 3 timed repeats.
- `<scratchpad>/bench-zig-short/runottawa_output_files_r6_default_r0/` --
  Step 3's retained output tree, diffed against run-005's
  `runottawa_output_files_r5_neutral_fixed/` for the output-neutrality check.
- `<scratchpad>/run_zig_repeat_r5.ps1` -- reused unchanged from run-005 for
  all timed repeats in this run.
- All scratchpad artifacts above are retained in the session scratchpad only,
  per the standing root-cleanliness instruction, not committed to the
  repository.
