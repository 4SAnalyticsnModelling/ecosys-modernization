# Issue 048 -- `watsub.f` under-snow soil-surface freeze-thaw (`HFLFGX`) is driven by the litter's heat capacity, not the soil's own

Status: OPEN, legacy-side defect found and source-confirmed; Zig-side non-reproduction plausible but not yet confirmed by an instrumented run. Candidate mechanism for issue-024's freeze-thaw divergence -- filed separately per this pass's instruction not to reopen issue-024's own diagnosis loop, cross-referenced there as an incidental note.

Owner: unassigned
Candidate/input hashes: `f77src/watsub.f` sha256 `8606E2EA96E52EE8109CF0EF78B6B49ABE0683E68BAA41FFACBEBAF1FE49DA95`
Source finding: this pass's audit of `audit/features/feature-018-watsub-heat-water-solver-core.md`'s "snowpack surface-energy-balance detail" gap (`watsub.f:1-1400,2600-3800`, extended slightly into `1400-2600` while following the narrative continuously).

## Failure signature and first bad location/process

`watsub.f` computes soil-surface freeze-thaw latent heat (`HFLFGX`/`HFLFG2`/`FLFG2`) in **three** places that should be structurally parallel (an "N parallel blocks" pattern):

1. **Litter freeze-thaw, under snow with litter present** (`watsub.f:1938-1972`, specifically `HFLFRX=VHCPR2*(TFREEZ-TKR22)*XNPRS/(1.0+6.2913E-03*TFREEZ)` at `:1959-1960`) -- correctly uses `VHCPR2`, the litter's own heat capacity (defined at `:1230`).
2. **Soil freeze-thaw, under snow with litter present** (`watsub.f:2064-2095`, `HFLFGX=VHCPR2*(TFREEZ-TKS22)*XNPRS/(1.0+6.2913E-03*TFREEZ)` at `:2082-2083`) -- **uses `VHCPR2` (the litter's heat capacity), not `VHCPG2` (the soil's own heat capacity, `=VHCP1(NUM(NY,NX),NY,NX)`, defined in scope at `:1233` and not reassigned until `:2572`, well after this block runs)**.
3. **Soil freeze-thaw, exposed soil surface (no snow), litter present** (`watsub.f:2788-2820`, `HFLFGX=VHCP1(NUM(NY,NX),NY,NX)*(TFREEZ-TKS2)*XNPR/(1.0+6.2913E-03*TFREEZ)` at `:2807-2808`) -- correctly uses the soil's own heat capacity, `VHCP1(NUM(NY,NX),NY,NX)` (the same quantity `VHCPG2` was assigned from at `:1233`/`:2647`).

Block 2 is the outlier: it computes the *soil* surface's freeze-thaw energy availability (`HFLFGX`, gating `FLFG2`, which changes `VOLW2(NUM(NY,NX),NY,NX)`/`VOLI2(NUM(NY,NX),NY,NX)`, the soil's own water/ice pools) using the wrong heat-capacity variable -- the litter's, not the soil's. `TFREEZ`, `TKS22`, `VOLW2(NUM...)`, `VOLI2(NUM...)`, and `VOLT(NUM...)` in the same block are all correctly the soil's own quantities; only the `VHCPR2` term inside `HFLFGX` is wrong. All variable names, scoping, and the two sibling blocks were read directly from `f77src/watsub.f` this pass (line numbers and formulas quoted above are verbatim).

This is the classic copy-paste pattern the project's audits have repeatedly found ("N parallel blocks, 1 outlier"): block 2 was almost certainly cloned from block 1 (litter) with `TKR22`->`TKS22`, `VOLW2R`->`VOLW2(NUM..)`, `PSISVR`->`PSISVG`, etc. correctly substituted everywhere except the `VHCPR2` inside `HFLFGX`'s formula, which should have become `VHCPG2`.

## Why this matters

`HFLFGX` sets the *magnitude* of the latent-heat increment available to drive freeze/thaw in a substep; `VOLW2(NUM..)`/`VOLI2(NUM..)` via the `AMAX1`/`AMIN1` caps only bound it. If the litter's heat capacity (`VHCPR2`, typically a thin organic layer, e.g. `2.496E-06*(ORGC+ORGCC)*FSNW` plus a small water/ice term) is smaller than the soil surface layer's own heat capacity (`VHCPG2`, which includes the mineral solid heat capacity `VHCM` for a real soil layer, typically much larger), then block 2 systematically **under-drives** the soil's freeze-thaw increment per substep whenever snow and litter are both present -- the exact combination expected at the start of a Canadian winter deck (Ottawa, January, sub-freezing air temperature). The consequence is not a rounding-level effect: the freeze/thaw energy available per substep for the soil surface layer scales with the wrong (generally much smaller) capacity, so many more substeps/hours are needed to reach the same phase-change outcome than the physically-correct `VHCPG2`-scaled version would need.

## Possible relevance to issue-024 (incidental note, not a reopening)

`audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md` (rounds 1-3, still open) found that the Fortran oracle's top soil layer ends hour 1 of the Ottawa Jan-1998 deck **colder** than Zig's layer 1 (`-21.04 degC` vs `-6.05 degC`) yet with **negligible ice** (`ICE_1=9.39e-5`), while Zig's layer 1 converts ~51% of its water to ice in the same hour. Issue-024 identified two live candidates (a matric/osmotic-potential value difference, and a substep-schedule/`NFH x NPH` compounding gap) but left the actual freeze-thaw *energy* formula as "textually identical" between the two sides and did not examine the `VHCPR2`-for-`VHCPG2` substitution documented here, because that inspection was outside its traced call path (issue-024 traced `phase_change.zig`'s Dall'Amico equilibrium formula and `TFREEZ`, not this specific under-snow soil block).

This finding is a **third, previously-unconsidered candidate mechanism**, and its signature matches the observed symptom directionally: if the Fortran oracle's under-snow soil freeze-thaw is throttled by the small litter heat capacity instead of the soil's own (larger) heat capacity, the oracle would show muted/negligible freezing at hour 1 exactly as observed, while a Zig implementation that (by construction, see below) always supplies each cell's own correct heat capacity would show the larger, physically-expected freeze/thaw. This is consistent with, but not proof of, causing issue-024's divergence -- it has not been quantified against issue-024's specific cell/hour, and issue-024's other two candidates remain independently plausible and unruled-out.

**This issue does not reopen issue-024's diagnosis loop.** A note cross-referencing this issue has been added to issue-024's round-3 resolution section as a "flagged, not part of this resolution" pointer for whoever picks up issue-024 next.

## Zig-side status

No hand-duplicated litter/soil freeze-thaw block pair was found in Zig. The relevant machinery:
- `ecosys-ng/src/surface/litter_freeze_thaw_energy_limit.zig` (sha256 `E473D4620EB10E0CC6FC64F05383842214518F40D36D3BB06D2E0CA56E1305AF`) implements the energy-led freeze-thaw rate limit (`watsub.f:3145-3161`, i.e. legacy block 3's sibling for litter without snow) as a generic `apply()` taking `heat_capacity_megajoules_per_k` as an explicit input, not a hardcoded litter-only constant.
- `ecosys-ng/src/surface/temperature_solver.zig` (sha256 `079282B03594A53F4AEA224C75CB32D80BAFAC7FC9EC711EC8669EB241836E34`) calls this generic limiter (`limitPhaseChangeToAvailableEnergy`, around line 1479-1527) from a per-cell `CellPhaseContext`, i.e. the caller supplies whichever cell's (litter's or soil's) own heat capacity is being solved.

Because Zig has one generic per-cell solver rather than hand-written parallel litter/soil blocks, the specific copy-paste opportunity that produced the Fortran bug does not exist in the Zig source in the same shape. **This has not been confirmed by tracing the exact call site that solves the under-snow soil surface cell specifically** (i.e., verifying that whatever caller feeds `CellPhaseContext` for the soil-under-snow-with-litter case passes the soil's own heat capacity and not some snow/litter-derived value) -- that would require following `hourly_snow_energy.zig`/`hourly_gas_surface_water.zig`'s per-cell dispatch in detail, which this pass did not do. Flagged as the concrete next step below.

## Falsifiable cause and next steps

Falsifiable claim: if the Fortran oracle's `HFLFGX` at `watsub.f:2082` is evaluated with the diagnostic-run's actual hour-1 `VHCPR2` and `VHCPG2` values for Ottawa layer 1, the ratio `VHCPG2/VHCPR2` (the factor by which the legacy code under-drives the freeze increment relative to the physically-correct value) should be large enough to plausibly explain several-fold-to-order-of-magnitude slower freeze-thaw progress in the oracle relative to a `VHCPG2`-correct computation.

Recommended next actions for whoever picks this up (not done this pass -- static source read only, no run):
1. Confirm via one instrumented Fortran run (or by hand-computing `VHCPR2`/`VHCPG2` from the deck's litter/soil-layer-1 masses at hour 1) whether this specific code path (litter present, `FSNW>0`) is actually the branch taken for Ottawa hour 1, and quantify the `VHCPG2/VHCPR2` ratio.
2. Trace the exact Zig call site that solves the under-snow soil-surface cell's freeze-thaw (likely in `hourly_snow_energy.zig` or a sibling under `stages/`) and confirm it passes the soil's own heat capacity, not a shared/litter-derived one, closing the "Zig-side status" gap above.
3. If both confirm, decide disposition: this would be a `legacy-defect-corrected` case (Zig's generic architecture happens to avoid a genuine Fortran bug) rather than an unexplained translation divergence -- but per contract this needs independent review before that disposition is finalized, and should be cross-attributed as (at least partial) resolution material for issue-024 rather than closed in isolation.

## Regression added and actually executed

None. This pass was static source reading only (no run, no build, no binary execution), per this session's explicit read-only constraint for this range.

Independent reviewer: not yet done.

Remaining limitation/final disposition: **OPEN, unresolved.** A real, source-confirmed legacy Fortran defect (a variable-substitution miss in a copy-paste block) has been identified with high confidence from direct line-by-line comparison of the three parallel blocks. Its magnitude of practical effect and its exact relationship to issue-024 (partial cause, unrelated, or incidental) are not yet quantified and require the instrumented follow-up above.
