# Run 003 -- Zig (ecosys-ng) vs. Fortran oracle, matched single-threaded performance benchmark, 2026-09-18

**Status: FIRST REAL MEASUREMENT, ACCEPTANCE BAR NOT MET.** This is the first-ever controlled (repeated, isolated, matched-workload) performance comparison between ecosys-ng (Zig) and the independent gfortran oracle in this checkout. Success criterion 4 ("ecosys-ng model is highly performant, much better than the fortran oracle run") has **not** been evidenced before this run. Result: on the only currently-possible matched partial workload (hours 1-2,578 of year 1998, single-threaded), **Zig is approximately 6.4x slower than Fortran (ratio ~6.4, not <=1)**. The acceptance bar (Zig/Fortran wall-time ratio <=1) is **NOT MET**. This does **not** cover the full 30-year production workload -- that comparison remains blocked by the separate, already-tracked `issue-015` stiff-solver frontier at hour 2,578-2,579, unchanged by this run (not investigated or worked around here, per scope).

Per skill `ecosys-performance-engineering` and `PROJECT_CONTRACT.md`: fair measurement requires matched workload/dates/inputs, single-thread first, >=3 measured repeats, medians/spread reported, machine kept free of concurrent compiles/runs, compiler/flags/hardware/hashes recorded. All of this was done; details and honest caveats below.

## Why this benchmark is only a partial match

ecosys-ng cannot currently advance past hour 2,578 of the Ottawa deck (see `audit/runs/run-001-ottawa-diagnostic-2026-09-18.md`, `issue-015`) -- a known, separately-tracked stiff nonlinear reaction-network convergence limit, out of scope to fix here. The only workload both sides can currently complete is **hours 1-2,578 of year 1998** (day 1 through day 108). This is real and honest: a full 30-year comparison is **not yet possible**, and criterion 4 cannot be fully closed by this run alone -- only a first real data point is provided.

The Fortran legacy code (`f77src/main.f`, `f77src/readi.f`) has no hour-count or day-count run-length control below the year/scene boundary (checked `main.f:64-124`; the only granularity is `NAX,NDX`/`NAY,NDY` scene-repeat counters). There is no way to make gfortran stop at exactly hour 2,578 mid-year. Per the task's own accepted fallback: the Fortran side was run for the **full single year 1998 (8,760 hours)**, and the wall-clock timestamp at which its own live stdout first prints `NOW EXECUTING DAY   108   OF YEAR  1998` (`f77src/exec.f:52`) was captured by polling the growing log file. This checkpoint corresponds to the **start of day 108 (end of hour 2,568)**, not the exact target hour 2,579 -- an approximation ~10 hours (0.4% of the 2,578-hour window) short of the true target, because the Fortran log only has daily granularity. This is the same caveat the task anticipated and explicitly permits; it is noted here plainly rather than hidden. Both the day-108-checkpoint number (more precise match) and the full-year number (looser, but internally consistent -- see below) are reported.

## Confirming both binaries are single-threaded for this first pass

- **Fortran**: `f77src/makefile` `FFLAGS = -O2 -mp1 -r8 -i4 -align dcommons -cpp -auto-scalar` (line 68, the active uncommented line). No `-openmp`, `-parallel`, `-fopenmp`, MPI, or any other parallel-execution flag appears in any FFLAGS variant in the makefile (checked all live and commented-out FFLAGS lines and LDFLAGS). `-mp1` is confirmed to be ifort's floating-point-consistency flag (restricts optimizations that would change FP rounding/reassociation across sequential statements), **not** a parallelism flag -- ifort's actual parallel flag is `-parallel` (auto-parallelization) or `-qopenmp`/`-openmp`, neither of which appears anywhere in the file. The legacy Fortran source itself contains no OpenMP directives, no MPI calls (aside from one fully-commented-out historical `FFLAGS` line referencing `-lmpi` that is not the active build line), and no threading library calls. **Confirmed single-threaded by construction.**
- **Zig**: invoked explicitly with `--threads 1` for all 3 measured repeats; a supplementary `--threads 4` run was done separately (see below).

## Build

**Fortran oracle** (reused, not rebuilt): `ecosys_oracle.exe`, renamed `ecosys_x.exe`, gfortran `(MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r2) 16.1.0`, flags as above (per `audit/runs/run-002-independent-gfortran-oracle-build-2026-09-18.md`'s documented recipe, post-`issue-023` fix). Binary copied into this run's isolated scratch dir; SHA-256 of the copy actually used: `1452CC0A2E7C17E9063D63FDE19A1CDF4CAE8E7C822C0BAAEB163350551DED0D`.

**ecosys-ng (Zig)**: rebuilt fresh for this run (the pre-existing binary at `ecosys-ng/ecosys-ng-bin/ecosys_ng.exe` was timestamped earlier than the current git HEAD and its optimize mode from `run-001` was `ReleaseSafe`, not the production `ReleaseFast` this benchmark requires). Rebuilt via:
```
cd D:\ecosys-modernization\ecosys-ng
zig build -Doptimize=ReleaseFast
```
Zig `0.16.0`. Git HEAD at build time: `e28745b014d40c8b853590d904f69b14b7413912` (`git status --short` in `ecosys-ng/` was clean before and after -- no source changes made for this benchmark). Resulting binary SHA-256: `7D99E2EE60EED7FC129ECD6A5AC2B20CD4FCC31092E5558ABD1B8C703E0419CE`, 11,647,488 bytes.

## Hardware

13th Gen Intel Core i9-13950HX, 24 physical cores / 32 logical processors. Windows 11 Enterprise 10.0.26100 (64-bit). Machine confirmed free of other `zig`/`gfortran`/`ecosys_x`/`ecosys_ng` processes via `Get-Process` immediately before each measured run (checked before every repeat; none found running concurrently with any measured repeat).

## Isolation and decks (new scratch copies, originals untouched)

Both decks are **new isolated copies** made specifically for this benchmark, in the session scratchpad (not under `D:\ecosys-modernization`), leaving the pre-existing `legacy-run/` and `zig-run/deck/` scratch directories referenced by `run-001`/`run-002` untouched:

- **Fortran**: `<scratchpad>/bench-fortran-short/` -- fresh copy of only the true input files (65 files: site/topo/weather/management/output-editor configs + `ecosys_x.exe`; excluded the ~1,138 bulky output files already sitting in `legacy-run/` from the prior 30-year run). Custom `stdin.deck` written to run **exactly one pass through one scene (year 1998 only)**: `NAX,NDX` unchanged (`1  1`), `NAY,NDY` changed from `6,5` to `1,1` (confirmed against `main.f:64-117`'s exact read/loop structure: `NAX,NDX` scenario-level; `DO NEX=1,NAX: READ NAY,NDY` scene-level, `NA(NEX)`/`ND(NEX)` scene-count/repeat-count; only the first scene block -- `gbf98h,f25y98,f25m98,f25p98,f25ch1,f25wh1,f25nh1,NO,f25eh1,f25cd1,f25wd1,f25nd1,f25pd1,f25ed1` -- kept, followed by the `0  0` scenario terminator). Verified this produces a real, complete single-year run to day 365 with clean exit (checked before the timed repeats).
- **Zig**: `<scratchpad>/bench-zig-short/` -- fresh copy of `runottawa` (the deck config) and `runottawa_input_files/` only, from `<scratchpad>/zig-run/deck/`; **excluded** the pre-existing `runottawa_output_files/` and the loose root-level checkpoint/diagnostic `.bin` files and `restart.manifest` left over from `run-001`'s prior attempt (those are not read by a fresh invocation -- `input_root`/`output_root` in `runottawa` point only at `runottawa_input_files`/`runottawa_output_files`; confirmed via `ecosys-ng/src/core/options.zig` that `resume_from_checkpoint` is a per-scene **input flag**, not file-presence auto-detection, and the deck's own `f25y98` scene-option file has it set to `NO` -- so no resume/checkpoint contamination risk even if stray files existed). `runottawa_output_files/` was deleted and recreated empty before every one of the 4 runs below (3 single-thread + 1 four-thread), guaranteeing a clean hour-1 start each time.

## Fortran repeats (full year 1998, 8,760 hours; day-108 checkpoint via live-log polling)

Command (per repeat, from `bench-fortran-short/`): stdin fed from `stdin.deck` via `Start-Process -RedirectStandardInput`; stdout/stderr redirected to per-repeat log files; log polled every 250 ms for the first appearance of `NOW EXECUTING DAY   108   OF YEAR  1998`.

| repeat | day-108 checkpoint (s) | full-year total (s) | exit |
|---|---|---|---|
| 1 | 139.24 | 453.97 | 0 |
| 2 | 131.46 | 446.50 | 0 |
| 3 | 131.03 | 444.60 | 0 |

- Day-108 checkpoint: **median 131.46 s**, min 131.03 s, max 139.24 s (spread 8.21 s, ~6%).
- Full-year total: **median 446.50 s**, min 444.60 s, max 453.97 s (spread 9.38 s, ~2%).
- Internal consistency check: full-year rate = 446.50 s / 8,760 h = 0.05097 s/h; day-108 rate = 131.46 s / 2,568 h = 0.05121 s/h -- these agree to within 0.5%, supporting that the day-108 checkpoint is a reliable proxy and that per-hour cost is roughly stable across the year (i.e., not dominated by a huge one-time startup cost that would bias the partial-run comparison).
- All 3 repeats completed the full year cleanly, exit code 0 (only the standard informational gfortran end-of-run FPE-flag note in stderr, non-fatal, expected for this model).

## Zig repeats (single-threaded, `--threads 1`, hour-1-to-2,578 failure)

Command (per repeat, from `bench-zig-short/`, output dir wiped first): `ecosys_ng.exe --threads 1 --execution-evidence <tag>_evidence.json runottawa`.

| repeat | wall time to failure (s) | exit | failure hour (confirmed via stderr stage census) |
|---|---|---|---|
| 1 | 859.26 | 1 | 2,578 |
| 2 | 844.97 | 1 | 2,578 |
| 3 | 841.27 | 1 | 2,578 |

- **Median 844.97 s**, min 841.27 s, max 859.26 s (spread 18.0 s, ~2.1%).
- All 3 repeats failed identically: `error: SoluteReactionSolverDidNotConverge` after exhausting the retry ladder, with the stage-execution census confirming `last_hour=2578` for every per-hour-executed stage in every repeat -- fully reproducible failure point and reproducible timing.

## Matched-benchmark ratio (the acceptance-criterion number)

Using the more precise matched comparator (Fortran's day-108/~hour-2,568 checkpoint vs. Zig's hour-2,578 failure -- both are the earliest currently-obtainable checkpoint near the shared frontier, off by ~10 h / 0.4% of the window, single-threaded on both sides):

- **Zig/Fortran wall-time ratio = 844.97 s / 131.46 s = ~6.43** (range across min/max combinations: ~6.0 to ~6.6).

Using the looser full-year Fortran denominator as a sanity check (not the primary number, since it is not workload-matched -- it's comparing Zig's 2,578-hour partial run against Fortran's full 8,760-hour run): 844.97 s / 446.50 s = ~1.89 -- even this deliberately Fortran-unfavorable comparison does not support a Zig speed advantage; it is included only to show the qualitative conclusion is not an artifact of which Fortran denominator is chosen.

**Verdict: the acceptance bar (Zig/Fortran ratio <=1) is NOT MET.** On this matched, single-threaded, partial-run (hours 1-2,578 of 1) benchmark, Zig is approximately **6.4x slower** than the independently-built Fortran oracle, with repeat-to-repeat spread of a few percent on each side (not enough to change the qualitative conclusion). No claim of a universal language-level speed advantage is made in either direction; this is a measured result for this specific translation state, workload, and hardware.

## Supplementary data point: 4-thread Zig (single run, NOT a repeated/rigorous measurement)

One additional run with `--threads 4` (this machine has 32 logical processors; the deck's own `tile_layout` is `1,1,2` -- only 2 tiles, limiting available data-parallelism regardless of thread count):

- `--threads 4`: **680.37 s** to the same hour-2,578 failure (single run only).
- Compared to the single-thread median (844.97 s): ~1.24x speedup, well short of linear 4x scaling -- consistent with the deck's small 2-tile grid limiting exploitable parallelism.
- Compared to Fortran's single-thread day-108 checkpoint (131.46 s): even 4-thread Zig is still ~5.2x slower (680.37/131.46). Threading narrows but does not close the gap on this workload.

This is explicitly **one data point, not a repeated measurement** -- no median/spread is reported for it, per the task's own instruction that this is supplementary only.

## Honest caveats

1. **Partial workload only.** This benchmark covers hours 1-2,578 of a 262,920-hour (30-year) production horizon (~1%). It says nothing about relative performance once/if the hour-2,578 solver frontier (`issue-015`) is resolved and the full run becomes possible on the Zig side. Criterion 4 remains **NOT_ASSESSED** for the full production scope; this run provides the first real partial data point only.
2. **Day-108 checkpoint precision.** The Fortran comparator is a live-log-timestamp approximation at the *start* of day 108 (end of hour 2,568), not the exact hour 2,579 Zig fails at -- a ~10-hour / 0.4% shortfall in the Fortran side's favor (i.e., if anything, this makes the reported ratio slightly conservative/favorable to Fortran, not to Zig, since Fortran's timer effectively stops slightly earlier than the true matched point while it would need a few more seconds to reach the exact hour). Given the ~6.4x gap, this small offset does not change the qualitative conclusion.
3. **Polling overhead.** The day-108 detection used a 250 ms poll loop doing a `Select-String` regex scan of the (small, <1.1 MB) growing log file on the same machine. This is negligible instrumentation overhead relative to the ~130-450 s run times and was identical across all 3 Fortran repeats, so it does not bias the comparison between repeats, though it is technically a small amount of extra CPU activity not present in an uninstrumented run.
4. **Zig binary freshness.** The pre-existing `ecosys_ng.exe` was stale (older commit, `ReleaseSafe`) and was rebuilt in `ReleaseFast` at current HEAD (`e28745b0`) specifically for this benchmark; the Fortran oracle binary was reused as-is from `run-002` (no rebuild needed, no source changes since).
5. **Single deck, single machine, single session.** No cross-machine or cross-session reproduction was attempted. Reported spreads (2-6%) are within-session, same-hardware only.
6. **4-thread result is illustrative only**, run once, on a deck whose grid is too small (2 tiles) to meaningfully exercise 32 logical processors -- it should not be read as characterizing ecosys-ng's scaling behavior on larger grids.

## Disposition and next action

- Success criterion 4 ("ecosys-ng ... much better than the fortran oracle run"): **FAIL** for this matched partial benchmark. Do not weaken this conclusion or represent it as inconclusive -- 3 clean repeats each side, ~6.4x gap, well outside the combined measurement spread.
- Root cause not yet profiled in this run (out of scope here per the task's bounded scope -- this was a measurement pass, not a profiling/optimization pass). Per the skill's "profile before patching" step, a follow-up session should instrument where Zig's per-hour cost is actually going (residual/Jacobian assembly, the retry ladder's repeated substep escalation, allocation patterns, output buffering) before attempting any optimization -- especially since the retry-ladder-heavy final hours near 2,578 may be disproportionately expensive on the Zig side and not representative of steady-state per-hour cost earlier in the run; a future benchmark should also measure a steady, non-failing early window (e.g., hours 1-500) in isolation to separate "steady per-hour cost" from "retry-ladder cost at the frontier."
- Do not re-run this exact benchmark again without new evidence to test (per contract's repeat-run discipline) -- the next useful action is profiling, not another timing repeat.

## Evidence paths

- `<scratchpad>/bench-fortran-short/` -- isolated Fortran deck, truncated `stdin.deck`, `repeat{1,2,3}_log.txt`, `repeat{1,2,3}_err.txt`, `repeat{1,2,3}_timing.json`.
- `<scratchpad>/bench-zig-short/` -- isolated Zig deck, `t1_r{0,1,2}_log.txt`/`_err.txt`/`_evidence.json`/`_timing.json` (single-thread repeats), `t4_r0_*` (4-thread supplementary run).
- `<scratchpad>/run_fortran_repeat.ps1`, `<scratchpad>/run_zig_repeat.ps1` -- the exact repeat-runner scripts used (fixed timestamp/polling logic; an initial `run_fortran_repeat.ps1` bug that mis-detected the day-108 line via a too-narrow `Tail 5` window was caught and fixed before any reported repeat was accepted -- the discarded first attempt is not included in the table above).
- All of the above are retained in the session scratchpad only (bulky/reproducible artifacts, per the standing root-cleanliness instruction), not committed to the repository.
