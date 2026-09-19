# Issue 043 -- `trnsfr.f:6470-6660` subsurface macropore *external boundary* convective flux hardcodes all six inorganic gases (CO2,CH4,O2,N2,N2O,H2) to zero; two smaller co-located copy/paste defects in the same block; Zig does not reproduce any of the three, but only incidentally

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected` (Findings A, B, and C).** See "Closing review (2026-09-19)" section at the end of this file. Independently re-verified `aqueous_extensive_transport.zig` and `external_boundaries.zig`: every species is handled by the same generic, sign-based rule with no per-species carve-out and no domain-flux-variable mixup possible, confirming the issue's own claim for all three co-located findings. A citation comment has been added at `ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig` (above `state_updateBoundary`).

Owner: found by this session's audit fork, 2026-09-19, during a full statement-level read of `trnsfr.f:5906-7604` (the "BOUNDARY SOLUTE AND GAS FLUXES" section through the state-commit tail -- this file's largest remaining unread contiguous range per `feature-009`).

## Background

`trnsfr.f:5906-6923` computes the convective solute/gas flux at the external subsurface boundary of the model domain (edges of the grid and the bottom layer), separately for micropore water flux (`FLWM`, `:6259-6468`) and macropore water flux (`FLWHM`, `:6470-6660`). Both sub-blocks share an identical structure and an identical comment banner (copy-pasted): compute `VFLW` (flux/water-content ratio, clamped to `+-VFLWX`), then branch on discharge (`NN.EQ.1.AND.FLW*.GT.0.0.OR.NN.EQ.2.AND.FLW*.LT.0.0`) vs. recharge (the mirrored condition) vs. "otherwise no flux", assigning the boundary flux for all ~18 species groups (6 inorganic gases CO2/CH4/O2/N2/N2O/H2, 4 organic-C K-indexed species DOC/DON/DOP/acetate, and 6 N/P species each in non-band+band form).

## What was found

Three distinct, co-located defects, all consistent with the micropore block having been copy-pasted to build the macropore block without being fully adapted:

### Finding A (primary, most consequential): the six inorganic gases are unconditionally hardcoded to zero in the macropore boundary block

In the **micropore** block, the six gas fluxes are computed with real values *before* the discharge/recharge branch, so they get a real nonzero value regardless of which branch is taken (`:6284-6289`):
```fortran
RCOFLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,CO2S2(M3,M2,M1))
RCHFLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,CH4S2(M3,M2,M1))
ROXFLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,OXYS2(M3,M2,M1))
RNGFLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,Z2GS2(M3,M2,M1))
RN2FLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,Z2OS2(M3,M2,M1))
RHGFLS(N,M6,M5,M4)=VFLW*AMAX1(0.0,H2GS2(M3,M2,M1))
```
In the **macropore** block, the structurally parallel lines (`:6491-6496`) instead read:
```fortran
RCOFHS(N,M6,M5,M4)=0.0
RCHFHS(N,M6,M5,M4)=0.0
ROXFHS(N,M6,M5,M4)=0.0
RNGFHS(N,M6,M5,M4)=0.0
RN2FHS(N,M6,M5,M4)=0.0
RHGFHS(N,M6,M5,M4)=0.0
```
Neither the discharge branch (`:6500-6531`) nor the recharge branch (`:6535-6574`) nor the "otherwise no flux" branch (`:6578-6602`) ever reassigns `RCOFHS`/`RCHFHS`/`ROXFHS`/`RNGFHS`/`RN2FHS`/`RHGFHS` -- only the organic-C (K-loop) and N/P species are set inside those branches. **The six inorganic gases therefore always get exactly zero macropore boundary convective flux, regardless of macropore water flux direction or magnitude, or of the source cell's macropore gas concentration.** This is a whole-species-group ("N parallel blocks, 1 outlier" generalized to a block of species) omission, not a one-statement typo like `issue-041`.

This is not inert: `RCOFHS` etc. are accumulated into `XCOFHS`/`TCOFHS` etc. (`:6617-6634`, `:7013-7024`), and `TCOFHS` is committed directly into the persistent macropore gas state at the state-commit tail (`:7394-7399`):
```fortran
CO2SH2(L,NY,NX)=CO2SH2(L,NY,NX)+TCOFHS(L,NY,NX)-RCOFXS(L,NY,NX)
CH4SH2(L,NY,NX)=CH4SH2(L,NY,NX)+TCHFHS(L,NY,NX)-RCHFXS(L,NY,NX)
OXYSH2(L,NY,NX)=OXYSH2(L,NY,NX)+TOXFHS(L,NY,NX)-ROXFXS(L,NY,NX)
Z2GSH2(L,NY,NX)=Z2GSH2(L,NY,NX)+TNGFHS(L,NY,NX)-RNGFXS(L,NY,NX)
Z2OSH2(L,NY,NX)=Z2OSH2(L,NY,NX)+TN2FHS(L,NY,NX)-RN2FXS(L,NY,NX)
H2GSH2(L,NY,NX)=H2GSH2(L,NY,NX)+THGFHS(L,NY,NX)-RHGFXS(L,NY,NX)
```
`TCOFHS` etc. are also accumulated from internal adjacent-cell macropore transport elsewhere in the file (already audited, `preserved`), so this defect specifically zeroes out the *external-boundary* contribution only -- lateral edge-of-domain and bottom-of-domain macropore gas exchange never occurs for CO2/CH4/O2/N2/N2O/H2, while it does occur correctly for DOC/DON/DOP/acetate (`OQCH2` etc., `:7363-7370`, fed by real `ROCFHS`-family values) and for NH4/NH3/NO3/NO2/HPO4/H2PO4 in both band forms (`ZNH4H2` etc., `:7400-7411`, fed by real `RN4FHW`-family values).

### Finding B (smaller, same block): recharge branch condition gates on the wrong flux variable

The macropore recharge condition at `:6535-6536` reads:
```fortran
ELSEIF((NN.EQ.2.AND.FLWM(M,N,M6,M5,M4).GT.0.0)
     2.OR.(NN.EQ.1.AND.FLWM(M,N,M6,M5,M4).LT.0.0))THEN
```
It tests `FLWM` (the **micropore** water flux variable) instead of `FLWHM` (the **macropore** water flux variable), even though this whole block is gated on `VOLWHM`/`FLWHM` (`:6484-6489`) and even though the immediately preceding discharge condition at `:6500-6501` correctly uses `FLWHM`. The actual flux values assigned inside this recharge branch (`:6543-6564`) do correctly use `FLWHM`, so only the branch-selection condition is mis-keyed. Whenever `FLWM` and `FLWHM` disagree in sign at a boundary face, this condition can misclassify a true macropore recharge event, causing it to fall through to the "otherwise no flux" branch (Finding C) instead. This is the `trnsfr.f`-side counterpart of the `FLWM`-vs-`FLWHM` variable-substitution habit already confirmed in the sibling salt file's macropore boundary section (`audit/issues/issue-042-trnsfrs-macropore-boundary-flux-branch-structure-diverges-from-sibling.md`, `trnsfrs.f:8161-8163,8263-8265`) -- but unlike `trnsfrs.f`, `trnsfr.f`'s **discharge** branch coverage itself is complete (both `NN` sides are combined correctly at `:6500-6501`), so this is a narrower recurrence of the same authoring habit, not the same missing-branch-coverage defect.

### Finding C (smaller, same block): "otherwise no flux" branch zeroes the wrong variable family for 10 of 18 species groups

The macropore "otherwise no flux" branch (`:6578-6602`) is:
```fortran
ELSE
      DO 9527 K=0,4
      ROCFLS(K,N,M6,M5,M4)=0.0     ! should be ROCFHS
      RONFLS(K,N,M6,M5,M4)=0.0     ! should be RONFHS
      ROPFLS(K,N,M6,M5,M4)=0.0     ! should be ROPFHS
      ROAFLS(K,N,M6,M5,M4)=0.0     ! should be ROAFHS
9527  CONTINUE
      RCOFLS(N,M6,M5,M4)=0.0       ! should be RCOFHS
      RCHFLS(N,M6,M5,M4)=0.0       ! should be RCHFHS
      ROXFLS(N,M6,M5,M4)=0.0       ! should be ROXFHS
      RNGFLS(N,M6,M5,M4)=0.0       ! should be RNGFHS
      RN2FLS(N,M6,M5,M4)=0.0       ! should be RN2FHS
      RHGFLS(N,M6,M5,M4)=0.0       ! should be RHGFHS
      RN4FHW(N,M6,M5,M4)=0.0       ! correct (macropore suffix)
      ...                          ! remaining 11 N/P lines all correct
      RH2BHB(N,M6,M5,M4)=0.0
      ENDIF
```
The first ten assignments (four organic-C K-loop species plus six inorganic gases) use the **micropore**-suffixed variable names (`*FLS`) instead of the **macropore**-suffixed names (`*FHS`) -- they zero variables that belong to the micropore block (already correctly zeroed/set there) instead of the macropore variables this branch is actually responsible for. The remaining twelve N/P lines correctly use the macropore-suffixed names (`*FHW`/`*FHB`). Consequence: for the six inorganic gases this is inert (Finding A already forces them to a constant `0.0` regardless of branch), but for the **four organic-C species** (`ROCFHS`/`RONFHS`/`ROPFHS`/`ROAFHS`), this means that when the "otherwise no flux" condition is reached, their macropore boundary flux values are **not reset** and instead retain whatever stale value survived from processing a previous grid cell/species iteration in the same timestep -- a real state-staleness bug distinct from Findings A/B.

## Scope check

Confirmed via direct comparison against the micropore block immediately above (`:6259-6468`, all species groups computed correctly and symmetrically) and against the organic-C/N-P species inside this same macropore block (computed correctly in the discharge/recharge branches, `:6503-6531,6543-6564`). The commented-out (dead, disabled) "GASOUS LOSS WITH SUBSURFACE MICROPORE WATER GAIN" section immediately following (`:6664-6733`, entirely `C`-commented, a combined-`FLWM+FLWHM` alternative gas-boundary mechanism keyed on `RCOFLG`-family variables, not `RCOFHS`) is not an active fallback for this gap -- it is disabled in its entirety and would not compensate even if active, since it targets a different variable family (`*FLG`, gas-phase litter/soil-surface exchange, not the macropore-boundary solute-phase family `*FHS`).

## Zig side

`ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig` (sha256 `012702E6DCCEA82DF4CC19CF6A4A37E82FF2FF320A99D2F2EEA9D1EDE0EC54BC`) is the Zig home for this boundary mechanism for the dissolved-gas/nutrient species set. Its `state_updateBoundary` (`:667-685`) is called identically for the micropore and macropore domains (`advance`, `:125-126`) and applies the same discharge/recharge convective rule uniformly to *every* species in the shared `amounts` slice -- there is no species-specific carve-out, and no analog of `FLWM`/`FLWHM` variable confusion since each call receives its own domain's `outward_water_flux_m3_per_step` directly as a parameter. `ecosys-ng/src/soil/solute/external_boundaries.zig` (sha256 `83CF613B4F490989902634562E042E87D073775C615A5ED2C000876F739CF7F4`, `calculateNetFluxMol`, `:20-51`), used identically by the driver's generic solute path (`ecosys-ng/src/driver/transport_step.zig`, sha256 `8561548CC1D67FCD2EBF8CE9F31706531EA5120188F2A85CA489DEC97076F7F0`, `advanceSoilLocalSoluteProcesses`, `:262-303`), is likewise fully generic per species with the domain (micropore vs. macropore) selected only via the `apply_donor_content_ceiling` flag and each call's own flux value -- no species is ever hardcoded to a constant zero and no cross-domain flux-variable mixup is architecturally possible.

**Zig therefore does not reproduce any of Findings A, B, or C** -- but, as with every other instance of this recurring pattern in this dossier (finding #3, `issue-029`, `issue-041`, `issue-042`), this is an incidental consequence of a generic, per-species, domain-parameterized architecture, not a documented, reviewed decision to fix these specific statements. Nothing in either Zig file cites `trnsfr.f:6470-6660` specifically or discusses the gas-species omission.

## Why this needs review, not an autonomous close

1. Finding A is the most consequential of the three: it is a whole-species-group (6 of ~18) omission at a real, exercised code path (external subsurface macropore boundary), not a single mistyped statement. If macropore flow is a non-trivial fraction of total subsurface flow at domain edges/bottom in the reference deck, this could suppress a real, physically-motivated pathway for gas exchange (e.g., CO2/CH4 escaping or entering via macropore-dominated lateral/vertical boundary flow) in the legacy oracle that Zig's rewrite would, by contrast, correctly include.
2. Per the project contract, legacy defects need evidence and review before finalizing a `legacy-defect-corrected` disposition; none of the three findings should be silently absorbed into "the generic design happens to differ."
3. No kernel test or numerical impact estimate was produced this pass (read-only, static-source-only constraint for this session).
4. Recommend: (a) a reviewer confirm the disposition as `legacy-defect-corrected` for Finding A specifically (the highest-value target), ideally via a matched-state kernel test constructing a macropore boundary face with nonzero gas concentration and nonzero `FLWHM` to quantify the magnitude of gas mass the legacy routine fails to exchange; (b) confirm or refute Finding B's hypothesized misclassification scenario (`FLWM`/`FLWHM` sign disagreement) with a targeted test; (c) if either is confirmed, add an explicit code comment / feature-register cross-reference at the Zig call sites noting the intentional non-reproduction, per this project's evidence discipline.

## Evidence

`D:\ecosys-modernization\f77src\trnsfr.f:6259-6660,6923-6923,7013-7024,7394-7399` (sha256 `466E28F9A84BC67DB7998F213B48FD56312CC9C01DA09E59E6C36117637635EC`); `D:\ecosys-modernization\ecosys-ng\src\soil\gas\aqueous_extensive_transport.zig:125-126,667-685` (sha256 `012702E6DCCEA82DF4CC19CF6A4A37E82FF2FF320A99D2F2EEA9D1EDE0EC54BC`); `D:\ecosys-modernization\ecosys-ng\src\soil\solute\external_boundaries.zig:20-51` (sha256 `83CF613B4F490989902634562E042E87D073775C615A5ED2C000876F739CF7F4`); `D:\ecosys-modernization\ecosys-ng\src\driver\transport_step.zig:262-303` (sha256 `8561548CC1D67FCD2EBF8CE9F31706531EA5120188F2A85CA489DEC97076F7F0`).

## Closing review (2026-09-19)

Independently re-read `aqueous_extensive_transport.zig`'s `state_updateBoundary` and `advance` (lines 125-126, 667-685) and re-read `driver/transport_step.zig`'s `advanceSoilLocalSoluteProcesses` call site (lines 262-303, quoted in full this pass) to verify the issue's own claim rather than take it at face value. Confirmed: `state_updateBoundary` iterates `for (amounts, recharge, ledger, external_inputs, external_outputs) |...|` over every species uniformly, with the same discharge/recharge branch selected once per call for the whole species slice -- there is no per-species conditional and no way for a subset of species (e.g. the six inorganic gases) to be hardcoded to a literal `0.0` while others receive real flux values. `transport_step.zig`'s driver calls the micropore and macropore boundary functions identically (`calculateNetFluxMol` with `apply_donor_content_ceiling=false`/`true` respectively) for every active cell, each species getting its own `discharge_mobility_fraction`/`recharge_concentration_mol_per_m3` entry -- confirming Finding A (gas hardcoded to zero), Finding B (`FLWM`-vs-`FLWHM` mis-keyed recharge branch), and Finding C (wrong-family zero branch) are all structurally impossible to reproduce here, matching the issue's own claim.

**Disposition confirmed: `legacy-defect-corrected`** for all three co-located findings. A citation comment was added above `state_updateBoundary` in `ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig` naming this issue and Finding A specifically. No matched-state kernel test was added this pass (comment-only change; the existing `aqueous_extensive_transport.zig`/`external_boundaries.zig` test suites already exercise the generic boundary path). Traceability: existing row `TRC-180` carried `disposition=unresolved`; a new row `TRC-285` was added reflecting this closure rather than overwriting `TRC-180`.
