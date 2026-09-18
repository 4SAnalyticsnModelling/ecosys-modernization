# Feature ID: FEAT-009-TRNSFR-TRNSFRS-SOLUTE-GAS-TRANSPORT

Status: PARTIALLY_ASSESSED (first-pass source-audit; `trnsfrs.f` ~5% and `trnsfr.f` ~4% depth-read of very large files; full-file structural/banner coverage achieved for both)

## Scope and provenance

**Identity verified, not assumed**: `f77src/trnsfrs.f` (9,749 lines, sha256 `89F5D7CD44C0561E9B7233AD42164CBB1F9A6DF84BF90480A7A126177C34C5F1`) header: "3-DIMENSIONAL FLUXES OF ALL SOIL **SALT SOLUTES**" (Al,Fe,H+,Ca,Mg,Na,K,OH-,SO4,HCO3,Cl,CO3, phosphate mineral complexes, silica). `f77src/trnsfr.f` (7,604 lines, sha256 `466E28F9A84BC67DB7998F213B48FD56312CC9C01DA09E59E6C36117637635EC`) header: "3-DIMENSIONAL FLUXES OF ALL SOIL **NON-SALT SOLUTES AND GASES**" (CO2,CH4,O2,N2,N2O,H2,NH4/NH3,NO3/NO2,DOC/DON/DOP/acetate,HPO4/H2PO4). Sibling routines (not driver/callee), same process skeleton, tracking disjoint species sets. `trnsfr.f` additionally carries fire-gas-release sections and litter/atmosphere gas boundary-layer exchange (no salt-phase analog).

### 1. Diffusive (Fick's-law) micropore flux -- `preserved`

`trnsfrs.f:2633-2708`: `DIFAL=(ALSGL2*TORTL+DISPN)*AREA`, `DFVAL=DIFAL*(CAL1-CAL2)` -- diffusivity-weighted concentration-gradient flux. `trnsfr.f:1580-1619` (gas analog): two-resistance-in-series form `CCO2GQ=(PARR*CCO2E*SCO2L+DFGSCO*CCO2S1)/(DFGSCO+PARR)`, `RCODFR=(CCO2GQ-CCO2S1)*min(VOLWM,DFGSCO)` -- reflects the extra air-water phase transition gases undergo that salts do not.

Zig: `ecosys-ng/src/soil/solute/litter_soil_solute_diffusivity.zig` (sha256 `C7F0EA96CF9F2AD775976C75048263FD5CFB393F7C26554BF2E4423582D84573`, `:49-61,84-89`) implements `TORTL=(t1+t2)/(d1+d2)*cover` and `DISPN=dispersivity*min(velocity_cap,|flux/area|)` for all 14 salt diffusivity classes; test "TRNSFRS preserves fourteen diffusivity classes and operation order" hand-verifies against `trnsfrs.f:2635-2638`. For gases, `ecosys-ng/src/soil/gas/transport.zig` (sha256 `4EB569A2DB79FB0E49AC1D95145E1A3E1BC4AB6FEF72ECFE6739F818DF292F19`, `:421-435`, `calculateFaceDiffusiveFluxesGFromValidatedInputs`) implements `conductance*(c1-c2)` with a hard mass-conservation clamp `[-second_mass,first_mass]`, citing `trnsfr.f:5303-5306` for the dual-floor gating (both cells must clear independent floors, no partial-floor branch).

**Disposition: `preserved`**, with a defensive bounded-safety clamp layered on top for gases (addition, not a functional-form change).

### 2. Convective (advective) donor-upwind flux -- `preserved`

`trnsfrs.f:2326-2334`: `VFLW=max(0,min(VFLWX,FLWRM/VOLWM))`, `RFLAL=VFLW*max(0,ZAL2)`. `trnsfr.f:1905-1917`: byte-for-byte the same `VFLW` formula, applied to gas/nutrient species instead. Zig: `ecosys-ng/src/soil/solute/transport.zig` (sha256 `99D9896CD3AB75694A1B6F2C6A1D5DFE3F701FBA4F3E9D222A75D3006DFC17B5`, `:281-302`), `calculateConvectivePoreExchangeFlux`, doc-cited "FINHM donor-upwind convective carrier from WATSUB/TRNSFR," `donor_fraction=min(maximum_convective_fraction, macropore_to_micropore_water_m3/donor_water_m3)` matches the `AMIN1(VFLWX,flux/volume)` cap. Test exercises both flow directions matching the `IF(FLWRM.GT.0.0)...ELSE` branch.

**Disposition: `preserved`.**

### 3. Gas-phase intercell pressure/bubbling equations (trnsfr.f only, no salt analog) -- `legacy-defect-corrected` candidate, needs its own issue entry

`trnsfr.f:5303-5306,5777-5778` map to `soil/gas/transport.zig:450-479` (`atmosphericDiffusiveFluxG`) and `:586-645` (`bubblingFluxesG`). Zig doc comment at `:470-473` records a corrected asymmetry: "The former unconditional `min` was correct only for inward diffusion; on an outward gradient it selected the more-negative equilibrium endpoint and evacuated the pool regardless of conductance." This reads as an already-applied, tested translation-defect fix (test at `:481`). **No dated `audit/issues/` or `audit/features/` entry was found for it in this `D:` checkout** -- disposition is `legacy-defect-corrected` by the evidence, but per this project's own evidence discipline it should get its own issue file rather than live only in a code comment. Separately, `adjacentPressureDrivenFluxesGFromValidatedInputs` (`:547-567`) documents *intentionally preserving* `trnsfr.f`'s "dimensionally inconsistent mol-vs-g `AMIN1`" bound rather than fixing it -- a **`preserved`** legacy quirk, explicitly called out as deliberate, not a defect.

## Internal issue-tag evidence found

`TRNSFRS-DLYRM-001` (cross-referenced at `soil/solute/transport_solver.zig:144-145`, describing "the unrelated TRNSFRS DLYRM thin-layer flux-block gate," distinct from `SOLUTE-TORT-BKDS-001` which is a `watsub.f:1122-1128` tortuosity fallback). Related `DLYRM` gate handling recurs in `driver/transport_step.zig:897,942`. **The tag's own definition/rationale block was not located this pass** -- only its cross-reference -- flagged for a follow-up trace.

## Not covered this pass

`trnsfrs.f`: ~95% by line count (macropore/micropore exchange block `:3352-6814`, subsurface boundary flux beyond `:7700`). `trnsfr.f`: ~96% by line count (litter/atmosphere gas boundary-layer block `:3194-3686`, fire-gas-release sections `:1080,1265`). Both files' full internal structure was swept by banner/comment-header grep (giving structural, not statement-level, coverage).

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (first-pass, explicitly scoped, ~4-5% depth coverage on very large files). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Two equation families `preserved` with direct citations; one `legacy-defect-corrected` candidate needing its own issue file (see `audit/issues/issue-011-atmospheric-diffusive-flux-asymmetry.md`); the vast majority of both files remains a follow-up audit target.
