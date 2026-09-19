# Issue 024 -- Top 1-2 soil layers' water content diverges significantly and grows between the Fortran oracle and ecosys-ng (Zig), deep layers agree closely

Status: OPEN (diagnosis not yet started; this issue opens the investigation per `ecosys-divergence-diagnosis` skill's "open an issue before diagnosing" step)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979
Source finding: `audit/features/feature-019-oracle-vs-zig-output-comparison-hour1-2578.md` (first quantitative oracle-vs-Zig comparison, this session)

Failure signature and first bad time/location/process:
Comparing the independently-built gfortran oracle's hourly water output (`f77example` Ottawa deck, year 1998, `01998f25wh1`) against ecosys-ng's own diagnostic run of the identical deck (same site, same hours 1-2578, `.../modelled_outputs/water/..._f25wh1.txt`), layer-1 volumetric liquid water fraction diverges from hour 1 onward and the divergence **grows monotonically in relative terms rather than staying bounded**:

| hour | Fortran WTR_1 | Zig layer_1 | relative difference |
|---|---|---|---|
| 1 | 0.2873841 | 0.1342972 | -53% |
| 100 | 0.2452929 | 0.1717055 | -30% |
| 1000 | 0.2643747 | 0.3647958 | +38% |
| 2578 | 0.2904609 | 0.6506264 | +124% |

Layer 2 shows the same qualitative pattern (hour 1: -26%). By contrast, layer 12 (deepest) agrees to 6+ significant figures at hour 1000 (relative difference ~2.4e-7) and still agrees closely at hour 2578 (~1.3e-5) -- **this rules out a column-mapping error or a wholesale model mismatch**: the deep-layer agreement proves the general retention physics (Mualem-van Genuchten / Dall'Amico machinery) and the column alignment used for this comparison are correct. The divergence is specifically concentrated in the top 1-2 layers (the surface-forcing-dominated layers) and is not present at depth.

A related, possibly-connected symptom: `EVAPN`/`evapotranspiration[mm]` (a near-surface flux quantity) also disagrees inconsistently across the same sampled hours (hour 1: 1.8x; hour 100: Fortran 0.00135 vs Zig exactly 0; hour 1000: ~46x; hour 2578: ~1% -- close). The hour-2578 near-match for this flux alongside the still-large layer-1 divergence at the same hour suggests the two symptoms may not share a single simple root cause, or that compensating errors are present -- not yet determined.

Legacy/Zig source anchors (from feature-019, verified against source): `f77src/outsh.f:113-169` (`N.EQ.22` hourly-water block, `THETWZ(1..12,NY,NX)` assembly) and `f77src/fouts.f` (header assembly) on the Fortran side; `ecosys-ng/src/soil/diagnostics/output_catalog.zig:15-31` (`water()` catalog) on the Zig side for the *output* definition -- the actual *producing* code (whatever computes `THETWZ`/`volumetric_liquid_water_fraction_layer_1` hour-by-hour) has NOT yet been located/read on either side; that is the required next step per this skill's "follow the backward provenance chain from output to first incorrect producer" instruction.

Scientific/output impact: if real (not yet proven whether Fortran or Zig is closer to correct, or whether both have independent, unrelated defects), this affects near-surface soil-water state -- which feeds evapotranspiration, infiltration, snow/ice coupling, and by extension nutrient/gas transport in the same layers. A +124% relative difference by hour 2578 is far outside plausible floating-point/independent-solver noise (contrast with the <1% differences seen in layers 3-7 at hour 1, which likely ARE ordinary independent-implementation noise).

## Minimal reproducer and hypothesis
Exact command/cwd/environment: not yet re-run for this issue specifically; the source comparison used the already-completed oracle run (`run-002`) and a fresh isolated Zig diagnostic run (`ecosys_ng.exe --execution-evidence <path> runottawa`, cwd = isolated copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON`), both already completed this session, scratch outputs available for the current session but not committed/durable.
Input/state provenance: same Ottawa deck on both sides; Fortran side's two documented input-deck fixes (van_genuchten_inflection_pressure_head_m strip from f25sol98; weather_phase strip from each f25yXX) were applied only to the Fortran run's isolated copy -- **the Zig side's deck was NOT given the equivalent treatment because it doesn't need it** (Zig reads a different, already-modern input format) -- worth double-checking this isn't itself a source of surface-layer parameter difference (e.g. van Genuchten inflection parameter defaulting differently on each side for the topmost layer specifically) before pursuing more complex hypotheses.
Hypothesis: none yet ranked/tested. Per the skill's ranked-cause order, candidates to check first (before assuming a deep science defect): (1) baseline/normalization -- do both sides start layer 1 from the same initial condition at hour 0/1? (2) translation/bindings -- is there a unit or indexing difference specific to the topmost layer (e.g. an off-by-one between surface litter layer 0 and soil layer 1, which is a documented recurring pattern in this codebase per `feature-002`'s notes on `PSISM1`/`FCX` retention-branch handling)? (3) process order/stale state -- does one side apply evaporation/infiltration before or after the water-content snapshot that gets written to output, at a different point in the hourly cycle?
Stop/resource budget: fresh issue, 0 of the contract's 3-experiment diagnosis budget spent yet.

## Experiments
(none yet -- this issue documents the discovery; diagnosis has not started)

## Resolution
Cause and focused patch: not yet determined.
Before/after results: n/a
Regression added and actually executed: none yet
Invalidated evidence and rerun dependencies: none
Independent reviewer: not yet done
Remaining limitation or final disposition: OPEN. This is currently the single most important open item for the user's success criterion 3 ("ecosys-ng outputs comparable against fortran oracle outputs") now that a genuine oracle exists (issue-002 resolved) -- unlike the still-open hour-2578 solver frontier (`issue-015`, which needs a human design decision per the user's own prior "keep auditing, revisit solver later" choice), this is a mechanically diagnosable divergence that the `ecosys-divergence-diagnosis` skill's methodology is designed for, and does not obviously require a human design decision until/unless the ranked-cause search is exhausted.
