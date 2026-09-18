# Feature ID: FEAT-018-WATSUB-HEAT-WATER-SOLVER-CORE

Status: PARTIALLY_ASSESSED (source-audit; `watsub.f` is 7,030 lines, not the ~4,500 previously estimated; this pass covers ~20-25% of the non-retention/non-freeze-thaw remainder, ~1,000-1,200 lines)

## Scope and provenance

Legacy source: `f77src/watsub.f` (sha256 `8606E2EA96E52EE8109CF0EF78B6B49AB0683E68BAA41FFACBEBAF1FE49DA95`). **Size correction**: 7,030 lines, not ~4,500 as earlier sessions estimated. Structure: surface energy balance/snowpack physics (`:1-3733`); pond/runoff/snow-drift routing (`:3737-4370`); the actual solver core this dossier covers (`:4370-6197` -- boundary location, water-potential assembly, Darcy/Richards water flux, hydraulic conductivity, macropore Poiseuille flow, vapor diffusion, thermal conductivity/conduction, water-table/tile-drain boundaries); state updates (`:6554-7030`). Retention (feature-002) and freeze-thaw (feature-001) already covered, excluded here.

### 1. Unsaturated (Richards/Darcy) water flux -- `replaced-by-approved-feature`

`watsub.f:4778-4890`: total potential `PSIST1=PSISM1+PSISH+ORFLN*PSISO`; harmonic-mean face conductance `AVCNDL` (`:4840`); flux `FLQX=AVCNDL*(PSIST1-PSISTL)*AREA*XNPHX` (`:4862`), donor/receiver-bounded. Conductivity from the legacy `HCND` Mualem-style class-interpolation table. Zig: `ecosys-ng/src/soil/water/flux.zig` (sha256 `4A294B2F217D9B050B477C52737D79147AA62FE11C075C7E691C724758B784CF`), `calculateMatrixFaceFlux` (harmonic-mean conductance, unlimited flux, donor/receiver bound) structurally identical -- but conductivity comes from `solver_hydraulics.zig`'s pure Mualem-van Genuchten K(h), the already-registered feature-002 replacement, not re-litigated here. Confirmed-benign artifact: the legacy `HCND` table itself (`soil/water/thermal.zig`) carries tag `PR-COND-TABLE-001` documenting its sole surviving production reader was a bug (JK-dependent misread masked by the Ottawa deck's `JK=100`), since replaced by a direct scalar read.

### 2. Soil-internal thermal conductivity + conductive heat flux -- `preserved`, exact match including turbulence term

`watsub.f:5094-5213`: de Vries-style mixing conductivity per face with Rayleigh/Nusselt turbulent-convection enhancement (`:5106-5119`), constants `2.067e-3`/`9.050e-5`/`1.467-0.467`. Zig: `ecosys-ng/src/soil/heat/flux.zig` (sha256 `C85E202974A17C8097E28F7EA4EF41D9DE93A824D7775865CD341B22A0CD1117`), `calculateCellConductivity` (`:24-45`), every constant matches (also `7.844e-3`, max Rayleigh `1e4`), Rayleigh->Nusselt chain verbatim, explicit citation. Confirmed live production call site: `solver_residual.zig:159,168,211`, `solver_boundary.zig:142` (inside the Newton-Raphson heat residual, not dead code).

### 3. Snow-soil vs. internal/litter-soil conduction asymmetry -- `preserved`, legacy itself is asymmetric (verified both ways)

A second Zig thermal-conductivity implementation (`soil/heat/thermal.zig`, sha256 `6D94794384024B3076A5A1DE7225427C14DB722C659DCB2348AF7F9BBBFFB443`) computes the same de Vries mixing formula but with **no** Rayleigh/Nusselt enhancement. **Looked like** the issue-017/018-style domain-asymmetry pattern (one path enhanced, its sibling not) -- checked the actual Fortran call sites and found this is **not a bug**: `watsub.f:1773-1779` (`TCNDS`, snow-to-bare-soil-surface conduction) is written by the legacy authors WITHOUT the turbulence terms -- fixed coefficients, no `XNUSW`/`XNUSA` multiplier -- in contrast to the internal soil-soil face (item 2) and the litter-soil face (`watsub.f:2991-3038`, which DOES include the full turbulence chain). The legacy model itself is asymmetric between "snow resting on bare soil" and "general internal/litter-soil" conduction; this is a deliberate legacy omission, not an oversight. Zig correctly mirrors it: `stages/hourly_heat_water_solute.zig:4621-4623` explicitly cites `watsub.f:1773-1796` and routes the no-turbulence field to `snow_base_thermal_coupling.acceptedInterfaceHeat` (`:4635`) for exactly that interface. **Worth noting as the mirror-image of issue-017/018's standing lesson: check both directions -- sometimes an apparent asymmetry in Zig is a faithfully-preserved asymmetry already present in the Fortran, not a translation gap.**

### 4. Snow thermal conductivity (empirical density law) -- `preserved`

`watsub.f:1443-1448`: `TCND1W=0.0036*10^(2.650*DENSW1-1.652)`. Zig: `ecosys-ng/src/soil/water/snow_heat_conduction.zig` (sha256 `3BEEF273DEBADB3181331EFAA591D78B4C77D72F17799C4ACE41D8ABB7BAB8F2`), exact constant match (`0.0036`/`2.650`/`-1.652`), generalized to a runtime `Parameters` struct rather than hardcoded, citation to "WATSUB 1436--1448."

### 5. Macropore water flow -- `replaced-by-approved-feature`, but no feature-register entry exists

Legacy (`watsub.f:4934-5012`) macropore flow is gravity-plus-hydrostatic only (`:4944-4947`, no matric-potential term) -- by construction cannot drive upward macropore flow against gravity. Zig deliberately has NO dedicated macropore-face kernel: `flux.zig:108-115` explicitly states "the former gravity-plus-hydrostatic `calculateMacroporeFaceFlux` kernel is deliberately absent: it omitted the matric term and made vertical macropore flow downward-only, which contradicts that policy." Both matrix and macropore faces now route through the same `calculateMatrixFaceFlux` using full Mualem-van Genuchten total potential, tested (`solver_tests.zig:249`, "vertical macropore face admits upward matric-driven flow"). Corroborated by a closed internal tag `SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001` (`solver_tests.zig:993-994`, "(removed...)").

**Process gap (documentation only, not functional)**: unlike its siblings Mualem-van Genuchten (feature-002) and Dall'Amico (feature-001), this macropore-flow unification has **no feature-register entry** despite being an intentional, well-tested, well-commented replacement of a legacy defect. Per contract, "every intentional difference" requires an individual feature-register entry. Filed as `audit/issues/issue-019-macropore-flow-unification-missing-feature-entry.md` -- a paperwork gap, code and tests are internally consistent.

## Not covered this pass

Snowpack surface-energy-balance detail (`:1-1400,2600-3800`), pond/runoff/drift routing (`:3737-4370`), boundary/water-table/tile-drain logic (`:5264-6197`) -- mapped by banner only, not equation-traced.

## Acceptance and review

Author: this session's audit fork, 2026-09-18. Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Four items `preserved`/`replaced-by-approved-feature` cleanly, one item functionally sound but missing its formal feature-register entry (`issue-019`, paperwork only). **No functional gaps found in this pass.**
