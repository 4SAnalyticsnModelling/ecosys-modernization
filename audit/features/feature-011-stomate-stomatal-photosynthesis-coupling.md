# Feature ID: FEAT-011-STOMATE-STOMATAL-PHOTOSYNTHESIS-COUPLING

Status: PARTIALLY_ASSESSED (source-audit; `stomate.f` is only 673 lines and was FULLY read this pass -- rare full coverage for this session)

## Scope and provenance

Legacy source: `f77src/stomate.f` (sha256 `5E8ACBAA44C1AC633C5DD75BA2C6897D4B63F4955C4D0157D33083DDCB003AFF`), 673 lines, **100% read**. Not a Ball-Berry/Jarvis conductance model -- computes Arrhenius-scaled temperature/CO2/O2 Km terms, per-branch feedback (`FDBK`/`FDBK4`), light- and CO2-limited C3/C4 carboxylation per leaf node integrated over canopy layers/inclination/azimuth/direct+diffuse PAR (`CH2O`), and from `CH2O` a minimum canopy stomatal resistance `RSMN` used downstream by `uptake.f`/`grosub.f`.

### 1. Arrhenius kinetics + CO2/O2 Km scaling -- `preserved`

`stomate.f:87-106` (`TFN1/TFN2/TFNE`, constants 8.3143/710.0/197500/222500/65000-60000-43000/26.237-24.220-17.362; `XKCO2L/XKO2L/XKCO2O`, constants 16.136/40000, 8.067/20000). Zig: `ecosys-ng/src/canopy/energy/stomatal_resistance.zig` (sha256 `8585AF51AC0CA5DC55B9AE0B22CFB502A9359A9C609A6172736CF14CDFB1DC96`), `gasEnvironment` (`:26-70`), all constants match exactly. File header documents a previously-fixed defect analogous to this session's HOUR1-002/SOLUTE-042 pattern: comment warns the CO2 compensation point must use the scaled `XKO2L`, not the caller's raw 25C PFT constant; three dedicated regression tests (`:251-284`) guard against regression. Live call site traced (`c3Capacity`, `:172`) confirmed using the scaled value, matching `stomate.f:441-442`. **Confirmed fixed and guarded, not an open gap.**

### 2. C3 CO2-compensation-driven carboxylation -- `preserved`

`stomate.f:439-444,495-501` (`VCGRO=VCMX*TFN1*VCDN`; `COMPL=0.5*O2L*VOGRO*XKCO2L/(VCGRO*XKO2L)`; `VGRO=max(0,VCGRO*(CO2L-COMPL)/(CO2L+XKCO2O))`). Zig: `stomatal_resistance.zig:154-183` (`c3Capacity`), exact formula/operand-order match. Efficiency term `CBXN` maps to `carboxylation_umol_co2_per_umol_electron` (`:181`). Live call site: `ecosys-ng/src/canopy/photosynthesis/maximum_turgor_carboxylation.zig` (sha256 `D604B015392A39287D6669E1083FEDFC2D94AF8C878ABA751E9560DECE9EBE13`, `:144-153`); a cross-check test (`:413-448`) reconciles against the separately-maintained production capacity-array path.

### 3. Non-rectangular hyperbola light response -- `preserved`

`stomate.f:330-333,552-555` (`PARJ=PARX+ETGR`; `ETLF=(PARJ-sqrt(PARJ^2-CURV4*PARX*ETGR))/CURV2`). Zig: `stomatal_resistance.zig:74-81` (`lightLimitedElectronTransport`), constants QNTM=0.45/CURV=0.70/CURV4=4*CURV match; deliberate cancellation-resistant algebraic rearrangement, numerically identical, per its own comment. Unit test (`:295-301`) confirms bounds.

### 4. Minimum canopy stomatal resistance `RSMN` -- `preserved`

`stomate.f:656-665` (`RSX=FRADP*DCO2*AREA/(CH2O*3600)` else `RSMH*1.56`; `RSMN=min(RSMH,max(RSMY,RSX*0.641))`, constants RSMY=2.78e-3/0.641/1.56). Two Zig implementations exist and are cross-checked bit-for-bit by test: `stomatal_resistance.zig:83-99` (`minimumWaterVaporResistanceHPerM`, literal constants) and `ecosys-ng/src/canopy/energy/minimum_stomatal_resistance.zig` (sha256 `0F51D8781EBE58BABF318F6CB60867238A3AEC613AEE47D409C8E8311E82E92E`, `:18-45`, explicitly cited "STOMATE.F lines 656-665," parameterized constants). Live production owner confirmed via `stomatal_call_boundary.zig`'s header: "CANOPY-TKC-001 is closed: `coupled_convergence.StomateFinalPass` carries the complete boundary, evaluates STOMATE at accepted TKC, resets RSMN, and performs the final solve" -- traced and confirmed, not a dormant duplicate.

## Issue-tag reconciliation (standing-lesson check applied)

`CANOPY-TKC-001` (throughout `canopy/energy/*.zig`): each file carries a HISTORICAL "GAP, blocked on CANOPY-TKC-001" note immediately followed by a current header confirming it's CLOSED with the bound production owner named. Traced to `coupled_convergence.zig`, confirmed `StomateFinalPass` is the live caller. **Not an open gap.** `HOUR1-002` (governing `FRADP` consumed at `stomate.f:657`) independently reconfirmed closed. No `TODO`/`FIXME`/unresolved markers found touching this file's equations.

## Not covered this pass

Nothing -- full file read. Minor unit/indexing observations noted (Zig's stricter positive-guard vs Fortran's implicit zero-fallthrough; `c4Capacity` duplicate in `stomatal_resistance.zig` confirmed as a deliberate cross-check oracle, not competing dead code) -- neither is a defect.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file coverage). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Four equation groups `preserved`, zero open gaps found in this file.
