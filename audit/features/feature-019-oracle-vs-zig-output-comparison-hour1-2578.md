# Feature ID: FEAT-019-ORACLE-VS-ZIG-WATER-OUTPUT-COMPARISON-HOUR1-2578

Status: FIRST-PASS COMPARISON DONE; two findings need `ecosys-divergence-diagnosis` follow-up before they can be closed. EXTENDED to hour 2,894 on 2026-09-20 (see "## Extended comparison through hour 2,894 (2026-09-20)" below) using already-captured evidence (no new run performed for this extension pass) -- Finding 2's divergence does NOT simply keep growing smoothly; it changes character at the very last cleanly-committed hour with an abrupt single-hour collapse that is directly relevant to the paired issue-024/issue-068 decision. FURTHER EXTENDED to hour 3,252 on 2026-09-21 (see "## Extended comparison through hour 3,252 (2026-09-21)" below), after issue-024's committed universal `NFH=4` baseline fix (commit `99234f1`) removed the hour-2,894 collapse mechanism and let the run reach a new frontier (hour 3,253, `issue-078`) -- the collapse is confirmed gone (layer 1 no longer crashes to near-zero), but the underlying chronic top-layer-elevation divergence this session first identified at hour 1 (Finding 2's original, non-collapse symptom) is unchanged in character across the whole new window.

## Scope and provenance

This is the first genuine quantitative output comparison performed for this checkout between:
1. **Fortran oracle** (`audit/runs/run-002-independent-gfortran-oracle-build-2026-09-18.md`): the independently-built gfortran 16.1.0 binary, full 30-year Ottawa run, year-1998-only hourly water file `01998f25wh1` (scratch, not committed; SHA-256 of the scratch file itself not recorded, but the run/build recipe that produced it is fully documented in run-002 and is reproducible).
2. **ecosys-ng (Zig)**: a fresh isolated-deck diagnostic run this session (same Ottawa deck, `ecosys-ng-bin/ecosys_ng.exe` built from git HEAD at time of writing), which fails at the already-documented hour-2578 `SoluteReactionSolverDidNotConverge` frontier (`audit/issues/issue-015-hour-2578-frontier-needs-human-design-decision.md`, `audit/runs/run-001-ottawa-diagnostic-2026-09-18.md`) -- independently reproduced this session at the identical hour, corroborating issue-015's frontier is stable/deterministic. Output: `.../modelled_outputs/water/lat_45.30_lon_-75.70_soil_or_eco_1998_..._f25wh1.txt`.

Both files cover hours 1-2578 of simulated year 1998 for the same site/deck, giving a genuine overlap window for comparison. Legacy source anchors: `f77src/fouts.f` (sha256 `C112D919EF8F317B86AF61A9A819599D34EC0355CAEFDECA5653313A11EB1E8F`, header-label assembly for this file), `f77src/outsh.f` (sha256 `4EE0E55F8C8EE64B04CDC3E665DF28A31D338EB0DCE28A1EDAC64E41CA7D7833`, `:113-169`, the actual K-indexed data assembly for the hourly-soil-water output block, `N.EQ.22`). Zig source anchor: `ecosys-ng/src/soil/diagnostics/output_catalog.zig` (sha256 `3C1FD58E23222BBF1968714D133D50D9032183CA4A20B65D0B5CB4037ECA7845`, `:15-31`, the `water()` catalog builder that defines this exact column schema).

## Column mapping (verified against source, not assumed from header text)

Fortran data row layout (verified via `outsh.f:118-168`, `N.EQ.22` block; tokens counted directly from the actual output row, 0-indexed): `[0]` filename tag (no header label) `[1]` DOY-fraction `[2]` DATE `[3]` HOUR `[4]` EVAPN=`TEVPGH*1000/AREA` `[5]` RUNOFF=`-WQRH*1000/TAREA` `[6]` SEDIMENT `[7]` TTL_SWC=`UVOLW*1000/AREA` (total profile water storage, mm) `[8]` DISCHG=`HVOLO*1000/TAREA` `[9]` SNOWPACK=`max(0,(VOLSS+VOLIS*DENSI+VOLWS))*1000/AREA` `[10..21]` WTR_1..WTR_12=`THETWZ(1..12)` (volumetric liquid fraction, m3/m3, **no unit scaling**) `[22..29]` WTR_13..WTR_20 placeholder zeros (`THETWZ(13..20)`, nonexistent in a 12-layer profile) `[30]` SURF_WTR=`THETWZ(0)` `[31..50]` ICE_1..ICE_20/SURF_ICE region (`THETIZ(0..20)`; exact tail boundary not fully resolved this pass, see Finding 3).

Zig column layout (verified via `output_catalog.zig:18-29`, `water()`): `evapotranspiration[mm]` `runoff[mm]` `sediment_discharge_water[mm]` `root_water_uptake[mm]` `external_water_outflow[mm]` `surface_water_equivalent[mm]` `volumetric_liquid_water_fraction_layer_1..12[m3 m-3]` `surface_excess_liquid_water_depth[m]` `volumetric_ice_fraction_layer_1..12[m3 m-3]` `surface_excess_ice_water_depth[m]` `active_layer_depth_below_surface[m]` `water_table_depth_below_surface[m]`.

## Findings

### 1. Deep soil layers (verified via layer 12) show excellent quantitative agreement -- `preserved`

Layer-12 volumetric liquid water fraction (`WTR_12` vs `volumetric_liquid_water_fraction_layer_12`) at hour 1000: Fortran `0.5112640`, Zig `0.5112638748...` (relative difference ~2.4e-7, i.e. agreement to 6+ significant figures). At hour 2578: Fortran `0.5112641`, Zig `0.5112574...` (relative difference ~1.3e-5). This is strong, genuine positive evidence that the deep-soil water-retention physics (Mualem-van Genuchten / Dall'Amico machinery, `FEAT-001`/`FEAT-002`) produces essentially identical results between the independently-built Fortran oracle and ecosys-ng for this deck, once the profile has equilibrated below the surface-forcing-dominated layers.

### 2. Top 1-2 soil layers show a real, growing divergence between the oracle and ecosys-ng -- `unresolved`, needs `ecosys-divergence-diagnosis`

Layer-1 volumetric liquid water fraction (`WTR_1` vs `volumetric_liquid_water_fraction_layer_1`) across the sampled hours:

| hour | Fortran WTR_1 | Zig layer_1 | relative difference |
|---|---|---|---|
| 1 | 0.2873841 | 0.1342972 | -53% |
| 100 | 0.2452929 | 0.1717055 | -30% |
| 1000 | 0.2643747 | 0.3647958 | +38% |
| 2578 | 0.2904609 | 0.6506264 | +124% |

Layer 2 shows the same pattern (hour 1: Fortran 0.2816860 vs Zig 0.2096645, -26%; hour 2578 not separately tabulated here but shows the same qualitative growing-divergence shape). Layers 3-7 show much smaller (sub-1%) differences at hour 1 that are consistent with ordinary independent-solver floating-point/algorithm divergence, not a structural defect. **This is not noise or an artifact of a bad column mapping** -- the deep-layer agreement (Finding 1) confirms the mapping and general model behavior are correct; the divergence is specifically concentrated in the top 1-2 layers and grows over the run rather than staying bounded, which is the signature of a real, currently-unexplained difference in near-surface water-balance handling (candidates not yet investigated: surface infiltration/evaporation partitioning, snow-layer coupling, or a boundary-condition difference between the two implementations' topmost layer). Per this project's `ecosys-output-comparison` skill guidance, this finding should be handed to `ecosys-divergence-diagnosis` next (inputs/bindings/units/translation/scheduling, in that order) before any `ecosys-feature-attribution` claim that it's an approved improvement rather than a defect. Do not assume either direction without that follow-up.

### 3. EVAPN/evapotranspiration sign convention and magnitude are inconsistent across hours -- `unresolved`, needs follow-up

Fortran `EVAPN` is signed (negative at most sampled hours) while Zig's `evapotranspiration[mm]` is always non-negative in this sample, suggesting a "flux direction" vs "unsigned magnitude" convention difference. However, magnitudes do not consistently track even after ignoring sign: hour 1 (0.0159 vs 0.0293, ~1.8x), hour 100 (0.00135 vs exactly 0), hour 1000 (0.0107 vs 0.000232, ~46x), hour 2578 (0.0619 vs 0.0625, ~1% -- close). The hour-2578 near-match suggests the underlying physics can agree closely, but the wide swings at other hours mean this is not simply a sign-convention artifact. Not diagnosed further this pass -- flagged for the same `ecosys-divergence-diagnosis` follow-up as Finding 2, since it may share a root cause (both are near-surface/evaporative-flux quantities).

### 4. Column-schema mismatch: Fortran's TTL_SWC slot vs Zig's root_water_uptake slot -- `unresolved`, design-intent question

Fortran's 4th data column (`TTL_SWC`, total profile water storage in mm, a stock) occupies the position Zig's schema uses for `root_water_uptake` (a flux, mm) -- these are not the same physical quantity, confirmed by reading both source definitions directly (not assumed from column position alone). This may be an intentional, approved schema redesign (Fortran's TTL_SWC is arguably redundant with -- derivable by summing -- the per-layer volumetric fractions already present in both schemas, so the freed slot could have been deliberately repurposed for a genuinely new, non-redundant diagnostic). It may also be an unintentional divergence if the original translation intended to preserve TTL_SWC verbatim. **No verdict reached this pass** -- this needs an explicit reviewer/design decision (same shape as issue-015/issue-022), not a mechanical fix.

### 5. Minor, zero-impact legacy header-labeling bug in `fouts.f` -- `preserved` (cosmetic only, not fixed)

`fouts.f`'s header-label loop (`:181`, `IF(L.EQ.19)HEAD(M)='WTR_13'`) appears in source but the actual printed header row for this run skips straight from `WTR_12` to `WTR_14` with no `WTR_13` label, while the corresponding data slot (`outsh.f:137`, `K.EQ.19`, `THETWZ(13,NY,NX)`) is correctly present in the data row (confirmed via direct token counting: 8 placeholder-zero columns follow `WTR_12`, matching layers 13-20, all zero since this is a 12-layer profile). Net effect: a cosmetic one-label gap in the header text only; the data columns are unaffected and the value is always zero (nonexistent layer) regardless. Not investigated further (zero science impact, not fixed, not blocking) -- noted here only because it was discovered while establishing the column mapping and would otherwise mislead a future naive header-based parser.

## Extended comparison through hour 2,894 (2026-09-20)

### Provenance -- no new run performed for this extension

Both sides' evidence for this extension already existed in the session scratchpad from other work this session; per this task's instructions, no oracle rerun and no fresh Zig validation run was performed.

- **Fortran oracle**: reused `run-002`'s already-completed full 30-simulated-year run output, `<scratchpad>/legacy-run/01998f25wh1` (8,761 lines = header + full 8,760-hour year-1998 coverage). Hours 2600/2700/2800/2894 were already present in this file; only new extraction (row lookup, no re-execution) was needed. Same column mapping as the original pass, re-verified against the same header row this pass.
- **ecosys-ng (Zig)**: reused an already-captured fresh-from-hour-1 `ReleaseFast` validation run from other work this session (`<scratchpad>/r-val-deck/`), binary SHA-256 `FB7727E5632159D356AF6071502D20542DBCADE4A96C427FDE8447D5549296F1` (built 2026-09-20 21:13:59). Confirmed via `runottawa_output_files/logs/run.log`: `plant_emergence_refresh entries=2894 first_hour=1 last_hour=2894` (and identically for every other per-hour-executed record), i.e. a genuine, clean, fresh-from-hour-1 run of hours 1-2894, consistent with the task's premise that the Zig run "now reaches hour 2,894 cleanly." The run then fails at `total_hour=2895` with `error=SoilPhaseSolverStagnated` (`run.log:3876`) -- this is the already-tracked `issue-068` frontier, not a new failure, and is out of scope for this comparison pass. Output file: `.../modelled_outputs/water/lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep01_scene01_cell01_pop00_f25wh1.txt` (2,895 lines = header + 2,894 data rows, one row per committed hour). Column schema unchanged from the original pass (`output_catalog.zig`'s `water()` catalog).

Both files thus give genuine hours-1-2894 overlap, 316 more hours than the original pass's 1-2578 window.

### Finding 1 update -- deep-layer agreement holds at the new frontier

Layer 12 (`WTR_12` vs `volumetric_liquid_water_fraction_layer_12`) at hour 2894: Fortran `0.5112641`, Zig `0.5112569820642453` -- relative difference ~1.4e-5, i.e. still 5-6 significant figures of agreement, consistent with the original pass's hour-1000/2578 numbers (~2.4e-7 / ~1.3e-5). **The deep-soil retention-physics agreement is unchanged all the way through the new frontier.**

### Finding 2 update -- the growing top-layer divergence does NOT simply keep growing; it changes character at the very last hour

Layer-1 volumetric liquid water fraction, extending the original table (new rows marked `*`):

| hour | Fortran WTR_1 | Zig layer_1 | abs diff | relative difference |
|---|---|---|---|---|
| 1 | 0.2873841 | 0.1342972 | -0.153 | -53% |
| 100 | 0.2452929 | 0.1717055 | -0.074 | -30% |
| 1000 | 0.2643747 | 0.3647958 | +0.100 | +38% |
| 2578 | 0.2904609 | 0.6506317 | +0.360 | +124% |
| 2600* | 0.2758706 | 0.6500051 | +0.374 | +136% |
| 2700* | 0.0463667 | 0.6451705 | +0.599 | +1292% (Fortran denominator near-zero; see note) |
| 2800* | 0.2632058 | 0.6579578 | +0.395 | +150% |
| 2894* | 0.0406611 | 0.0000104 | -0.041 | -100% (sign-reversed) |

Additional tail-window samples taken to characterize the transition (not part of the original hour set, absolute Zig layer-1 value only): hour 2850 `0.639`, 2860 `0.633`, 2870 `0.591`, 2880 `0.625`, 2885 `0.206`, 2888 `0.578`, 2890 `0.599`, 2892 `0.574`, **2893 `0.6058`**, **2894 `0.0000104`** -- Fortran's WTR_1 over the same window declines smoothly and monotonically (`0.048 -> ... -> 0.0409 -> 0.0407`), showing no comparable event.

Reading this together with the original table:

- **Through roughly hour 2600-2893, the divergence continues in the same direction and general absolute magnitude as at hour 2578** -- Zig's layer 1 stays chronically elevated (~0.57-0.66) while Fortran's continues a slow drying trend (falling from ~0.29 at hour 2578 to ~0.041 by hour 2893). The *relative*-difference numbers balloon further (up to +1292% at hour 2700) but this is largely a denominator artifact of Fortran's own value approaching zero, not evidence the *absolute* gap is accelerating -- the absolute gap is roughly stable/bounded in the 0.36-0.60 range across this whole tail window, a materially different shape than the original table's apparently-still-growing 1->2578 trend suggested in isolation.
- **At the very last cleanly-committed hour (2894), Zig's layer 1 abruptly collapses in a single hour** -- from `0.6058` (hour 2893) to `1.04e-5` (hour 2894), i.e. from "chronically over-wet relative to Fortran" to "essentially completely desiccated" in one external hour, while Fortran's own value changes negligibly (`0.04087 -> 0.04066`) across the same hour. This is a genuine **qualitative change in character**, not a continuation of the original monotonic-growth pattern: the sign of the divergence flips in the final hour.
- **This is very likely the same mechanism `issue-068` already documents as the immediate cause of the hour-2895 failure.** Issue-068's own diagnosis (rounds 3-10) repeatedly describes "cell 0/layer 0" reaching a chronic near-total-desiccation state (`water_vapor_volume_m3` in the `1e-7`-`1e-6` range, old/new water repeatedly hitting exact zero) immediately before the hour-2895 domain/stagnation failures. The hour-2894 collapse observed here, in the same cell/same layer-1 (array index 0), to `1.04e-5` volumetric liquid fraction, is direct output-level corroboration of that same near-desiccation state one hour before the model can no longer commit -- not a new, independent finding, but a concrete data point tying issue-024's output-level divergence and issue-068's solver-level failure to the same physical location and the same terminal trajectory.

### Finding 3 update -- EVAPN/evapotranspiration inconsistency persists, with a matching terminal spike

| hour | Fortran EVAPN | Zig evapotranspiration | ratio (abs) |
|---|---|---|---|
| 2600* | -0.04343 | 0.01819 | ~2.4x |
| 2700* | -0.04974 | 0.35919 | ~7.2x |
| 2800* | -0.08297 | 0.02048 | ~4.0x |
| 2894* | +0.02783 | 6.26559 | ~225x |

The same "sign convention differs, magnitude does not consistently track" pattern from the original pass continues through the new sample hours (Fortran still switches sign across hours; Zig stays non-negative). At hour 2894, Zig's `evapotranspiration` value (`6.27` mm in one hour) is 20-30x larger than any other sampled value in the whole tail window and is the direct output-side signature of the same layer-1 collapse described in the Finding 2 update above -- an implicit solver forcing a near-total loss of layer-1 liquid water in one step necessarily shows up as a huge apparent evapotranspiration flux in this output stream. Fortran's EVAPN at the same hour (`+0.0278`) is unremarkable. This is a new, concrete data point but does not change Finding 3's original disposition (still unresolved, still flagged for the same follow-up).

### What this does and does not establish

This extension is evidence-gathering only, per this task's scope -- it does **not** re-diagnose or attempt to fix issue-024 or issue-068, and it does not determine whether Fortran or Zig is "more correct" in the tail window (Fortran's own smooth decline to ~0.04 is itself unverified as ground truth here). It does establish, with concrete new numbers, that (a) the deep-layer agreement (Finding 1) is durable across the whole extended window, (b) the top-layer divergence (Finding 2) is not simply an unbounded monotonic runaway when viewed in absolute terms -- it is roughly bounded through most of the new window -- but (c) it terminates in an abrupt, qualitatively different single-hour collapse at the exact hour immediately preceding the already-tracked hour-2895 failure, which is new, directly relevant evidence for whoever makes the paired issue-024/issue-068 design decision.

## Extended comparison through hour 3,252 (2026-09-21)

### Provenance -- no new run performed for this extension either

Per this task's instructions, both sides' evidence for this second extension already existed and required no new execution:

- **Fortran oracle**: same already-completed `run-002` full 30-simulated-year output reused by the hour-2,894 extension, `<scratchpad>/legacy-run/01998f25wh1` (8,761 lines = header + full 8,760-hour year-1998 coverage, unchanged file, unchanged hash provenance). New hours (2896, 2900, 2920, 2950, 2980, 3000, 3010, 3040, 3070, 3100, 3110, 3140, 3170, 3200, 3210, 3240, 3252) were extracted from this same file by direct row lookup (row N+1 = simulated hour N); no re-run.
- **ecosys-ng (Zig)**: reused the already-captured fresh-from-hour-1 `ReleaseFast` validation run that `issue-024`'s "Committed fix (2026-09-21)" section itself performed to validate the committed universal-`NFH=4`-baseline fix (commit `99234f1`, `src/stages/hourly_heat_water_solute.zig`'s `boundedInitialRecoverySubstepCount`). That run's evidence lives at `<scratchpad>/nfh4-committed-validation-run/runottawa_output_files/modelled_outputs/water/lat_45.30_lon_-75.70_soil_or_eco_1998_exec01_scenario01_rep01_scene01_cell01_pop00_f25wh1.txt` (3,253 lines = header + 3,252 data rows, one per committed hour, confirming the documented `census_positive_control entries=3252 first_hour=1 last_hour=3252` and the terminal `RuntimeSoilPoreCapacityExceeded` frontier at hour 3,253, i.e. `issue-078`, which is explicitly out of scope for this comparison pass). Same `output_catalog.zig` `water()` column schema as every prior pass in this file.

Both files thus give genuine hours-1-3252 overlap, 358 more hours than the hour-2,894 extension's window, covering the entire span the committed fix newly unlocked.

### Finding 1 update -- deep-layer agreement holds essentially unchanged through the new frontier

Layer 12 (`WTR_12` vs `volumetric_liquid_water_fraction_layer_12`) is effectively constant on the Fortran side across this whole window (`0.5112641` at every one of hours 2894/2900/3000/3100/3200/3252, to the file's printed precision) and moves only in the 6th-7th significant figure on the Zig side: `0.5112566` (hour 2894) -> `0.5112566` (2900) -> `0.5112562` (3000/3100/3200/3252). Relative difference stays in the `~1.4e-5`-`~1.6e-5` band throughout, unchanged from both the original pass (hour 2578, `~1.3e-5`) and the hour-2,894 extension (`~1.4e-5`). **The committed `NFH=4` fix has no material effect on deep-layer agreement, and that agreement remains excellent (5-6 significant figures) all the way through hour 3,252.**

### Finding 2 update -- the collapse mechanism is confirmed gone; the chronic elevation it used to mask is confirmed unchanged

Layer-1 volumetric liquid water fraction, new sample hours from the post-fix run:

| hour | Fortran WTR_1 | Zig layer_1 (post-fix) | Zig layer_1 (pre-fix, for reference) | abs diff (post-fix) |
|---|---|---|---|---|
| 2894 | 0.0406611 | 0.6884256 | 0.0000104 (collapsed) | +0.6478 |
| 2896 | 0.0403294 | 0.6902907 | -- | +0.6500 |
| 2900 | 0.0399814 | 0.6924958 | -- | +0.6525 |
| 2920 | 0.3061322 | 0.7074851 | -- | +0.4014 |
| 2950 | 0.2976073 | 0.7311077 | -- | +0.4335 |
| 2980 | 0.3038280 | 0.7423282 | -- | +0.4385 |
| 3000 | 0.2946641 | 0.7567422 | -- | +0.4621 |
| 3010 | 0.2965587 | 0.7670653 | -- | +0.4705 |
| 3040 | 0.2544784 | 0.7742080 | -- | +0.5197 |
| 3070 | 0.2370423 | 0.7747413 | -- | +0.5377 |
| 3100 | 0.2669046 | 0.7752076 | -- | +0.5083 |
| 3110 | 0.2493285 | 0.7753430 | -- | +0.5260 |
| 3140 | 0.1406977 | 0.7754988 | -- | +0.6348 |
| 3170 | 0.0444201 | 0.7731978 | -- | +0.7288 |
| 3200 | 0.0413901 | 0.7622012 | -- | +0.7208 |
| 3210 | 0.0395168 | 0.7503207 | -- | +0.7108 |
| 3240 | 0.0371489 | 0.7464400 | -- | +0.7093 |
| 3252 | 0.2610430 | 0.5690381 | -- | +0.3080 |

This directly answers this task's central question:

- **The collapse mechanism itself is confirmed gone.** At hour 2,894 -- the exact hour that pre-fix collapsed Zig's layer 1 from `0.6058` to `1.04e-5` in a single hour (the hour-2,894 extension's headline finding) -- the post-fix run instead shows layer 1 at `0.6884`, a normal continuation of the chronically-elevated trajectory, with no discontinuity. Hour 2,895 (the shared issue-024/issue-068/issue-077 frontier) clears cleanly, exactly as `issue-024`'s own validation documents.
- **The underlying chronic-elevation divergence is unchanged in character, not improved.** Across the entire new window (hours 2896-3252), Zig's layer 1 stays elevated in a `0.57`-`0.78` band while Fortran's continues its own independent low-frequency oscillation in a `0.04`-`0.31` band -- the same qualitative shape (Zig chronically wetter than Fortran at the surface) that this session first identified at hour 1 (`-53%`... inverting to `+38%` by hour 1000, `+124%` by hour 2578) and that the hour-2,894 extension already showed was roughly bounded in absolute terms through hour ~2893 (absolute gap `0.36`-`0.60` in that window). The new window's absolute gap (`0.31`-`0.73`) is the same order of magnitude and the same sign throughout -- if anything modestly larger at its widest (hour 3170's `+0.729`), but not a new runaway: it contracts back to `+0.308` by the final hour 3,252, tracking Fortran's own hour-3252 uptick (`0.261`) rather than diverging further.
- **This confirms the task's framing precisely.** The NFH=4 fix targeted and eliminated a specific, single-hour desiccation-collapse mechanism (the `DRY_CARRIER`-family near-total-water-loss event this session's hour-2,894 extension tied to `issue-068`'s solver-stagnation frontier). It did **not** touch, and does not appear to have any measurable effect on, this issue's own separately-tracked, still-open root cause (`issue-024` rounds 1-7: a Dall'Amico freeze-thaw / substep-schedule discretization difference dominating hour 1's divergence, per that issue's own diagnosis) -- exactly as `issue-024`'s "Committed fix" disposition itself already states ("Not a resolution of this issue's own core round-1..7 hour-1/layer-1 chronically-elevated-water divergence, which remains open"). This extension supplies the first concrete multi-hundred-hour post-fix confirmation of that self-assessment: the chronic elevation persists, essentially unchanged in magnitude and shape, all the way to the new hour-3,253 frontier.

### Finding 3 update -- EVAPN/evapotranspiration inconsistency persists; the collapse-specific terminal spike is gone

| hour | Fortran EVAPN | Zig evapotranspiration (post-fix) | ratio (abs) |
|---|---|---|---|
| 2894 | +0.027834 | 0.236273 | ~8.5x |
| 2900 | +0.093917 | 0.034227 | ~0.36x |
| 3000 | +0.005575 | 0e0 | Zig exactly zero, Fortran nonzero |
| 3100 | -0.007900 | 0e0 | Zig exactly zero, Fortran nonzero |
| 3200 | +0.056720 | 0.024668 | ~0.43x |
| 3252 | -0.312267 | 0.214726 | ~0.69x, sign-reversed |

The same "sign convention differs, magnitude does not consistently track" pattern from every prior pass continues unchanged. The one qualitative change: the hour-2,894 collapse-specific terminal spike the previous extension documented (Zig `evapotranspiration=6.27` mm, 20-30x every other sampled value, a direct artifact of the now-fixed single-hour desiccation) is **gone** -- hour 2,894's post-fix value (`0.236`) is unremarkable relative to this window's other samples, consistent with the collapse mechanism (Finding 2) being the sole cause of that spike, not a separate EVAPN-specific defect. Finding 3's core disposition (unresolved, same follow-up as Finding 2) is otherwise unchanged.

### What this does and does not establish

Evidence-gathering only, per this task's scope -- no re-diagnosis of issue-024's open root cause or issue-078's tillage-mixing frontier was attempted. This extension establishes, with concrete new numbers spanning 358 further hours: (a) Finding 1 (deep-layer agreement) remains excellent and materially unaffected by the fix; (b) Finding 2's collapse-specific symptom (the abrupt hour-2,894 desiccation) is confirmed eliminated by the committed fix, exactly as `issue-024`/`issue-068`/`issue-077` claim; (c) Finding 2's *other*, chronologically-earlier and separately-diagnosed symptom -- chronic top-layer over-wetness relative to the Fortran oracle, present from hour 1 onward -- is confirmed to persist essentially unchanged in magnitude and shape through the entire new window, i.e. the NFH=4 fix resolved a downstream collapse artifact without touching (for better or worse) the upstream divergence that this issue's own rounds 1-7 are still trying to explain; (d) Finding 3 loses its collapse-specific terminal spike but is otherwise unchanged. No genuinely new, distinct, well-localized issue was found in this pass beyond what `issue-024` and `issue-078` already track -- both findings above are extensions of already-filed, already-open issues, not new defects.

## Not covered this pass

Only the water-hourly (`f25wh1`) stream was compared. Carbon, energy, nitrogen, and phosphorus streams (all confirmed present and structurally comparable on both sides -- see the sibling files listed in `run-002`) were not compared this pass. Only 4 sample hours (1, 100, 1000, 2578) were checked, not a systematic full-window sweep with formal tolerance thresholds (`atol`/`rtol` per the `ecosys-output-comparison` skill's own acceptance-rule guidance) -- this is a first-pass, evidence-gathering comparison, not a completed acceptance gate.

## Acceptance and review

Author: fork dispatched from ecosys-modernization-88's main session, 2026-09-18. Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes -- this surfaces real evidence (both a strong positive result at depth and a real, unexplained near-surface divergence) rather than closing anything. Recommended next actions: (a) invoke `ecosys-divergence-diagnosis` on Finding 2 (top-layer water-content divergence) as the highest-priority item, since it is large, growing, and currently unexplained; (b) get an explicit reviewer decision on Finding 4's schema question; (c) extend this comparison to the carbon/energy/nitrogen/phosphorus streams once Finding 2 is understood, since a shared root cause (e.g. a surface energy/water coupling difference) could plausibly explain divergences across multiple streams at once.

Addendum, 2026-09-21 (hour-3,252 extension): author, fork dispatched to extend the water-stream comparison after `issue-024`'s committed `NFH=4` baseline fix unlocked hours 2895-3252. Independent reviewer: still not done. Decision: still NOT_ASSESSED for gate purposes -- this pass is evidence-extension only. It reclassifies, but does not close, Finding 2: the hour-2,894 desiccation-collapse symptom is confirmed fixed, but the chronic top-layer over-wetness symptom (this issue's actual, still-open round-1..7 root cause per `issue-024`) is confirmed unchanged through the new window. Recommended next actions unchanged from the list above (Finding 2's underlying divergence, not the now-fixed collapse, is still the priority item for `ecosys-divergence-diagnosis`); additionally, once `issue-078`'s hour-3,253 tillage-mixing frontier is resolved and the run reaches further, this comparison should be extended again.
