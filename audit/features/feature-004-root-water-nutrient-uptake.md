# Feature ID: FEAT-004-ROOT-WATER-NUTRIENT-UPTAKE

Status: PARTIALLY_ASSESSED (first-pass source-audit; `uptake.f` is 170KB single-subroutine, most of it not yet read)

## Scope and provenance

**Legacy source:** `f77src/uptake.f` (sha256 `D60132510BB9AB8DD79D62D3770F8BFB9A1984D7C480E388D3F33FE4D8281B2B`) -- single `SUBROUTINE uptake(...)` (`:2`), internally sectioned: canopy energy balance, root hydraulic resistance network, canopy-root water-potential convergence, then per-nutrient (NH4/NO3/H2PO4/HPO4, non-band and band) radial mass-flow/diffusion/Michaelis-Menten blocks.

**Root water uptake (Ohm's-law resistance-in-series):**
```
RSSL=(LOG((PATH(N,L)+RRADL(N,L))/RRADL(N,L))/RTARR(N,L)); RSSX=RSSL/CNDU(L,NY,NX)   [:702-704]
RTAR2=6.283*RRAD2*RTLGP; RSRG=RSRR/RTAR2*VOLA/VOLWM                                  [:716-718]
RSR1, RSR2 (primary/secondary axial resistance)                                      [:736-743]
RSRT=RSRG+RSR1+RSR2; RSRS=RSSX+RSRT                                                  [:761-762]
UPWTRM = clamp((PSILC-PSIST1)/RSRS * PP * XNPHX, ...)                                [:1119-1120]
PSILC=PSILT-PSILH; PSILH=-0.0098*HTSTZ                                               [:660,1097]
```
**New (Zig):** `ecosys-ng/src/plant/root/water_balance.zig` (sha256 `D324AE80966B1F02D629AB102981A3EBDF4812EEA3CF59A92AF20A14D8F65405`), `hydraulicResistance()` (`:523-537`) reproduces `RSSX`/`RSRG`/`RSR1`/`RSR2`/`RSRT`/`RSRS` term-for-term (same log-geometry, same `6.283`/`0.1e-3` constants, same axial split), self-citing "UPTAKE RSSX, RSRG, RSR1, RSR2, RSRT and RSRS equations" (`:521-522`). `PSILH`/`PSILC` reproduced at `:610-611`/`:572-577`, explicitly citing `uptake.f:659-660,1097`.

**Disposition: `preserved`.** Same functional form and constants; Zig solves the canopy-water-storage convergence via Newton-Raphson/Picard where legacy used a fixed-point `MXN=200` cycle -- a permitted solver-architecture difference, not a science change. **Caveat:** the residual/convergence loop that consumes these primitives was not itself traced this pass -- disposition covers the resistance network and elevation term only.

**NH4 uptake (mass-flow + diffusion supply vs. Michaelis-Menten demand, quadratic solution):**
```
ZNSGX=ZNSGL*TORT*XNFH; PATHL=min(PATH,sqrt(2*ZNSGX)); DIFFL=ZNSGX*RTARR/LOG(...)   [:2932-2999 region]
RMFNH4=UPWTRP*CNH4S*FNH4S (convective); DIFNH4=DIFFL*FNH4S (diffusive)
UPMX=UPMXZH*RTARP*FWSRT*TFN4*FNH4S*min(FCUP,FZUP)*XNFH*WFR (O2-limited M-M demand)
X=(DIFNH4+RMFNH4)*CNH4S; Y=DIFNH4*UPMNZH; B=-UPMX-DIFNH4*UPKMZH-X+Y; C=(X-Y)*UPMX
RTKNH4=(-B-SQRT(B*B-4.0*C))/2.0
```
A standard Baldocchi-type quadratic root-uptake formulation (supply=demand solved simultaneously), not a plain M-M evaluation.

**New (Zig):** `ecosys-ng/src/plant/root/plant_root_nutrient_uptake.zig` (sha256 `7BA8EB292456DBE3A26E681AE408FE5AE152BF1608562DD71FE071EF00E29B40`). `radialDiffusiveConductanceM3PerStep()` (`:417-436`) reproduces `ZNSGX`/`PATHL`/`DIFFL` exactly. `transportMichaelisRoot()` (`:488-499`) reproduces `X`,`Y`,`B`,`C` and the quadratic root, rewritten as the numerically-stable conjugate form `2c/(-b+sqrt(disc))` -- symbolically verified algebraically equivalent to `(-B-sqrt(B^2-4C))/2` (avoids catastrophic cancellation when `B^2~=4C`); comment explicitly notes the source term is "retained algebraically as written" (`:502-503`). `inputFromTraits()` (`:447-486`) builds the O2-limited/unlimited `UPMX`/`UPMXP` pair matching `uptake.f:2996-2999`.

**Units note:** Zig comment (`:444-446`) documents that trait-supplied Km/residual concentrations arrive in umol/L (=mol/m3), multiplied by molar mass to get g-element/m3 with no extra power-of-ten conversion -- documented but not independently re-verified against actual PFT input files this pass.

**Disposition: `preserved`** (same functional form, numerically-improved cancellation-safe root formula, symbolically verified equivalent). This numerical-stability improvement may warrant its own feature-register line if the project wants it distinguished from a pure translation -- not found as an existing separate entry.

**Primary reference:** none external cited -- legacy-derived formulation (Baldocchi-style combined supply/demand root uptake), standard in ecosys-family models.

**User-approved scope:** covered generally by `PROJECT_CONTRACT.md`'s translation-completeness requirement; no feature-specific approval doc found beyond that.

## Scientific and numerical tests

Not run this pass (source-read only, per contract G1 scope).

## Acceptance and review

**Author:** this session's audit fork, 2026-09-18 (first-pass survey; canopy energy-balance body `:400-1090`, NO3/H2PO4/HPO4 band-zone blocks, gas-conductance/O2-uptake sections `:2004-2650`, and everything past ~line 4200 of `uptake.f` NOT yet read -- scope explicitly narrower than the full file).

**Independent reviewer:** not yet done for this dossier.

**Evidence paths/hashes:** as cited above, git commit `97a33a9`-era tree (pre-dating this session's later commits, files unchanged).

**Decision:** NOT_ASSESSED for gate purposes. Two equations confirmed `preserved` at the level read; large remaining scope in this file untraced.

## Candidate issue found (not confirmed) -- see also `audit/issues/issue-009-root-uptake-geometry-uninstrumented.md`

`ecosys-ng/src/validation/stage_execution_census.zig` (sha256 `0805663013BD493CA4B4622D0B700306319ABA23FFEE06530DFAA22D290BCBF0`) defines both `root_water_uptake` (confirmed **instrumented**, `:116`) and `root_uptake_geometry` (explicitly listed under `uninstrumented_reason.inside_a_parallel_tile_kernel`, `:180`) as census stages. The author's own note (`:161-167`, `:180`) argues `rootUptakeGeometry` (`plant/root/water_balance.zig:459`) is likely subsumed by `root_water_uptake`'s confirmed execution but defers a firm conclusion, since no serial point observes whether the parallel-kernel-internal call actually ran. This is the closest analog found in this checkout to concerns the mature reference project's own docs raise about `root_water_uptake`/`root_uptake_geometry` execution status -- filed as a candidate issue for follow-up (confirm `rootUptakeGeometry` fires in a real deck run rather than being short-circuited by tile-active gating).
