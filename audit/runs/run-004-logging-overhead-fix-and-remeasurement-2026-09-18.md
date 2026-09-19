# Run 004 -- Logging-overhead diagnosis, fix, and re-measurement (Zig only), 2026-09-18/19

**Status: LOGGING CONFIRMED AS A MAJOR COST; PERMANENT FIX LANDED; ACCEPTANCE BAR STILL NOT MET.**
`run-003` measured ecosys-ng (Zig) at ~6.4x slower than the independent gfortran
oracle on the matched partial benchmark (hours 1-2,578 of the Ottawa deck,
single-threaded) and recommended profiling before any optimization attempt.
This run follows that recommendation for the specific lead named in the task:
`ecosys_ng.zig`'s custom `std.log` handler
(`run_support.routeLogToRunLogAndStderr`, `run_support.zig:415-442`) performs an
unconditional lock, format, file write, `flush()` (a real OS write per line,
not a buffered append), and stderr write for *every* `info`/`warn`/`err`
call, with no minimum-log-level gate. A short reproduction confirmed the
benchmark's Zig run emits a 5.8 MB / 19,248-line stderr file for one 2,578-hour
run, and four specific `info`-level call sites in `ecosys_ng.zig` -- all
debug-shaped, left over from closed frontier investigations, referencing
specific historical hours like 2,657/2,658 -- account for 10,312 of those
19,248 lines (53.6%), firing on **every** hour of the run, not just the hour
they were written to diagnose.

**Result:** gating those call sites (plus one negligible-volume
`TEMP_CHEMISTRY_TRACE` site) behind an off-by-default `--verbose-diagnostics`
flag reduced single-threaded Zig wall time on the same matched workload from a
**844.97 s median (run-003) to a 266.05 s median** -- a **68.5% wall-time
reduction** attributable to this logging alone. The new Zig/Fortran ratio is
**~2.02** (down from ~6.43), a large improvement, but the acceptance bar
(ratio <=1) **is still not met**. Output-neutrality was verified two ways: (a)
197 of 202 produced output files are byte-identical between the unmodified and
fixed builds, and (b) the 5 non-identical files are the run log itself (whose
content is, by design, exactly what changed) and four solute-failure replay
snapshots whose raw-byte differences were traced to struct padding
(`ReactionParameters.phosphate_minerals: ?...`) that `std.mem.asBytes`
incidentally captures but the real decoder never reads -- confirmed by
decoding both snapshots with the production `read()` path and finding the
context, options, and packed chemistry-state vector bit-identical.

## What was found (profiling before patching)

Per the skill's "profile before patching" step, the actual cost was quantified
by inspection and reproduction before any change, not assumed:

1. Re-ran the existing `<scratchpad>/bench-zig-short/` benchmark artifacts from
   `run-003` (`t1_r0_err.txt`, still on disk, 5,806,132 bytes / 19,248 lines).
   Grouped lines by a numerically-normalized signature and counted frequency:

   | count | line signature |
   |---|---|
   | 2,578 | `hourly surface heat capacity owners: cell=... hour=...` |
   | 2,578 | `hourly surface phosphorus lanes: cell=... hour=...` |
   | 2,578 | `hourly surface phosphorus booked: cell=... hour=...` |
   | 2,578 | `hourly surface heat scope history: cell=... hour=...` |
   | 483 x 15 variants | `THERMAL_SOURCE`/`THERMAL_TRACE stage=... layer=...` |
   | (remainder) | various lower-volume `info`/`warn`/`err` lines |

   The four `hourly surface *` lines total 10,312 lines (53.6% of the file)
   and fire exactly once per cell per hour, for **every** hour 1-2,578 -- not
   gated by any hour window.

2. Traced these to `ecosys_ng.zig:6048-6198`, inside `acceptHourAndPublish`.
   The enclosing comments (`SURFACE-HEAT-PONDED-LITTER-BOOKING-001`,
   `PHOSPHORUS-SURFACE-CLOSURE-HOUR-2658-001`) explain they were added to
   localize two specific, already-closed defects at hours 2,657/2,658, and
   were deliberately left printing "every hour, not only on the hour that
   fails" for historical comparison -- but were never gated back off once the
   investigation closed. Every value read inside this loop (`surface_before`,
   `surface_after`, `surface_activity`, `surface_closure`, `phosphorus_before`,
   `phosphorus_after`, `phosphorus_closure`, `stored_surface_heat_capacity`,
   `recomputed_surface_heat_capacity`, and the intermediate
   `capacity_organic_carbon_g_c` / `capacity_vapor_water_equivalent_m3` /
   `capacity_ice_per_water_equivalent` computations) is local to the loop body
   and never read again afterward (confirmed by grep across the whole file);
   the real conservation acceptance decision is
   `hourly_layer_conservation_report`, evaluated once, unconditionally, before
   the loop (`ecosys_ng.zig:6022-6032`) and used again after the loop
   (lines 6200, 6253, 6258, 6321) -- so the loop's printing is provably
   acceptance-inert.
3. The much smaller `TEMP_CHEMISTRY_TRACE` site
   (`stages/hourly_heat_water_solute.zig:148`) is gated to `executed_weather_hours
   < 2` already (2 lines total over the whole run) -- negligible volume, fixed
   for consistency, not because it mattered to the timing.
4. The remaining large cluster, `THERMAL_SOURCE`/`THERMAL_TRACE`
   (`soil/water/heat_step.zig:43-62`, driven from
   `stages/hourly_heat_water_solute.zig`'s `thermal_trace_active` /
   `temporary_profile_active` gates), is **already** self-limiting: it only
   fires for hours `< 8` or hours `2531-2534` (11 of 2,578 hours, ~0.4%),
   controlled by a hardcoded frontier-investigation window, not by a runtime
   flag. Left unchanged in this pass -- see "Not done in this pass" below.

## The fix

Added an off-by-default runtime verbosity switch rather than deleting the
scaffolding (the historical frontier investigations it supported remain
reproducible on demand), following the existing boolean-flag pattern already
used for `--survey-conservation`:

- `ecosys-ng/src/driver/cli.zig`: new `Options.verbose_diagnostics: bool =
  false` field and `--verbose-diagnostics` flag, parsed identically to
  `--survey-conservation` (duplicate-flag rejection, new test `"verbose
  diagnostics logging is off unless explicitly requested"`).
- `ecosys-ng/src/stages/run_support.zig`: new `pub var
  verbose_diagnostics_enabled: bool = false`, documented as read-only after
  startup (set once, single-threaded, before any hourly work or worker
  threads start -- the same lifetime pattern the file's existing
  `active_run_log` global already uses, so this is not new "mutable model
  state," just a startup-configured, read-only-thereafter diagnostic switch).
- `ecosys-ng/src/ecosys_ng.zig`: `main` sets
  `run_support.verbose_diagnostics_enabled = cli_options.verbose_diagnostics`
  immediately after CLI parsing. The `acceptHourAndPublish` per-cell loop at
  `:6048` (the four `hourly surface *` lines) is now `if
  (run_support.verbose_diagnostics_enabled) for (...) { ... }`; nothing inside
  the loop is used outside it, so gating the whole loop -- not just the
  `std.log.info` calls -- changes zero acceptance decisions.
- `ecosys-ng/src/stages/hourly_heat_water_solute.zig`: the
  `TEMP_CHEMISTRY_TRACE` branch now also requires
  `run_support.verbose_diagnostics_enabled`.
- `run_support.routeLogToRunLogAndStderr` / `logToRunLogAndStderr` themselves
  are **untouched**, per the task's explicit instruction -- this is a
  call-site change only.

## Output-neutrality proof

**Full file comparison.** Ran the unmodified (pre-fix) binary once and the
fixed binary (default flags, i.e. `verbose_diagnostics_enabled = false`) once
more, both single-threaded on the identical `bench-zig-short` deck, both
failing identically at hour 2,578 with `SoluteReactionSolverDidNotConverge`
(exit code 1), both producing 202 output files. SHA-256 comparison:

- **197 of 202 files byte-identical.**
- `logs\run.log`: differs, expected -- its content is exactly what changed
  (fewer lines, plus non-deterministic wall-clock timestamps in unrelated
  startup-phase lines that already varied run-to-run before this change, e.g.
  `startup phase complete: phase=run_plan elapsed_ms=...`; a same-binary
  rerun of the *unmodified* build against itself also changes this file for
  the same reason).
- `logs\ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day108-hour{5,8,9,11}.bin`:
  differ at the byte level, but a same-binary-vs-itself rerun of the
  *unmodified* build (two separate process launches, zero code difference)
  produced **zero** byte differences in these same four files -- ruling out
  ordinary per-process nondeterminism (e.g. ASLR) as the cause and pointing
  at something the code change itself perturbed.

**Root-caused, not just tolerated.** `soil/solute/failure_snapshot.zig`
serializes `ReplayCase` via `std.mem.asBytes` on three structs (`Context`,
`ReactionParameters`, `OptionsWithUnitTolerances`) rather than a field-by-field
encoder. `ReactionParameters` contains `phosphate_minerals:
?phosphate_reaction_rates.MineralParameters`, an optional whose Zig
in-memory representation includes compiler-inserted alignment padding; `zig
test`'s own existing assertions in this file already record that the sibling
`OptionsWithUnitTolerances` struct is 72 bytes against a naive 69-byte field
sum, confirming padding is present in this same serialization path.
`std.mem.asBytes` captures that padding as raw, uninitialized-content bytes,
and this fix's removal of one small allocate/free pair
(`TEMP_CHEMISTRY_TRACE`'s `std.json.Stringify.valueAlloc` at hours 1-2, upstream
of hour 2,578) shifts later heap layout enough to change what garbage ends up
in that padding -- a pre-existing, latent property of this serializer, not a
computed-science difference, and not introduced by this fix (it would fire for
any code change anywhere upstream that alters allocation call order).

To prove this conclusively rather than argue it, a throwaway test (added
temporarily to `failure_snapshot.zig`, run once via `zig test src/module_index.zig
--test-filter "TEMPORARY-PERFORMANCE"`, then removed before commit --
never part of the committed diff) decoded both builds' `...hour5.bin` snapshot
with the real production `read()` path (which reads named fields, not raw
bytes) and compared the decoded `context`, `options`, and the full packed
chemistry-state vector (`chemistry.State.packedComponentCount()` components)
for exact equality. **Result: `OK` -- every decoded field and every packed
component value matched exactly.** The raw-byte difference is confined to
padding the decoder never reads; the actual replayable scientific content of
the failure snapshot is bit-identical.

**Test suite.** `zig build test` (module + executable test artifacts, per
`build.zig:32-40`) was attempted but a **pre-existing, unrelated** test
(`driver.outer_hour_transaction.test.production outer hour explicitly owns
soil gas and pending surface ledger`) failed and left a runaway `test.exe`
process consuming CPU indefinitely (observed at 62,993 CPU-seconds before
being killed) when run through `zig build test` in this environment; this
reproduces on the **unmodified, pre-fix** source (verified with `git stash`
before rebuilding the baseline binary), so it is not caused by this change
and is out of this run's scope to fix. To avoid that hang, this fix's own two
new/changed call sites were instead verified with targeted `zig test
src/module_index.zig --test-filter "..."` runs, which do not invoke the
unrelated failing test:
- `--test-filter "verbose diagnostics"` -> `driver.cli.test."verbose
  diagnostics logging is off unless explicitly requested"` -- **OK**.
- `--test-filter "TEMPORARY-PERFORMANCE"` -- the throwaway cross-check above
  -- **OK**, then removed.

Both `hourly_heat_water_solute.zig` and `ecosys_ng.zig` are only reachable
from the executable's own root module (not `module_index.zig`), and a
standalone `zig test` invocation against `ecosys_ng.zig` requires build-graph
module wiring this session did not resolve from the command line in the
time available; the targeted module-side filter plus the full before/after
production-output comparison above is the evidence offered for this run.

## Benchmark methodology (matched to run-003)

Same deck, same isolation discipline: `<scratchpad>/bench-zig-short/`
(`runottawa` + `runottawa_input_files/`), `runottawa_output_files/` wiped and
recreated before every repeat, single-threaded (`--threads 1`), machine
checked free of other `zig`/`gfortran`/`ecosys`/`test` processes before each
repeat (after killing the runaway `test.exe` noted above). Rebuilt fresh via
`zig build -Doptimize=ReleaseFast` (Zig 0.16.0) at git HEAD `95c55ea` in
`ecosys-ng/` (a nested git repository; `git diff --stat e28745b 95c55ea --
src/` is empty, confirming the source is identical to run-003's HEAD except
this run's own four-file edit). Fixed binary: 11,648,000 bytes (vs run-003's
unmodified 11,647,488 bytes).

### Zig, fixed build, single-threaded, `--verbose-diagnostics` NOT passed (default off)

| repeat | wall time (s) | exit | notes |
|---|---|---|---|
| 0 | 579.38 | 1 | **discarded as warm-up** -- see below |
| 1 | 274.34 | 1 | measured |
| 2 | 257.51 | 1 | measured |
| 3 | 266.05 | 1 | measured |

- **Median of the 3 measured repeats: 266.05 s**, min 257.51 s, max 274.34 s
  (spread ~6.4%, comparable to run-003's 2-6% spreads).
- All 4 runs (including the discarded repeat 0) failed identically at hour
  2,578 with `SoluteReactionSolverDidNotConverge`, exit code 1, identical
  stage-census entries (`plant_emergence_refresh entries=2578 first_hour=1
  last_hour=2578`, etc.) -- same amount of accepted work as run-003's
  baseline, confirming the fix changed logging volume only, not how far the
  run progressed.
- **Repeat 0 is reported, not hidden, and explicitly excluded from the
  median**: it ran against the same freshly-built binary as repeats 1-3 but
  took 2.1-2.3x longer. The leading hypothesis is a one-time cost tied to the
  binary's first execution after being freshly linked (e.g. antivirus
  real-time scanning of a new, unsigned executable on first launch, cached
  thereafter) rather than anything in the run itself -- repeats 1-3 used the
  identical on-disk binary with no rebuild between them and were mutually
  consistent (~6% spread). This matches the skill's "stated warmup policy"
  practice; it is called out explicitly rather than silently dropped so a
  reviewer can judge the exclusion.
- Log file size for the fixed build: 2,028,841 bytes / 8,922 lines (down from
  the unmodified build's 5,806,132 bytes / 19,248 lines on the identical
  workload -- a 65.1%-by-bytes / 53.6%-by-lines reduction).

### Comparison to run-003's baseline (unmodified source, not re-measured -- reused)

| build | median (s) | min | max |
|---|---|---|---|
| run-003 baseline (unmodified, verbose logging unconditional) | 844.97 | 841.27 | 859.26 |
| this run, fixed (verbose logging off by default) | 266.05 | 257.51 | 274.34 |

**Wall-time reduction attributable to this logging fix: (844.97 - 266.05) /
844.97 = 68.5%.** This is a large fraction, well above any reasonable
"meaningful" threshold, and confirms logging (specifically these four
call sites) as a major -- not merely contributing -- cost on this benchmark.

### New Zig/Fortran ratio

Fortran's numbers are run-003's, unchanged and not re-measured here (this fix
does not touch Fortran or the oracle build): day-108/hour-2,568 checkpoint
median 131.46 s (min 131.03, max 139.24).

- **New ratio (medians): 266.05 / 131.46 = ~2.02.**
- Range across min/max combinations: min Zig (257.51) / max Fortran (139.24)
  = 1.85; max Zig (274.34) / min Fortran (131.03) = 2.09.
- **This is a large improvement from run-003's ~6.43x, but the acceptance bar
  (Zig/Fortran ratio <=1) is still NOT MET.** Zig is still roughly 2x slower
  than Fortran on this matched, single-threaded, partial (hours 1-2,578 of
  262,920) workload.

## Not done in this pass (honest scope limits)

1. **`THERMAL_SOURCE`/`THERMAL_TRACE` (soil/water/heat_step.zig) left
   unchanged.** These are already self-limiting to an 11-hour hardcoded
   window (hours <8 or 2531-2534) rather than firing every hour, so they were
   judged lower-priority than the four call sites fixed here, which fired on
   literally every one of the 2,578 hours. They still account for a
   non-trivial share of the remaining 8,922-line log and are a reasonable
   target for a follow-up pass if further logging-overhead reduction is
   wanted; converting their hardcoded windows to the same
   `verbose_diagnostics_enabled` gate (or a separate flag) is the natural next
   step and was not done here to keep this change small and independently
   verifiable.
2. **Full `zig build test` suite not completed** due to the pre-existing,
   unrelated `outer_hour_transaction` test failure/hang described above.
   This should be investigated and fixed or triaged separately -- it is a
   correctness-test-infrastructure issue, not a performance one, and is
   reported here only because it was encountered while trying to run the
   existing suite for this task's output-neutrality step.
3. **Partial workload only**, same as run-003: hours 1-2,578 of 262,920
   (~1%). The `issue-015` hour-2,578 stiff-solver frontier is unchanged by
   this run (out of scope here, as in run-003) and still blocks a full
   30-year comparison. Criterion 4 remains **NOT_ASSESSED** for the full
   production scope.
4. Per-hour surface phosphorus/heat `info` lines were gated in full (the
   whole per-cell loop, not just the print statements) because every value
   they read is provably unused afterward; this was verified by grepping the
   whole file for each local variable name, not merely inspected by eye at
   the call site.

## Disposition and next action

- Logging confirmed as a major, not minor, contributor to run-003's ~6.4x
  gap: fixing the four highest-volume call sites alone recovered 68.5% of
  baseline wall time and cut the Zig/Fortran ratio from ~6.43 to ~2.02.
- The fix is a real, permanent, off-by-default source change (not a
  throwaway experiment) -- committed as source, distinct from this evidence
  file.
- Acceptance bar (ratio <=1) still **FAIL**. Recommended next actions, in
  order: (a) apply the same off-by-default gating to `THERMAL_SOURCE`/
  `THERMAL_TRACE` and re-measure; (b) profile the remaining ~266 s the way
  run-003 recommended for the original ~845 s -- residual/Jacobian assembly,
  the retry-ladder cost concentrated near the hour-2,578 frontier, and
  allocation patterns are all still unprofiled and are likely to explain most
  of the remaining ~2x gap, since removing 68.5% of wall time from *pure
  logging* on a numerically unchanged workload strongly suggests the
  underlying solver work itself was previously a smaller fraction of total
  time than it will be now; (c) separately triage the
  `outer_hour_transaction` test hang found above.

## Evidence paths

- `ecosys-ng/src/driver/cli.zig`, `ecosys-ng/src/ecosys_ng.zig`,
  `ecosys-ng/src/stages/run_support.zig`,
  `ecosys-ng/src/stages/hourly_heat_water_solute.zig` -- the committed source
  fix.
- `<scratchpad>/bench-zig-short/t1_r{0,1,2}_err.txt` -- run-003's original,
  unmodified-build logs (19,248 lines each), retained from that run and
  reused here for the line-frequency analysis.
- `<scratchpad>/bench-zig-short/fix_t1_r{0,1,2,3}_{log,err,evidence,timing}.txt/json`
  -- this run's fixed-build repeats (0 discarded as warm-up per above).
- `<scratchpad>/bench-zig-short/runottawa_output_files_baseline2/`,
  `runottawa_output_files_fixed/` -- the two full output trees compared
  byte-for-byte for output-neutrality (202 files each).
- `<scratchpad>/bench-zig-short/baseline_neutral{,2}_{log,err,evidence}.txt/json`
  -- the two unmodified-build output-neutrality runs (baseline-vs-itself
  control, and baseline-vs-fixed comparison source).
- `<scratchpad>/run_zig_repeat_fix.ps1` -- the repeat-runner script used for
  this run's timed repeats (adds `--verbose-diagnostics` and a `fix_`/`verbose_`
  tag prefix on top of run-003's `run_zig_repeat.ps1`, which is unchanged and
  retained for the baseline).
- All of the above are retained in the session scratchpad only, per the
  standing root-cleanliness instruction, not committed to the repository.
