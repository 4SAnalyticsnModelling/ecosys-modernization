# Feature ID: FEAT-019-ORACLE-VS-ZIG-WATER-OUTPUT-COMPARISON-HOUR1-2578

Status: FIRST-PASS COMPARISON DONE; two findings need `ecosys-divergence-diagnosis` follow-up before they can be closed

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

## Not covered this pass

Only the water-hourly (`f25wh1`) stream was compared. Carbon, energy, nitrogen, and phosphorus streams (all confirmed present and structurally comparable on both sides -- see the sibling files listed in `run-002`) were not compared this pass. Only 4 sample hours (1, 100, 1000, 2578) were checked, not a systematic full-window sweep with formal tolerance thresholds (`atol`/`rtol` per the `ecosys-output-comparison` skill's own acceptance-rule guidance) -- this is a first-pass, evidence-gathering comparison, not a completed acceptance gate.

## Acceptance and review

Author: fork dispatched from ecosys-modernization-88's main session, 2026-09-18. Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes -- this surfaces real evidence (both a strong positive result at depth and a real, unexplained near-surface divergence) rather than closing anything. Recommended next actions: (a) invoke `ecosys-divergence-diagnosis` on Finding 2 (top-layer water-content divergence) as the highest-priority item, since it is large, growing, and currently unexplained; (b) get an explicit reviewer decision on Finding 4's schema question; (c) extend this comparison to the carbon/energy/nitrogen/phosphorus streams once Finding 2 is understood, since a shared root cause (e.g. a surface energy/water coupling difference) could plausibly explain divergences across multiple streams at once.
