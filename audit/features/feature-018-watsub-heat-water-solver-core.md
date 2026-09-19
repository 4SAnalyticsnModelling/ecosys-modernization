# Feature ID: FEAT-018-WATSUB-HEAT-WATER-SOLVER-CORE

Status: PARTIALLY_ASSESSED (source-audit; `watsub.f` is 7,030 lines; depth-read is now COMPLETE end to end -- this pass closed the last two unresolved sub-ranges, `:6197-6554` (net flux accumulation, below-surface evaporation-condensation, and micropore/macropore freeze-thaw, item 13) and `:6554-7030` (state-variable updates from net fluxes, item 14, confirming the scope note's "state updates" label was accurate). One new defect found and filed (`issue-051`). Depth-read completeness does not equal review completeness: four open issues touch this file (`issue-019`, `issue-049`, `issue-050`, `issue-051`) plus the shared `issue-015` stiff-solver frontier, and no independent reviewer pass has yet been applied to any of this dossier's 14 items -- see the closing tally at the end of this dossier)

## Scope and provenance

Legacy source: `f77src/watsub.f` (sha256 `8606E2EA96E52EE8109CF0EF78B6B49ABE0683E68BAA41FFACBEBAF1FE49DA95`; corrected this pass -- the previously recorded digest here was a 63-character transcription that dropped one hex digit, re-verified against a fresh `Get-FileHash` this pass, file otherwise unchanged and untouched by this or any concurrent agent). **Size correction**: 7,030 lines, not ~4,500 as earlier sessions estimated. Structure: surface energy balance/snowpack physics (`:1-3733`); pond/runoff/snow-drift routing (`:3737-4370`); the actual solver core this dossier covers (`:4370-6197` -- boundary location, water-potential assembly, Darcy/Richards water flux, hydraulic conductivity, macropore Poiseuille flow, vapor diffusion, thermal conductivity/conduction, water-table/tile-drain boundaries); net flux bookkeeping and below-surface evaporation-condensation/freeze-thaw (`:6197-6554`, item 13); state updates (`:6554-7030`, item 14). Retention (feature-002) and freeze-thaw (feature-001) already covered, excluded here.

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

### 6. Snowpack layer physics (radiation, evaporation-condensation, internal freeze-thaw, inter-layer conduction/vapor diffusion) -- `preserved`

`watsub.f:1-2599`: per-column initialization of snow/litter/soil local arrays (`:123-696`), snowpack surface shortwave/longwave and evaporation-condensation (`:1237-1401`; `VPSV=2.173E-03/TK02(1)*0.61*EXP(5360.0*(3.661E-03-1.0/TK02(1)))`), inter-snow-layer meltwater discharge/diffusive vapor/conductive heat exchange (`:1424-1600`), snow density-dependent thermal conductivity (`TCND1W=0.0036*10**(2.650*DENSW1-1.652)`, `:1448`, also independently confirmed in item 4 above), internal-snow-layer freeze-thaw driven by a fixed `273.15`/`2.7185` pure-water reference -- not the matric-potential-depressed `TFREEZ` used for soil/litter (`:2374-2428`; deliberate, since bulk snow has no matric potential term). Zig: `ecosys-ng/src/soil/water/snow_surface_atmosphere_exchange.zig` (sha256 `9A1CEC20EBE21BC42FCC0637E51941FFDA28AB72E760654B178EF16B1CCEEC26`) covers `watsub.f:1238-1334` (surface radiation/evaporation) with exact-formula citations; `ecosys-ng/src/soil/water/snow_phase_change.zig` (sha256 `3F95087F6D903569F01030C65F7CF8FAB7C6603C8111CDCDA92B8DD678FD68EF`) covers the `2.7185`/`273.15` internal-layer freeze-thaw; `ecosys-ng/src/soil/water/snow_base_thermal_coupling.zig` (sha256 `69E19F4255BF2C5E1E9923A6DE22D974C648D4B565773337B641F804E3D92903`) covers the snow-to-bare-soil (`:1773-1796`) and snow-to-litter (`:1861-1872`,`:2025-2033`) conductive interfaces, explicitly documenting two deliberate, reviewed departures (no substep-count divisor; snow-side equalization capacity apportioned by cover fraction) rather than silent drift. Structurally sound; no functional gap found across this sub-range.

### 7. Under-snow soil-surface freeze-thaw uses the litter's heat capacity instead of the soil's own (`VHCPR2` for `VHCPG2`) -- legacy Fortran defect, filed as `issue-048`

`watsub.f:2064-2095` (soil-surface freeze-thaw when snow AND litter are both present, computing `HFLFGX`/`HFLFG2`/`FLFG2`) uses `HFLFGX=VHCPR2*(TFREEZ-TKS22)*XNPRS/(1.0+6.2913E-03*TFREEZ)` at `:2082-2083` -- `VHCPR2` is the **litter's** heat capacity (assigned at `:1230`), not `VHCPG2`, the soil's own heat capacity (`=VHCP1(NUM(NY,NX),NY,NX)`, assigned in scope at `:1233` and not reassigned until `:2572`, long after this block executes). This is confirmed as a genuine outlier, not an intentional lumped treatment, by direct comparison against **two** structurally parallel, correct sibling blocks read this pass: the litter's own freeze-thaw immediately above it (`:1938-1972`, correctly uses `VHCPR2`) and the exposed/no-snow soil freeze-thaw later in the same routine (`:2788-2820`, correctly uses `VHCP1(NUM(NY,NX),NY,NX)`). Every other `VHCPR2`/`VHCPG2` pairing in the surrounding code (`:2025-2033`'s `TKY` snow-litter equilibrium, `:2142-2143`'s litter-soil equilibrium, `:2561-2582`'s temperature updates) correctly keeps the two variables distinct -- this is the sole instance where they are conflated, consistent with a copy-paste-and-incomplete-rename origin (litter block cloned to make the soil block, with the `VHCPR2` inside the `HFLFGX` formula missed). Filed as `audit/issues/issue-048-watsub-under-snow-soil-freeze-thaw-uses-litter-heat-capacity.md` rather than resolved here, since the practical magnitude (litter heat capacity is typically much smaller than a full soil layer's, so this would throttle -- not accelerate -- the oracle's under-snow top-layer freeze/thaw rate) has not yet been quantified against a specific run, and whether Zig's generic per-cell freeze-thaw solver (`ecosys-ng/src/surface/temperature_solver.zig` + `ecosys-ng/src/surface/litter_freeze_thaw_energy_limit.zig`) actually receives the soil's own heat capacity for this exact under-snow-with-litter soil cell has not been traced to its specific call site. **Disposition: proposed `legacy-defect-corrected` pending independent review and the follow-up in issue-048; not finalized here.** Flagged as a plausible third candidate mechanism for `issue-024`'s still-open freeze-thaw divergence (added there as an incidental note, not a reopening).

### 8. Exposed (snow-free) litter/soil surface energy balance -- `preserved`

`watsub.f:2605-3418`: parallel to item 6/7's under-snow treatment, this range independently recomputes litter and soil surface radiation, evaporation-condensation, freeze-thaw (`:2788-2820`, verified correct per item 7 above), and litter-soil conductive/diffusive coupling for the snow-free fraction of the surface (`FSNX(NY,NX).GT.0`). The litter freeze-thaw block here (`:3145-3161`) is the one already covered by `ecosys-ng/src/surface/litter_freeze_thaw_energy_limit.zig` (sha256 `E473D4620EB10E0CC6FC64F05383842214518F40D36D3BB06D2E0CA56E1305AF`) and its "energy-led, mass-capped" formulation is independently confirmed correct against this pass's own line-by-line read (`TFREEZ`, `HFLFRX`, `HFLFR2`, `FLFR2` at `:3145-3157` all match the module's documented derivation exactly). `ecosys-ng/src/surface/temperature_solver.zig` (sha256 `079282B03594A53F4AEA224C75CB32D80BAFAC7FC9EC711EC8669EB241836E34`) generically wraps this per-cell rather than duplicating litter/soil blocks by hand, which is *why* it does not reproduce item 7's defect (see item 7's Zig-side caveat).

### 9. Litter-soil surface water exchange (exposed surface) reuses the same `HCND`/`JK` conductivity table already flagged in item 1 -- confirmed consistent, not a new finding

`watsub.f:3634-3641`: the litter-soil water flux (`FLQX`, `AVCNDR`) under exposed conditions reads `CNDR=HCND(3,K0,0,NY,NX)` and `CND1=HCND(3,K1,NUM(NY,NX),NY,NX)*FKSAT` -- the same class-interpolation `HCND` table item 1 already documented as a confirmed-benign legacy artifact (`PR-COND-TABLE-001`, since replaced in Zig by a direct scalar Mualem-van Genuchten read). No new call site or asymmetry found here; recorded only to close out this line range's coverage.

### 10. Pond overflow, overland flow into macropores, film thickness, Manning runoff generation, and interior downslope runoff/snow-drift redistribution -- `preserved`

`watsub.f:3737-4128` (this pass's assigned "pond/runoff/drift routing" range, overlapping the concurrent snowpack pass's coverage through `:3800` by 63 lines, re-confirmed rather than skipped): pond-surface overflow to soil micropores (`FLQR`, `:3739-3755`), overland flow into macropores when litter retention capacity is exceeded (`FLQHR`, `:3768-3784`), litter/surface-soil water film thickness for gas exchange (`FILM`, `:3794-3801`, already independently cited by `plant_root_gas_exchange.zig`), Manning's-equation runoff generation (`XVOLW`/`VX`/`QRM`/`QRV`, `:3803-3866`), and the `DO 4310 N=1,2 / DO 4305 NN=1,2` interior E/S-vs-W/N loop computing both downslope runoff (`QR1`/`HQR1`, `:3946-4020`) and downslope snow drift (`QS1`/`QW1`/`QI1`/`HQS1`, `:4049-4126`) between adjacent grid cells. Checked this "N parallel blocks" structure both across the runoff/snow-drift sibling pair and across the E/S vs W/N sub-blocks within each: symmetric and internally consistent, including the `N4B.GT.0.AND.N5B.GT.0` boundary-index guard present identically in all four blocks.

One confirmed-benign legacy quirk found and not escalated: in the outer "no source outflow at all" `ELSE` branch (`QRM(M,N2,N1).LE.ZEROS`, `:4009-4020`, and its snow-drift analogue `:4111-4126`), the west/north direction flag is set `IFLBM(...)=0`/`IFLBMS(...)=0` rather than the `1` used by every other west/north assignment in this file, including the "live but zero-magnitude" sub-case immediately above it (`:3994-3999`). Traced this flag's only two downstream readers (`trnsfr.f:6784,6804`, `erosion.f:449`): both gate a *subtraction* of a quantity computed proportional to the same already-zero flow, so the wrong flag value multiplies against zero and has no numerical effect under the current formula structure -- dead-but-latent, not a live divergence. Zig's `ecosys-ng/src/surface/runoff.zig` (sha256 `FE2063877DCB967C504D576F44A3BF63FC5D23F96041C155B68DCC98A28E4415`) and `ecosys-ng/src/soil/water/snow_drift_routing.zig` (sha256 `D0B0BAE11DA3D963A4B0B5C7156CE54CDE2DD9DCF76D24EE0CCAFAAAE6A2F264`) structurally avoid the ambiguity: each direction is its own signed field computed independently, so there is no equivalent "flag disagrees with magnitude" state representable in Zig.

Canopy-air aerodynamic exchange and boundary-layer conductance export (`:4194-4370` -- `TKQG`/`VPQG`, `RAGC`/`RAGD`, `PARR`/`PARG`) falls inside this dossier's named `:3737-4370` range by line number but is not pond/runoff physics; confirmed its Zig counterpart exists (`ecosys-ng/src/surface/ground_air_exchange.zig`, sha256 `EA6654EE5286D6018178C58812888D75BACCE3516DE35B649BC2E1A721DD1D75`) but was not re-derived equation-by-equation this pass -- recorded so this line range's coverage is not silently skipped.

### 11. Domain-boundary snow drift is legacy dead code but a live Zig production path -- `unresolved`, filed as `issue-049`

`watsub.f:3868-4128`'s **interior** (cell-to-cell) snow drift is active legacy code (item 10 above). Its domain-**boundary** counterpart, `:5675-5720` (banner "BOUNDARY SNOW REDISTRIBUTION FROM SNOWPACK (DISABLED)"), is entirely commented out by the original authors -- the only live statements unconditionally zero every boundary snow-transfer quantity (`QS1`/`QW1`/`QI1`/`HQS1`/`IFLBMS=0`) regardless of wind, slope, or the `RCHQF`/`IRCHG` boundary-openness test that the structurally parallel, **active** boundary **runoff** block (`:5556-5667`) does honor. In every legacy run, snow cannot leave the domain through a lateral boundary. Zig's `ecosys-ng/src/soil/water/snow_drift_routing.zig` `produceAndRoute` (`eligibleDirection`, `:418-427`) grants eligibility to an open domain boundary and books a real, tested export to the landscape boundary ledger (test "open QSX drift books physical and all-element boundary activity", `:711-775`). This is wired into the real production hourly loop -- `stages/hourly_heat_water_solute.zig:5449-5474`'s `advanceSnowDrift` passes `context.surface_erosion.{east,west,south,north}_boundary_open`, the *same* mask `stages/hourly_process_driver.zig:42-64`'s `refreshSurfaceBoundaryOpenFlags` derives from the site file's `surface_runoff_boundary_fraction` (confirmed nonzero on a real parsed site fixture, `state/site.zig:229`) to faithfully reproduce legacy's *runoff* boundary gating -- not gated closed for snow drift specifically. Whether the in-scope Ottawa deck's actual site file ever makes this path live has not been checked this pass. Full detail, falsifiable cause, and suggested next action in `audit/issues/issue-049-watsub-domain-boundary-snow-drift-legacy-disabled-zig-enabled.md`.

### 12. Water-table/tile-drain discharge-eligibility flags -- `preserved`; discharge/recharge flux-formula family -- `legacy-defect-corrected` (undocumented), filed as `issue-050`

`watsub.f:5285-5410`: the four parallel eligibility flags gating micropore/macropore discharge to the natural water table vs. artificial tile drain (`IFLGU`/`IFLGUH`/`IFLGD`/`IFLGDH`) are internally consistent -- checked all four against each other (the only difference between the micropore-natural and micropore-artificial inner loops, `DO 9565 LL=MIN(L+1,NL),NL` vs `DO 9568 LL=L+1,NL`, is a no-op given the enclosing `L.LT.NL` guard, not a bug). Zig's `soil/water/solver_residual.zig` (sha256 `F7C4EC006DAE315D0E9C162D2B580C8A5292343BC3975470146396D0616072E6`) reproduces this eligibility logic (`matrix_discharge_enabled`, `:432-471`) against a frozen hour-start state, matching the legacy intent documented in its own comment (`:454-457`).

The six discharge/recharge flux formulas that follow (`:5819-6145`) contain a genuine legacy "N parallel blocks, 1 outlier" pattern -- both the natural-table and tile-drain micropore-discharge formulas divide by `(RCHG+1.0)` while their four siblings (both macropore-discharge instances and both recharge instances) divide by `AMAX1(RCHG,1.0)` -- compounded by a dimensional defect (no formula divides the driving potential by an actual physical separation length). Zig's `soil/water/boundary.zig` fixes both, already tested (`GRID-INV-001`/`GRID-INV-002`/`GRID-INV-R3`, whose own test comments state "Legacy `watsub.f` carries the same defect ... so legacy agreement is inadmissible evidence"), but has no feature-register entry -- the same paperwork gap as item 5/`issue-019`. Full detail in `audit/issues/issue-050-watsub-water-table-boundary-dimensional-fix-missing-feature-entry.md`.

### 13. Net runoff/snow-drift flux bookkeeping, net soil water/vapor/heat flux accumulation, below-surface evaporation-condensation, and micropore/macropore freeze-thaw -- resolves the `:6197-6554` accounting gap; mostly `preserved`, one new `unresolved` finding

This pass read `watsub.f:6197-6554` (357 lines) in full at statement level to
resolve the accounting question raised by every prior pass's "Not covered
this pass" note. Finding: **this range is not a trivial DO-loop closeout**;
it contains real, substantive physics, and part of it (`:6208-6267`) had
already been itemized in `audit/traceability/traceability.csv` as `TRC-224`
even though no feature-dossier item text ever named it -- a
documentation/cross-referencing gap between the CSV and this dossier's prose,
not a coverage gap. The genuinely new-to-any-pass sub-range is `:6268-6554`
(287 lines).

- `:6208-6267` (already `TRC-224`, re-confirmed this pass, not re-narrated):
  net runoff/snow-drift E/S-vs-W/N flux bookkeeping (`TQR1`/`TQS1`/`TQW1`/
  `TQI1`/`THQR1`/`THQS1`), gated by the `IFLBM`/`IFLBMS` direction flags
  computed earlier (item 10/11's range) -- internally symmetric between the
  runoff and snow-drift siblings, no new finding.
- `:6269-6341` (`preserved`): net soil micropore/macropore water, vapor, and
  heat flux accumulation (`TFLWL`/`TFLVL`/`TFLWLX`/`TFLWHL`/`THFLWL`) into the
  next-existing-destination-layer variables (`N6`), then folded into the
  running total flux arrays (`FLW`/`FLV`/`FLWX`/`FLWH`/`HFLW`) consumed by
  `trnsfr.f` (per this file's own in-line documentation, already audited from
  the `trnsfr.f`/`trnsfrs.f` side this session, `feature-009`).
- `:6345-6384` (`preserved`, exact constant match): below-surface-layer
  evaporation-condensation. `VPLV=2.173E-03/TK1*0.61*EXP(5360.0*(3.661E-03
  -1.0/TK1))*EXP(18.0*PSISV1/(8.3143*TK1))` (`:6363-6365`) is the exact same
  formula (down to every constant) as Zig's `vaporLiquidEquilibrium`
  (`ecosys-ng/src/soil/water/phase_change.zig` (sha256
  `88A54A1A58972393ECEBEE71960A920A3A1724DCC2494E49B7EBC62121E461CC`),
  `:23-33`), whose own doc comment (`:21-22`) explicitly identifies itself as
  "WATSUB's below-surface VOLV/VOLW equilibrium."
- `:6386-6457` (micropore/macropore freeze-thaw): micropore block
  (`:6399-6418`) is internally consistent -- its eligibility gate and its
  driving-force formula both key on the same matric-depressed `TFREEZ`
  (`:6399`, computed from the layer's own `PSISV1=PSISM1+PSISO`). The
  macropore block (`:6430-6446`) is **not** internally consistent: its
  eligibility gate correctly compares against pure-water `273.15` (`:6430-
  6433`, appropriate since macropore water is free/gravitational, not
  matric-bound), but its driving-force formula (`HFLFH1`, `:6435-6436`)
  reuses the *same* matric-depressed `TFREEZ` from the micropore calculation
  instead of `273.15`. Confirmed this exact inconsistency is faithfully
  reproduced -- not corrected, not diverged -- in the current Zig production
  call path (`phase_change.zig`'s `freezeThaw`, `:286-302`, whose
  `threshold_temperature` at `:291` branches on `macropore` but whose
  `unlimited_heat` at `:293` always uses the depressed `freezing_temperature`;
  confirmed at the call site, `ecosys-ng/src/soil/water/phase_solver.zig`
  (sha256 `9EDA9CD994559FDC6DE189FD8565192BCE41266AAAD6282BFD7A66BC9E82C300`),
  `:1514-1521` and `:1535-1543`, both passing the identical
  `matric_plus_osmotic_potential_megapascal`). This is the fourth "N parallel
  blocks, one outlier" finding in this file this session (after `issue-048`,
  `issue-049`, `issue-050`) but a different shape: a legacy internal
  inconsistency bit-for-bit preserved into production, undocumented on either
  side. Filed as `audit/issues/issue-051-watsub-macropore-freeze-thaw-uses-micropore-depressed-freezing-point.md`.
  **Disposition: `unresolved`, pending independent review of whether to
  correct the Zig formula or document the reuse as intentional.**
- `:6459-6550` (`preserved`): total/accumulated freeze-thaw and
  evaporation-condensation tallies (`XWFLVL`/`XHFLVL`/`TWFLVL`/`THFLVL`/
  `XWFLFL`/`XWFLFH`/`XHFLFL`/`TWFLFL`/`TWFLFH`/`THFLFL`, consumed by
  `redist.f`, already audited this session as `feature-010`) and
  macro-to-micropore infiltration (`FINHL`/`FINHM`/`FINH`, `:6512-6550`).
  The infiltration formula (`FINHX=6.283*HCND(2,1,...)*AREA*(PSISE-PSISA1)
  /LOG(PHOL/HRAD)*XNPHX`, `:6513-6515`) matches Zig's
  `macroporeMatrixExchange` (`phase_change.zig:319-326`) constant-for-constant
  (`6.283`, the same log-spacing-over-radius form, the same donor/receiver
  bound structure) -- no new finding.

### 14. State-variable updates from net fluxes -- resolves the `:6554-7030` accounting gap; `preserved`, not independently re-derived equation-by-equation

`watsub.f:6554-7030` (476 lines) read in full at statement level, confirming
the scope note's "state updates" label was accurate (not a stale guess): this
is the routine's terminal `M.LT.NPH` / `ELSE` split (`:6556`/`:7007`) that
commits the substep's net fluxes into persistent state, then falls through to
`RETURN` (`:7027-7028`).

- `:6557-6615`: snowpack water/vapor/ice volume and temperature update per
  layer (`VOLS0`/`VOLW0`/`VOLV0`/`VOLI0`/`TK0`), with a cascading fallback
  (`VHCPWM(M+1,L,..).GT.VHCPWX` -> real update; else layer 1 takes `TKQG`,
  deeper layers inherit the layer above, `:6588-6595`). This exact fallback
  is the one already independently confirmed by
  `ecosys-ng/src/soil/water/snow_inactive_temperature.zig`'s own header
  comment ("WATSUB assigns ground-air temperature to layer one and the
  preceding snow temperature to deeper layers whenever `VHCPWM2 <= VHCPWX`"),
  found via keyword search this pass, not re-derived line-by-line.
- `:6626-6638`: snow-drift net flux (`TQS1`/`TQW1`/`TQI1`/`THQS1`, from item
  13's bookkeeping) applied to the top snow layer only, with the same
  cascading temperature fallback.
- `:6655-6683`: if the snowpack's top layer drops to/below the minimum heat
  capacity while the ground-surface air temperature is above freezing, all
  remaining snowpack mass/heat is transferred to the litter layer
  (`XFLWSX`/`XFLWWX`/`XFLWVX`/`XFLWIX`/`XHFLWX`, consumed by `redist.f`) --
  a "snowpack disappears" terminal case, structurally a one-off rather than
  part of any parallel-block family.
- `:6710-6743`: surface litter water/vapor/ice volume and temperature update,
  folding in runoff (`TQR1`/`THQR1`, item 13) and the litter's own
  evaporation-condensation/freeze-thaw fluxes (already audited, items 6-9);
  `:6744-6745` blends snow-cover-weighted and snow-free-weighted ground
  temperature (`TKGS=FSNW*TK0(1)+FSNX*(TK1(0)*CVRDW+TK1(NUM)*BAREW)`) --
  matches the cover-fraction-weighting convention already confirmed
  elsewhere in this file (item 6's `snow_base_thermal_coupling.zig`).
- `:6808-6968`: the main per-soil-layer state commit loop (`DO 9785
  L=NUM,NL`) -- water/vapor/ice/macropore volumes, porosity-derived air
  volumes with a `BKDS.GT.ZERO`/else split for degenerate (zero-bulk-density)
  layers, `THETWX`/`THETIX`/`THETPX`/`THETPY` bulk concentrations, `FMAC`/
  `CNDH1` macropore-fraction-scaled conductivity, and the layer's own
  heat-capacity-gated temperature update (`:6907-6926`, same
  `VHCP1.GT.VHCPRX` guard pattern as the snowpack/litter blocks above it,
  falling back to `TKQG`/`TK1(L-1)` for degenerate layers). Includes one
  fully-commented-out diagnostic feature (`:6887-6894`, "artificial soil
  warming," an experiment-only heat-flux injection guarded by hardcoded
  `I`/`NX`/`NY`/`L` bounds) -- dead code in every configuration, not a
  production path.
- `:6980-7025`: pond-surface-loss bookkeeping -- if the surface layer's bulk
  density and heat capacity indicate the pond has fully evaporated, `NUM`
  (the active surface-layer index) is advanced to the next real layer and its
  flux values are cached (`FLWNX`/`FLVNX`/`FLWXNX`/`FLWHNX`/`HFLWNX`) for
  `redist.f`; the `ELSE` branch (`M.EQ.NPH`, the final substep) instead reuses
  those cached values (`FLWNU`/etc.) rather than recomputing, since the full
  per-substep state commit above only runs for `M.LT.NPH`. This is an
  intentional last-substep shortcut, not a parallel-block asymmetry to flag.

**Disposition: `preserved`** at the structural/formula level for every block
read. **Caveat, matching this dossier's own items 9/10 precedent**: given
this pass's time budget, Zig counterparts were confirmed to exist and match
at the function/module level (`snow_inactive_temperature.zig`,
`phase_solver.zig`, `temperature_solver.zig`, and the snow/litter/soil update
paths already cited across items 1-13) but the ~416 executable lines of the
per-soil-layer commit loop (`:6808-6968`) specifically were **not**
independently re-derived term-by-term against a single named Zig owner this
pass -- flagged honestly rather than claimed, consistent with the contract's
"missing evidence is never a pass" rule. No new defect found in this range
beyond item 13's freeze-thaw finding, which lands one section earlier.

## Not covered this pass

None outstanding for this file. Both of the two previously-open accounting
gaps (`:6197-6554`, `:6554-7030`) are now closed by items 13-14 above. Combined
with items 1-12's prior closure of `:3737-4370`, `:5264-6197`, and the
concurrent snowpack pass's closure of `:1-3800`, **`watsub.f`'s depth-read is
now complete end to end (all 7,030 lines)** -- the sixth file this session to
reach that state, after `redist.f`/`feature-010`, `uptake.f`/`feature-004`,
`trnsfr.f`+`trnsfrs.f`/`feature-009`, and `solute.f`/`feature-017`. See the
closing tally below for the residual scope (open issues, unreviewed items)
that depth-read completeness does not by itself resolve.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (items 1-5); continued
2026-09-19 (items 6-9, snowpack surface-energy-balance range; items 10-12,
pond/runoff/drift and boundary/water-table/tile-drain ranges, a separate
parallel fork on the same file; items 13-14, the final `:6197-6554` and
`:6554-7030` accounting-gap closure, this pass). Independent reviewer: not
yet done for any item. Decision: NOT_ASSESSED for gate purposes. This pass's
read was static source analysis only (no build, run, or binary execution),
per this session's read-only constraint; `git status --short` was confirmed
clean and no `zig`/`gfortran`/`ecosys_ng`/`ecosys_x`/`ecosys_oracle` process
was running before starting.

### Closing tally for this dossier

**`watsub.f`'s depth-read is now complete (7,030/7,030 lines accounted for
by at least one pass's item), mirroring the full closures already reached
this session for `redist.f`, `uptake.f`, `trnsfr.f`+`trnsfrs.f`, and
`solute.f`.** Depth-read completeness is a distinct, narrower claim than
"fully reviewed" -- see the residual scope below.

**Final item count and dispositions**: 14 numbered items across all passes.
- `preserved`: items 2, 3, 4, 6, 8, 9, 10, 12 (eligibility-flag half), 13
  (all but the freeze-thaw sub-finding), 14 -- the dominant disposition
  throughout this file, consistent with `watsub.f` being a translation-target
  routine rather than a locus of approved physics changes (those live in
  `feature-001`/`feature-002`, cross-referenced but not re-litigated here).
- `replaced-by-approved-feature`: items 1 (Mualem-van Genuchten conductivity,
  `feature-002`), 5 (macropore-face unification removing a legacy
  gravity-only defect).
- `legacy-defect-corrected` (undocumented in the feature register):
  item 12's discharge/recharge-formula half (`issue-050`).
- Proposed `legacy-defect-corrected` pending review: item 7 (`issue-048`).
- `unresolved`: item 11 (`issue-049`), item 13's new freeze-thaw finding
  (`issue-051`).
- Paperwork-only registration gaps (functionally sound, no feature entry):
  item 5 (`issue-019`), item 12 (`issue-050`, doubles as the disposition note
  above).

**Full list of open issues touching this file**: `issue-015` (shared,
project-wide stiff-solver frontier -- `watsub.f` is upstream of but not
itself the cause of that convergence wall), `issue-019` (macropore-flow
unification missing a feature-register entry, paperwork), `issue-048`
(under-snow soil freeze-thaw uses the litter's heat capacity, proposed
`legacy-defect-corrected` pending review), `issue-049` (domain-boundary snow
drift: legacy-disabled, Zig-enabled, `unresolved`), `issue-050`
(water-table/tile-drain dimensional fix missing a feature-register entry,
paperwork), `issue-051` (macropore freeze-thaw reuses the micropore's
matric-depressed freezing point instead of pure water, `unresolved`, new this
pass).

**What has not been done, stated plainly**: (a) no item in this dossier has
an independent reviewer pass; (b) no build, test, or run evidence backs any
item -- every disposition rests on static source comparison only, per this
session's read-only constraint; (c) item 14's `:6808-6968` per-layer commit
loop was matched at the module level, not re-derived term-by-term against a
single named Zig owner; (d) `issue-049`/`issue-050`/`issue-051`'s own
suggested next actions (site-file check; new feature-register entry;
review-and-fix-or-document decision) have not been executed. Recommend the
next session prioritize an independent review pass over further depth-reading
for this file, since depth-read is now the completed half of the work and
review is the entirely-undone half.
