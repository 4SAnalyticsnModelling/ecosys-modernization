# Run 008 -- Fresh single-threaded Zig-vs-Fortran remeasurement over the full currently-reachable window (hour 1-2,894/2,895), post issue-058..068, 2026-09-20

**Status: MEASURED. Over this much longer, fairer window, the Zig/Fortran ratio is dramatically worse than run-007's ~2.0x baseline (~23.7x, range ~22.0-26.3x), but this is explained by measurement-window scope, not by a Zig performance regression: Zig's own absolute wall time to the same hour-2894/2895 boundary is essentially unchanged (mildly improved, ~6% faster) from run-007's own single full-tail sample, despite additional correctness fixes landing since then. Bounded profiling confirms the extra cost the longer window now captures remains concentrated in a handful of hard/escalation hours (one hour, 2,592, alone costs ~14-16 s), not a broad per-typical-hour tax; the one new, unconditional diagnostic check found in the log (`implausible surface conductive flux`, one of this session's three solver-safety guards) fires exclusively inside pre-existing sub-hour retry substeps and never during an ordinary full-hour step.**

Date: 2026-09-20. Context: `run-003` through `run-007` (2026-09-18/19) established a single-threaded Zig/Fortran performance picture using matched *checkpoints* (hour 2,568 or 2,578), because Zig could not previously progress past hour 2,578-2,894 at all. Since `run-007`, a large batch of correctness fixes (`issue-058` through `issue-068`, all on `main`) landed: the SOLUTE iteration-budget fix (60->200), ten water-carrier defect-class fixes, and three solver-safety guards plus two safe damping enhancements. `issue-068`'s own commit trail (10 rounds of diagnosis, ending with "decline eleventh-round substep-extension request per tenth round's own stop order") shows hour 2,895's `SoilPhaseSolverStagnated` failure is an actively-tracked, still-open frontier, not something this run attempts to fix. Per the coordinating task, this run measures the full currently-reachable window (hour 1 through the natural hour-2,894/2,895 boundary) instead of a truncated early checkpoint, and explicitly checks whether the fix batch's extra iteration/floor-check work is a broad per-hour tax or a rare-hour concentration.

Per skill `ecosys-performance-engineering` and `PROJECT_CONTRACT.md`: single-thread first, 3 measured repeats each side, medians/spread reported, machine kept free of other agents' compiles/runs, power/AC state logged and controlled, compiler/flags/hardware/hashes recorded, profile before patching (no source change attempted in this run -- measurement and bounded profiling only).

## Build

**Fortran oracle**: rebuilt fresh, following `run-002`/`run-007`'s documented recipe exactly: the 40 `.f` modules from `f77src/makefile`'s `SRCS` list (excluding the stray uncompiled `redist_utf8.f` duplicate) plus `splits.c`/`splitp.c` compiled separately, gfortran `(MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r2) 16.1.0` (exact version match, freshly verified via `gfortran --version` this session), flags `-O2 -std=legacy -cpp -ffixed-form -ffixed-line-length-72 -fdefault-real-8 -fdefault-double-8 -falign-commons -fautomatic -fmax-stack-var-size=0 -fprotect-parens -fno-associative-math -fno-reciprocal-math -ffp-contract=off -fno-frontend-optimize -fallow-argument-mismatch`. Two scratch-only patches applied to the isolated build copy only (tracked `f77src` never touched), re-derived from `run-002`/`issue-023`'s own documentation: (a) `EXTERNAL SPLIT` declaration inserted into the scratch copy of `soil.f` (gfortran 16 otherwise rejects the legacy `SPLIT` call); (b) the missing `IYRC` argument restored in `grosub.f`'s `CASNC0` debug `WRITE(*,8821)` statement. Result: clean compile, no errors; linked `ecosys_oracle.exe`, **38,966,941 bytes** -- byte-count-identical to `run-002`'s and `run-007`'s own binaries, confirming the same 40-module recipe/flags. SHA-256 of this run's binary: `3238A6DB8D7F755BEB2091B11098FB52EC83A26F6008BDF33A00DDE1E9E7AFB4`.

**ecosys-ng (Zig)**: built via `zig build -Doptimize=ReleaseFast` (Zig `0.16.0`, freshly verified via `zig version`) at git HEAD `8d8450fb2939637e81d1ed6c15456346f66ac33f` (`git status --short` clean before and after -- no source changes made by this run). This HEAD includes the full `issue-058`..`issue-068` fix batch (confirmed via `git log --oneline`, showing `issue-067`'s hybrid-tolerance water-closure fix and all ten rounds of `issue-068`'s solver-safety-guard diagnosis/hardening as the most recent commits before this run). Resulting binary: **12,257,792 bytes**, SHA-256 `CA708F624C59E608C58C211C9A5CF8D1A1C2F19A9578ABD89DCD4C34CDEF7A80`.

## Hardware and power state (explicitly controlled per run-007's own flagged confound)

Same machine as every prior run in this series: 13th Gen Intel Core i9-13950HX, 24 physical/32 logical, Windows 11 Enterprise 10.0.26100. Checked and logged **immediately before every one of the 6 timed repeats** (3 Fortran + 3 Zig), not just once per session (a stricter check than `run-007`'s "checked once, not continuously monitored" caveat):
- `powercfg /getactivescheme`: **Balanced** (`381b4222-f694-41f0-9685-ff5bb260df2e`) -- unchanged across all 6 repeats.
- `Win32_Battery`: `BatteryStatus=2` (on AC power, not discharging), `EstimatedChargeRemaining=100` -- unchanged across all 6 repeats.
- `Get-Process` confirmed no other `zig`/`gfortran`/`ecosys`/`test` process running immediately before every repeat on both sides.

This matches `run-007`'s own recorded state (AC power, 100% charge, Balanced plan) and keeps this run's own measurements internally consistent, though it does not retroactively resolve `run-007`'s addendum question of whether `run-003`'s much slower Fortran number reflected an unrecorded power/thermal state in that earlier session.

## Isolation and decks (fresh scratch copies this session)

- **Fortran**: fresh copy of the full `f25*`/`gbf*h`/`maiz33`/`soyb33`/`swhe33`/`restart.manifest` set from `f77example/Cool Temperate Maize-Soybean ON/`, decontaminated of the same two injected records `run-002`/`run-007` documented and reconfirmed present here (`f25sol98`'s injected `van_genuchten_inflection_pressure_head_m` line; `f25y98`'s trailing `weather_phase` line), both stripped from the isolated copy only. Custom `stdin.deck`: `NAX,NDX=1,1` (unchanged), `NAY,NDY` changed `6,5 -> 1,1` (single 1998-scene truncation, identical to `run-003`/`run-007`'s methodology).
- **Zig**: `robocopy /E` of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/` (`runottawa` + `runottawa_input_files/`, excluding `runottawa_output_files/`, recreated empty before every repeat), with `runottawa` line 81 truncated `6,5 -> 1,1` and scenes 2-6 removed, identical to `run-007`'s truncation (necessary because the deck would otherwise continue toward the full 262,920-hour horizon once past hour 2,895, which this task explicitly prohibits attempting).

Both binaries invoked single-threaded: Fortran by construction (no parallel flags anywhere in any FFLAGS variant, reconfirmed), Zig via `--threads 1`.

## Methodology: measuring the full window, not a truncated checkpoint

Unlike `run-003`-`run-006` (matched at a checkpoint the old code failed just past) and `run-007` (matched checkpoint at hour 2,568, with only one illustrative, non-repeated full-tail sample), this run measures the **full window on both sides as the primary, repeated number**:

- **Zig**: each of 3 repeats ran to its own natural exit (no early kill), single-threaded, default flags (no `--verbose-diagnostics`, so no logging-overhead confound). All 3 repeats reached and fully executed hour 2,894 (`last_hour=2894` for every stage in the stage census) and failed identically on the hour-2895 attempt with `error: SoilPhaseSolverStagnated`, exit code 1 -- exactly the currently-open, separately-tracked `issue-068` frontier, not a new failure this run discovered.
- **Fortran**: has no per-hour run-length control and no per-hour log line (only daily), so an exact hour-2,894 stop is not directly obtainable, the same coarse-granularity limitation `run-003`/`run-007` already disclosed. To stay safely at-or-past hour 2,894 **without running past hour 2,895** (this task's explicit bound), each repeat was polled (250 ms `Select-String` on the growing log) for `exec.f:52`'s `NOW EXECUTING DAY   122   OF YEAR  1998` line, which prints at the start of day 122 = end of hour 121*24 = **hour 2,904** (day *d*'s marker corresponds to end of hour (*d*-1)*24, confirmed against `run-003`'s own day-108/hour-2,568 correspondence). This is a **9-hour (0.31% of the 2,894-hour window) disclosed overshoot past Zig's own hour-2895 stopping point** -- the closest achievable day-boundary checkpoint given Fortran's daily-only granularity, and, like `run-003`'s own similarly-sized disclosed asymmetry, it runs slightly *more* Fortran work than the matched Zig window, which if anything is conservative (unfavorable to Fortran / favorable to Zig) rather than the reverse. Each Fortran repeat then continued to full natural completion of the single truncated 1998 year (8,760 hours, exit 0) for an internal-consistency cross-check, not used in the primary ratio.

## Fortran repeats (fresh oracle build, single 1998 scene, day-122/hour-2,904 checkpoint)

| repeat | checkpoint (s) | full-year total (s) | exit |
|---|---|---|---|
| 1 | 47.18 | 118.39 | 0 |
| 2 | 40.12 | 112.44 | 0 |
| 3 | 44.01 | 116.20 | 0 |

- Checkpoint: **median 44.01 s**, min 40.12 s, max 47.18 s (spread 7.06 s, ~16.0%).
- Full-year total: **median 116.20 s**, min 112.44 s, max 118.39 s.
- All 3 repeats completed the full 365-day year cleanly, exit code 0, only the standard non-fatal end-of-run gfortran FPE-flag note in stderr.
- This is close to `run-007`'s own fresh Fortran measurement (day-108/hour-2,568 checkpoint median 41.01 s) once the ~336-hour extension to hour 2,904 is accounted for (implied rate ~0.0152 s/h here vs. `run-007`'s ~0.0160 s/h -- within a few percent, consistent), and **far faster** than `run-003`'s original, still-unresolved-anomaly measurement (131.46 s at hour 2,568). This run's own result corroborates `run-007`'s fresh number as the more reproducible one, though it does not itself resolve `run-007`'s addendum's open question about what made `run-003`'s session slower.

## Zig repeats (current codebase, single-threaded, full run to natural hour-2894/2895 boundary)

| repeat | wall time (s) | exit | last fully-executed hour | failure |
|---|---|---|---|---|
| 1 | 1053.45 | 1 | 2894 | `SoilPhaseSolverStagnated` |
| 2 | 1042.71 | 1 | 2894 | `SoilPhaseSolverStagnated` |
| 3 | 1038.07 | 1 | 2894 | `SoilPhaseSolverStagnated` |

- **Median 1,042.71 s**, min 1,038.07 s, max 1,053.45 s (spread 15.4 s, ~1.5% -- tighter than every prior run in this series, and tighter than this run's own Fortran spread).
- All 3 repeats: byte-for-byte identical log-line counts (3,906 total lines each), identical stage census (`last_hour=2894` for every executed stage), identical failure mode and exit code -- fully deterministic and reproducible single-threaded behavior.
- **Zig now reaches hour 2,894 cleanly** (previously it failed at hour 2,578 per `run-003`-`run-006`, and at hour 2,894 with a different mechanism, `HourlyCellConservationFailure`, `last_hour=2893`, per `run-007`). The current failure, `SoilPhaseSolverStagnated` at hour 2,895 (`last_hour=2894`), is the actively-tracked `issue-068` frontier (10 diagnosis rounds already recorded on `main`, ending in an explicit "decline further substep-extension, escalate" disposition) -- not a new discovery of this run, and not attempted to be fixed here, per the task's explicit measurement-only scope.

## The Zig/Fortran ratio over this longer window

| comparison | Zig (s) | Fortran (s) | ratio |
|---|---|---|---|
| **This run, primary (full window to hour ~2894/2904)** | 1,042.71 | 44.01 | **23.69** |
| Range across min/max combinations | 1,038.07-1,053.45 | 40.12-47.18 | **22.00-26.25** |
| Sanity check vs. full-year Fortran (looser, ~3x more Fortran work than the matched window) | 1,042.71 | 116.20 | 8.97 |

**This is dramatically worse than `run-007`'s ~2.0x baseline** (its checkpoint-matched numbers ranged 1.77x using the historical Fortran baseline to 5.68x using its own fresh-vs-fresh numbers, both computed at the much shorter hour-2,568 checkpoint) and worse than the `run-004`/`run-005`/`run-006` ~2.02x baseline (computed at the hour-2,578 failure checkpoint, before the fix batch). **The direction of this change is real and not noise**: both sides' repeat-to-repeat spreads (1.5% Zig, 16.0% Fortran) are far smaller than the ~12x gap between the old and new ratios.

## Why the ratio got so much worse: window scope, not a Zig regression

This is the key, task-directed finding, and it is not simply "Zig got slower":

- **Zig's own absolute wall time to this same hour-2894/2895 boundary is essentially unchanged, mildly improved**, from `run-007`'s own single full-tail sample (1,113.54 s, reaching `last_hour=2893` before `HourlyCellConservationFailure`): this run's median is **1,042.71 s, ~6.4% faster**, while now additionally executing one more full hour of accepted work (`last_hour=2894` vs. `run-007`'s `2893`) and surviving past `run-007`'s failure mechanism into a different, harder-to-reach one (`SoilPhaseSolverStagnated`, the subject of `issue-068`'s 10 diagnosis rounds). **The correctness fix batch (`issue-058`-`068`) did not add net wall-time cost on this workload -- if anything it is mildly faster while doing more accepted work.**
- **`run-007`'s ~2.0x/1.77x/5.68x numbers were computed at a truncated hour-2,568 checkpoint**, deliberately excluding almost all of the expensive retry-ladder/frontier tail that `run-006` had already shown concentrates near stiff-convergence frontiers. This run's much larger ratio is the direct, expected consequence of finally being able to measure the **full** tail out to the new, much-later frontier, not evidence of newly-introduced per-hour overhead.
- **Fortran's own per-hour cost is flat and small** across this longer window (~0.015 s/h, consistent with `run-007`'s own fresh measurement), so extending the matched window by ~1,000 hours costs Fortran only a few extra seconds, while it costs Zig several hundred additional seconds concentrated in a handful of hard hours (below) -- this asymmetry, not a uniform per-hour slowdown on either side, is what drives the ratio from ~2x to ~24x.

## Bounded profiling: is the extra cost a typical-hour tax, or still a rare-hour concentration? (task step 5)

Per the task's explicit instruction (profile, do not fix), and using only the **default-build**, always-on log output from the 3 repeats just measured (no `--verbose-diagnostics` rebuild, which would itself reintroduce the large logging overhead `run-004` found and bias the very measurement being checked):

### Day-boundary elapsed-time sampling (1-in-24 hours, from the default `"day advanced"` line)

| window | day-markers (n) | sum | avg/marker | top values |
|---|---|---|---|---|
| steady (hour <=2,568, i.e. day markers 24-2,568) | 107 | 9.87 s | 92 ms | max 432 ms (hour 2,400; a mild, pre-existing ~240-hour periodic pattern already noted in `run-006`, unrelated to this fix batch) |
| newly-reachable (hour 2,569-2,880) | 13 | 32.0 s | 2,464 ms | **hour 2,592: 14.0-15.6 s** (largest single value across all 3 repeats); hour 2,856: 9.2-9.3 s; hour 2,880: 4.3-4.5 s; hour 2,808: 2.1-2.2 s |

The newly-reachable window's day-marker average is **~27x** the steady window's -- directionally the same finding `run-006` made at the old hour-2,578 frontier, now recurring (and, being sampled, understating the true magnitude) at the new hour-2,592/2,856 frontier the fix batch opened up. **Hour 2,592 alone**, reproducible to within ~10% across all 3 repeats (15,583 / 14,012 / 14,301 ms), is close in magnitude to `run-007`'s own independent finding of the same hour costing 15,329 ms with the pre-`issue-065..068` code -- strong cross-session corroboration that this specific hour's cost is a stable property of the underlying chemistry/phase-solver stiffness near this point in the year, not an artifact of either measurement session.

### Retry-ladder escalation frequency

`bounded fixed external hour recovery rejected`/`accepted` lines: **92 rejected + 86 accepted = 178 total escalation events** across the full 2,894-hour run (identical counts across all 3 repeats) -- a small fraction of the run's hours (well under 10%), consistent with `run-006`'s characterization of this as a rare-hour phenomenon, now simply recurring over a longer reachable stretch.

### Is the new solver-safety-guard logging itself a per-hour tax?

The log's single largest line-count contributor, by far, is a **new, unconditional (non-`--verbose-diagnostics`-gated) diagnostic**: `error: implausible surface conductive flux: ...` -- **934 occurrences, identical across all 3 repeats**, roughly a quarter of the whole 3,906-line default log. This is plausibly one of this session's three new solver-safety guards. Checked directly against its own logged `timestep_hours` field to see whether it fires on ordinary full-hour steps or only inside retries:

| `timestep_hours` value | occurrences |
|---|---|
| 5e-2 | 623 |
| 6.25e-2 | 145 |
| 3.125e-2 | 112 |
| 1.25e-1 | 53 |
| 2.5e-1 | 1 |

**Every single occurrence has `timestep_hours < 1`** -- i.e., this check only evaluates/fires inside the pre-existing, already-bounded sub-hour retry-ladder substeps (the same `1 -> 20 -> 32 -> 64`-style escalation architecture `run-006` audited and found approved), and **never during a normal, full 1-hour step**. This directly answers the task's core step-5 question for this specific new check: **it adds zero cost to typical/ordinary hours** -- it can only run at all when an hour is already escalating for an unrelated reason (the freeze-thaw/phase-change floor conditions `run-006` already characterized), and its own cost (formatting and printing one line) is negligible next to the multi-second Newton/Anderson solve cost `run-006` already quantified as 85-97% of an escalating attempt's time.

### Conclusion for the profiling pass

**The extra wall time this longer window reveals is still concentrated in a small number of hard/escalation hours, not spread across typical hours** -- extending, not overturning, `run-006`'s original finding. The single largest new cost driver is simply that the run now survives long enough to reach a *second*, even more expensive stiff-convergence region (peaking at hour 2,592, with secondary peaks at 2,856/2,880/2,808) that did not exist as a measurable cost before because the old code failed at hour 2,578 before ever reaching it. None of the newly-added correctness fixes were found to impose a broad per-hour tax; the one new unconditional diagnostic identified is structurally confined to already-rare retry substeps.

## Honest caveats

1. **Fortran's checkpoint is a 9-hour/0.31% disclosed overshoot** past Zig's own hour-2895 stopping point (day-122 marker = hour 2,904, the closest achievable day-boundary given Fortran's daily-only log granularity) -- the same class of caveat `run-003`/`run-007` already disclosed for their own checkpoint choices, and, if anything, conservative (adds slightly more Fortran work, not less) rather than inflating the ratio in Zig's disfavor.
2. **The day-boundary profiling samples only 1-in-24 hours** (120 of 2,894) in the default build; it is sufficient to identify which *sampled* hours are unusually expensive and to corroborate `run-007`'s independent hour-2,592 finding, but it cannot rule out additional, unsampled expensive hours between day-boundaries. The retry-ladder-event count (178, from unconditionally-logged warn lines, not day-sampled) is a complete count and is the stronger evidence for "still a small fraction of all hours."
3. **This run's ratio (~23.7x) and `run-007`'s (~2.0x-5.68x) are not measuring the same workload** -- this is the run's central, deliberate finding (per the task's own instruction to measure the longer window), not an oversight, but it means the two numbers should never be quoted interchangeably as "the" Zig/Fortran ratio without stating which window each refers to.
4. **Single deck, single machine, single session**, as with every prior run in this series -- no cross-machine reproduction attempted.
5. No source, test, or configuration change was made in this run -- measurement and bounded profiling only, per the task's explicit instruction.

## Disposition and next action

- Success criterion 4 ("ecosys-ng ... highly performant, much better than the fortran oracle run"): **FAIL**, more clearly and by a larger margin than any prior measurement in this series, once measured over the full currently-reachable window rather than a truncated early checkpoint.
- This is **not** evidence that the `issue-058`-`068` correctness batch introduced a performance regression: Zig's own wall time to the same hour-2894/2895 boundary is flat-to-mildly-improved (~6% faster) versus `run-007`'s own prior measurement of that same boundary.
- The dominant remaining cost is concentrated in a handful of stiff-convergence hours (peak: hour 2,592, ~14-16 s alone -- more than 10x the entire steady window's typical per-hour cost), matching the same SOLUTE/phase-solver stiffness mechanism `run-006` already characterized at the old frontier, now recurring at a new one.
- **Recommended next actions, in order**: (a) closing `issue-068`'s open hour-2895 `SoilPhaseSolverStagnated` frontier remains a correctness task, not a performance one, but would (as a side effect) extend the measurable window further and should be expected to reveal further stiff-convergence hours by the same pattern, not a qualitatively different cost profile; (b) any future performance-improvement attempt on this workload should target the SOLUTE/phase-solver Newton-Anderson iteration cost at specific hard hours (as `run-006` recommended and this run reconfirms), not general per-hour overhead, since no broad per-hour tax was found anywhere in this fix batch; (c) do not report this run's ~23.7x figure and `run-007`'s ~2.0x figure interchangeably in any future summary -- always state which measurement window (truncated checkpoint vs. full run-to-failure) a given ratio refers to.

## Evidence paths

- `<scratchpad>/r008-legacy-build/` -- fresh Fortran oracle build tree (40 `.f` modules + `splits.c`/`splitp.c`, scratch-only `EXTERNAL SPLIT`/`IYRC` patches, `ecosys_oracle.exe`).
- `<scratchpad>/r008-fortran-deck/` -- isolated, decontaminated Fortran deck, `stdin.deck`, `r8_f_repeat{1,2,3}_log.txt`/`_err.txt`/`_timing.json`.
- `<scratchpad>/r008-zig-deck/` -- isolated, truncated (1 scene x 1 repeat) Zig deck, `r8_z_repeat{1,2,3}_log.txt`/`_err.txt`/`_evidence.json`/`_timing.json`.
- `<scratchpad>/run_fortran_repeat_r8.ps1`, `<scratchpad>/run_zig_repeat_r8.ps1` -- the exact repeat-runner scripts used.
- `ecosys-ng/ecosys-ng-bin/ecosys_ng.exe` -- the built binary used for all Zig repeats (SHA-256 `CA708F624C59E608C58C211C9A5CF8D1A1C2F19A9578ABD89DCD4C34CDEF7A80`), git HEAD `8d8450fb2939637e81d1ed6c15456346f66ac33f`.
- All scratchpad artifacts are retained in the session scratchpad only, per the standing root-cleanliness instruction, not committed to the repository.
