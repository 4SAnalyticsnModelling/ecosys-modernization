# Feature ID: FEAT-005-NITRIFICATION-DENITRIFICATION-MINERALIZATION

Status: ASSESSED (source-audit; `nitro.f` is confirmed 4,592 lines (corrected from an earlier ~7000-line estimate); cumulative direct-read coverage across five passes ~100% -- see fifth-pass closing summary below. Independent reviewer pass and gate sign-off still pending; disposition remains source-audit-level, not a gate PASS.)

## Addendum 2026-09-19 (fifth pass, CLOSES nitro.f's remaining gaps): parameter/setup block, nitrification competition+inhibition setup, methanotrophs/O2 uptake solver, growth-respiration/DOC-DON-DOP partitioning+recycling+humification -- one real new defect found, two loose ends resolved

Read-only, static-analysis-only pass (no `zig build`, no binary execution, no
test run). Confirmed `git status --short` clean and no
`zig`/`gfortran`/`ecosys_ng`/`ecosys_x`/`ecosys_oracle` process running before
starting (a concurrent `hour1.f` pass had already committed and cleared by
the time this pass began; its `issue-053` and TRC rows were re-checked and
avoided by number).

**Full statement-level read this pass, the dossier's four remaining named
gaps:** `nitro.f:160-900` (~740 lines: parameter/decomposition-rate setup,
per-layer total substrate/biomass aggregation, DOC/acetate/O2/NH4/NO3/PO4
competition-fraction setup shared across microbial+root+mycorrhizal
populations, and the aerobic-heterotroph/fermenter/acetotrophic-methanogen
respiration-potential chain RGOCY->RGOMP->ROXYP), `:1060-1150` (NH4
competition-factor setup and nitrification-inhibition decay preceding the
already-audited NH3/NO2 oxidation reactions), `:1335-1666` (methanotroph CH4
oxidation with its own sub-hour gas-dissolution loop, the shared quadratic O2
uptake solver used by all aerobes, and the RCO2X/RCH3X/RCH4X/RH2GX
respiration-product allocation), and `:2482-2918` (microbial
maintenance/growth-respiration split, non-symbiotic N2 fixation respiration
coupling, DOC/DON/DOP/acetate uptake driven by growth respiration,
senescence-triggered decomposition, and C:N:P recycling/humification of
decomposition products).

**`:160-900` setup and aerobic/anaerobic respiration potential** -- Zig:
`ecosys-ng/src/soil/microbial/respiration_activity.zig`
(`aerobicSubstrateLimitedRespiration`, `totalActivity_g_c_per_step`,
`totalSurfaceActivity_g_c_per_step`) and
`ecosys-ng/src/soil/microbial/anaerobic_growth_respiration.zig` (fermenter
and acetotrophic product-energy feedback, `nitro.f:556-557,918-928,1000-1004`,
extensively self-documented with a source-statement table and its own
`bind_nitro_001_double_mutation_analysis` provenance note). Independently
re-derived `aerobicSubstrateLimitedRespiration` term-for-term against
`nitro.f:855-873` (`FSBSTC`/`FSBSTA`/`RGOCY`/`RGOCZ`/`RGOAZ`/`RGOCX`/`RGOAX`/
`RGOCP`/`RGOAP`/`RGOMP`/`ECHZ`/`ROXYM=2.667*RGOMP`) -- exact match including
the min-of-(microbial-limited, supply-limited) structure. `preserved`.

**`:1060-1150` NH4 competition-factor setup and nitrification-inhibition
decay -- REAL DEFECT FOUND.** The inhibition-decay math itself
(`ZNFNI=ZNFNI*(1-RNFNI*TFNX*XNFH)`, `ZNFN4S=ZNFN0-ZNFNI/(1+CNH4S/ZHKI)`,
`nitro.f:1113-1115`) is exactly reproduced by
`ecosys-ng/src/soil/microbial/nitrification.zig`'s `calculatePotential`
(`updated_inhibition`/`non_band_inhibition`/`band_inhibition`, lines 80,90-91)
-- `preserved`. **But the NH4/NO2 competition-fallback fractions
(`nitro.f:1088-1097` FNH4/FNB4 vs `:1209-1218` FNO2/FNB2) are conflated in
Zig**: `nitrification_step.zig`'s `makeZone` sets one `Zone.fallback_available_fraction`
field to the nitrate-zone volume fraction (`fractions.nitrate_non_band/band`,
correct for the NO2-oxidizer's own fallback, which legacy aliases to
`FNO3S`/`FNO3B` at `nitro.f:338-339`) and reuses that *same* field for the
NH3-oxidizer's own fallback in `nitrification.zig:81-82`, where the legacy
instead uses the independently-set ammonium-zone fraction (`FNH4S`/`FNHBS`).
Confirmed via `charge_classification.zig`'s own test that `ammonium_non_band`
and `nitrate_non_band` are genuinely independent runtime values (test uses
0.75 vs 0.65), not aliases. This is exactly the project's recurring "N
parallel blocks, 1 outlier" pattern: two sibling competition-fallback
formulas that must each use their own zone's volume fraction, one of which
was miswired to the other's. Reachable at minimum on hour 1 of every run and
whenever a layer's aggregate ammonium-demand history resets (new/thawed
layer), and only numerically inert when a deck's NH4 and NO3 band geometries
happen to coincide. Filed as
`audit/issues/issue-054-nitro-nitrification-ammonium-fallback-uses-nitrate-zone-fraction.md`.
**Disposition: `unresolved`** (confirmed defect, impact not yet quantified --
needs a build/run to measure, out of scope for this static pass).

**`:1335-1666` methanotrophs, O2 uptake solver, respiration-product
allocation** -- Zig: `ecosys-ng/src/soil/gas/methane_step.zig` /
`methane_oxidation.zig` (CH4 dissolution/oxidation sub-hour loop),
`ecosys-ng/src/soil/gas/oxygen_solver.zig` (`activeUptake`, the shared
implicit O2 quadratic solve used by all aerobic populations), and
`ecosys-ng/src/soil/microbial/respiration_products_step.zig`
(`applyTile`, RCO2X/RCH3X/RCH4X/RH2GX product split). Independently
re-derived the O2 solver's quadratic algebraically against
`nitro.f:1541-1543` (`B=-RUPMX-DIFOX*OXKM-X`, `C=X*RUPMX`,
`RMPOX=(-B-SQRT(B*B-4*C))/2`): expanding `B^2-4C` gives exactly
`(demand-x)^2 + half_saturation_term*(2*(demand+x)+half_saturation_term)`,
matching `oxygen_solver.zig:203` verbatim, and confirmed the stabilized
`2*(demand/denominator)*x` form is algebraically identical to
`(sum-root)/2` via the same expansion (`sum^2-discriminant=4*demand*x`) --
the Zig form is a numerically-stable rearrangement, not a different
equation. `preserved`. The RCO2X/RCH3X/RCH4X/RH2GX product split
(`nitro.f:1638-1665`, including the `0.333`/`0.667`/`0.111` fermenter split
and the `0.50`/`0.50` acetotrophic-methanogen split) is reproduced exactly in
`respiration_products_step.zig:78-89`, with a well-documented, independently
verified-safe edge case for the K=5 (autotrophic complex) branch that legacy
handles differently (`RCH4X=RGOMO`, no CO2/acetate split) but which the Zig
comment proves is unobservable today because an upstream substrate-loop
clamp (`substrate_uptake_step.zig`) never populates K=5's
`actual_aerobic_respiration_g_c`. `preserved`.

**`:2482-2918` maintenance/growth respiration, N2 fixation coupling,
DOC/DON/DOP uptake, recycling, decomposition, humification, senescence** --
Zig: `ecosys-ng/src/soil/microbial/metabolism.zig` (`maintenance`,
`nonsymbioticNitrogenFixation`, `respirationDrivenSubstrateUptake`,
`recyclingFractions`, `decompose`, `acceleratedSenescence`). Independently
re-derived every equation term-for-term against direct re-reads of
`nitro.f:2496-2913`: `maintenance()`'s `growth_respiration_g_c=max(0,oxygen_limited-total)`/
`senescence_respiration_deficit_g_c=max(0,total-oxygen_limited)` matches
`RGOMT=AMAX1(0,RGOMO-RMOMT)`/`RXOMT=AMAX1(0,RMOMT-RGOMO)` exactly (`:2507-2509`);
`respirationDrivenSubstrateUptake`'s `aerobic_carbon`/`denitrification_carbon`/
`doc`/`acetate`/`dissolved_organic_nitrogen`/`dissolved_organic_phosphorus`
match `CGOMX`/`CGOMD`/`CGOQC`/`CGOAC`/`CGOMN`/`CGOMP` exactly, including the
`K.LE.4` vs autotrophic branch split (`:2580-2613`); `recyclingFractions`'s
carbon/nitrogen/phosphorus balance clamps match `CCC`/`CNC`/`CPC`/`RCCC`/
`RCCN`/`RCCP` exactly (`:2627-2646`); `decompose()`'s
`rate=sqrt(temperature_response)*water_response*basal_rate*microbial_carbon_response*dt`
matches `SPOMX=SQRT(TFNX)*WFNG*SPOMC(M)*SPOMK*XNFH` exactly (`:2695`), and its
recycled/humified/microbial_residue split matches `R3OMC`/`RHOMC`/`RCOMC`
exactly including the humified-carbon-not-litterfall-carbon multiplier used
in the N,P humus-ratio ceiling (`:2699-2748`); `acceleratedSenescence`'s
gate (`enabled = deficit>negligible AND total_maintenance>negligible AND
recycling.carbon>0`) and `deficit_fraction=deficit/total` match the
`IF(RXOMT.GT.ZEROS.AND.RMOMT.GT.ZEROS.AND.RCCC.GT.ZERO)` gate and
`FRM=RXOMT/RMOMT` exactly (`:2767-2769`), with the same recycled/humified/
residue split reused (`:2777-2801`). No asymmetry defect found anywhere in
this range. **Disposition: `preserved`.**

**Loose end 1 of 2, RESOLVED (with a scope correction to prior passes'
description):** `nitrogen_state_update.zig`'s `applyZone` (the standing open
item since pass 1) was traced directly. It is a small, private, 20-line
function (`nitrogen_state_update.zig:1438-1457`) called exactly twice per
layer (non-band, band; call sites at lines 214-215) that commits *only* the
mineral-N triplet (ammonium/nitrate/nitrite) from nitrification +
heterotrophic denitrification + autotrophic (nitrifier-)denitrification +
chemodenitrification fluxes. Verified its mass-balance structure directly:
`ammonium -= ammonia_oxidation + autotrophic_ammonium_oxidation`;
`nitrate += nitrite_oxidation - nitrate_reduction`; `nitrite = nitrite +
ammonia_oxidation + autotrophic_ammonium_oxidation + nitrate_reduction -
nitrite_oxidation - heterotrophic_nitrite_reduction -
autotrophic_nitrite_reduction - chemo_nitrite_reduction` -- this is exactly
the NH4->NO2->NO3 flow topology independently confirmed against the
Fortran's RVOXA/RNNO2/RDNO3/RDNO2/RDN2/RCN2O flux family in the third-pass
addendum (denitrification cascade) and the fourth-pass chemodenitrification
finding. **`applyZone` itself is `preserved`, verified correct.**
**Correction**: the fourth-pass addendum's claim that `applyZone`'s "scope
now effectively covers... decomposition, priming, colonization" is
overclaimed and is corrected here. Those organic-pool (OSC/OQC/ORC/OHC/OMC)
commits are performed by *separate* helpers in the same file
(`addPool`/`subtractPool` at lines 318-320,434-449, and
`applyMicrobialExchange` for the mineralization-immobilization
ammonium/nitrate/phosphate exchange at lines 216-223) inside the same
per-layer orchestrator `state_updateLayer` (line 70) -- `applyZone` proper
never touches organic state. The correct broader claim is that
`state_updateLayer`, not `applyZone`, is the single per-layer state-commit
entry point that composes all of these narrower, independently-named
helpers. This does not change any prior pass's disposition (all the
decomposition/priming/colonization/sorption/combustion/mixing equations
already verified `preserved` in earlier passes remain `preserved`); it only
corrects which function name owns which commit.

**Loose end 2 of 2, RESOLVED:** `Z4MX`/`Z4KU`/`Z4MN`/`ZOMX`/`ZOKU`/`ZOMN`
(`nitro.f:154-155`: `Z4MX=1.4E-02, Z4KU=0.40, Z4MN=0.0125, ZOMX=1.4E-02,
ZOKU=0.35, ZOMN=0.03`) checked against
`ecosys-ng/src/soil/nutrients/nitrogen_parameters.zig`'s
`MicrobialMineralExchangeParameters` struct, with production numeric values
found at `ecosys-ng/src/surface/autotrophic_complex_step.zig:978` and
confirmed against the production config-string format
(`"soil_microbial_mineral_exchange 0.014 0.0125 0.40 0.014 0.03 0.35 ..."`
found in a delimited-input test): `ammonium_maximum_uptake_g_n_per_m2_h=0.014`
(=`Z4MX`), `ammonium_minimum_concentration_g_n_per_m3=0.0125` (=`Z4MN`),
`ammonium_half_saturation_g_n_per_m3=0.4` (=`Z4KU`),
`nitrate_maximum_uptake_g_n_per_m2_h=0.014` (=`ZOMX`),
`nitrate_minimum_concentration_g_n_per_m3=0.03` (=`ZOMN`),
`nitrate_half_saturation_g_n_per_m3=0.35` (=`ZOKU`). All six constants match
exactly. `CNOMC` (max microbial N:C ratio) was already independently
confirmed used correctly throughout this and prior passes (e.g. `:2534`
`RGN2P` derivation, `:2630` `CCC` derivation) via the shared
`nitrogen_parameters`/microbial-state plumbing -- no separate constant-table
check needed beyond the equation-level verification already done.
**Disposition: `preserved`.**

**Cross-check against other files' findings:** none of this pass's items
overlap with `solute.f`'s open issues, `starte.f`'s partial coverage,
`redist.f`'s/`watsub.f`'s closed audits, or the concurrent `hour1.f` pass
(`issue-053`, unrelated). `issue-054` is the only new open item.

**Coverage:** this pass added the four remaining named gaps
(`:160-900,1060-1150,1335-1666,2482-2918`, ~866 lines). Combined with all
four prior passes, `nitro.f`'s full 4,592 lines are now covered at
statement level. See closing summary below.

## Closing summary (nitro.f, five passes, 2026-09-18/2026-09-19)

**Final tally:**
- **Lines read at statement level: 4,592 of 4,592 (100%)**, across five
  passes (pass 1: nitrification/denitrification/mineralization backbone +
  scope correction from ~7,000 to 4,592 lines; pass 2 (2026-09-18
  follow-up): methanogenesis, N2 fixation, litter mineralization; pass 3:
  denitrification cascade completion + chemodenitrification; pass 4:
  SOC/residue/sorbed decomposition, priming, sorption, litter colonization,
  layer mixing, fire/combustion, gas-flux aggregation; pass 5 (this
  addendum): parameter/setup block, nitrification competition+inhibition
  setup, methanotrophs/O2 solver, growth-respiration/DOC-DON-DOP
  partitioning+recycling+humification).
- **Dispositions:** the overwhelming majority `preserved` (functional-form
  and constant-level exact matches, independently re-derived against direct
  Fortran reads, not trusted from comments alone). Two approved-feature
  additions noted in earlier passes (`NITRO-N2FIX-SUPPLY` dissolved-N2
  mass-conservation bound). One already-closed `legacy-defect-corrected`
  sub-finding (`GAS-METHANOGENESIS-DOUBLE-0.111-001`, hydrogenotrophic
  methanogenesis). Two `unresolved` items: `issue-020` (litter NO3 `AMAX1`
  anomaly, Zig behavior almost certainly correct but undocumented) and this
  pass's new `issue-054` (nitrification ammonium-fallback zone-fraction
  conflation, confirmed defect, unquantified impact).
- **Zig homes confirmed across all passes:**
  `ecosys-ng/src/soil/microbial/` (nitrification, denitrification,
  autotrophic/chemodenitrification, methanogenesis, respiration_activity,
  anaerobic_growth_respiration, metabolism, layer_mixing,
  respiration_products_step, nitrogen_exchange_step, phosphorus_exchange_step,
  nonsymbiotic_nitrogen_fixation_step), `ecosys-ng/src/soil/organic/`
  (decomposition_step, priming_step, sorption, litter_colonization_step,
  combustion), `ecosys-ng/src/soil/biogeochemistry/`
  (organic_substrate_decomposition, organic_priming_exchange,
  organic_matter_fire_exchange), `ecosys-ng/src/soil/gas/`
  (methane_step, methane_oxidation, oxygen_solver, oxygen_allocation,
  biogeochemical_gas_aggregation), `ecosys-ng/src/soil/nutrients/`
  (nitrogen_state_update, nitrogen_parameters, reactive_nitrogen_state,
  competition_history), and `ecosys-ng/src/surface/` (the litter-surface
  siblings of most of the above).
- **Both standing loose ends from pass 1 resolved this pass**: `applyZone`
  verified correct for its actual (narrower-than-previously-described) scope;
  `Z4MX`/`Z4KU`/`Z4MN`/`ZOMX`/`ZOKU`/`ZOMN` constants verified identical.
- **What still needs human/reviewer attention**: `issue-054` (new, needs a
  build/run to quantify impact and a scope decision on whether it is
  material enough to fix before v1.0.0); `issue-020` (needs a formal review
  record, not a fix); an independent reviewer pass on all five addenda
  (none of `feature-005`'s content has been independently re-verified by a
  separate reviewer yet, per contract's "Independent review is a separate
  pass with evidence, not multiple agents agreeing on a summary").
- **Not in scope for this static pass**: no build, run, or test was
  performed; `issue-054`'s numerical impact is unmeasured; conservation/
  physical-acceptance checks for any of these equations were not attempted
  (that is a G2 concern, not G1 source audit).

## Addendum 2026-09-19 (fourth pass): SOC/residue/sorbed decomposition, priming, sorption, litter colonization, layer mixing, fire/combustion, gas-flux aggregation (`nitro.f:2973-4592`) -- the largest remaining block, all clean

Read-only static pass. Confirmed no `zig`/`gfortran`/`ecosys_ng`/`ecosys_oracle` process running before starting; `git status --short` showed only a concurrent `hour1.f` pass's files modified (`audit/features/feature-006-...`, `audit/traceability/traceability.csv`, `audit/issues/issue-052-...`), confirmed unrelated and left untouched. Renumbered around that concurrent agent's `TRC-236`/`TRC-237` and `issue-052` by re-checking both files immediately before writing and again immediately before committing.

**Full statement-level read this pass:** `nitro.f:2973-4592` (~1,620 lines), the dossier's previously-flagged largest remaining gap. This is the file's heterotrophic decomposition/priming/redistribution/fire block, applied per soil layer L=0..NL and substrate-microbe complex K=0..KL (KL=2 at the litter surface L=0, KL=4 in soil layers; microbial biomass additionally spans K=5 for the autotrophic complex).

**Decomposition of structural/residue/sorbed substrates** (`:3182-3458`, RDOSC/RDOSN/RDOSP structural; `:3300-3350` lignin humification RHOSC->POC K=3 for K<=2 only, remainder RCOSC->DOC; `:3352-3398` microbial residue RDORC/RDORN/RDORP; `:3400-3458` sorbed RDOHC/RDOHN/RDOHP/RDOHA) -- Zig: `ecosys-ng/src/soil/organic/decomposition_step.zig` (`applyTile`) and `ecosys-ng/src/soil/biogeochemistry/organic_substrate_decomposition.zig` (`decompose`/`partitionStructuralProducts`/`decomposeSorbed`). Independently re-derived term-for-term: the `AMAX1(0.0,AMIN1(pool*XNFH,ratio*RDOSC))/FCNK(K)` pattern (min-then-divide-by-limitation, not divide-then-min) is reproduced exactly at `organic_substrate_decomposition.zig:81-82`; the `K.LE.2` lignin-humification gate (`nitro.f:3310`) matches `partitionStructuralProducts`'s `allow_particulate_humification` parameter, called with `substrate <= 2` (`decomposition_step.zig:135`); `RHOSC(5,K)=0.0` (5th structural fraction never humifies) is reproduced by construction (the particulate array defaults to zero and only fractions 0-3 are populated). **Disposition: `preserved`.**

**Priming redistribution** (`:3003-3179`, XFRK/XFRC/XFRN/XFRP/XFRA between K/KK for activity+DOC+DON+DOP+acetate, and XFMC/XFMN/XFMP for microbial C/N/P) -- Zig: `ecosys-ng/src/soil/organic/priming_step.zig` (`applyTile`) and `ecosys-ng/src/soil/biogeochemistry/organic_priming_exchange.zig` (`deriveCell`). The dual non-negativity gate on both donor and recipient after transfer (`nitro.f:3033-3034` etc.) is reproduced exactly (`organic_priming_exchange.zig:101-106,112-117`). One subtle legacy asymmetry independently confirmed and correctly preserved: the microbial-transfer rate uses `TFNG(N,K)` -- the temperature/water response of only the *lower-indexed* complex K, not an average of K and KK -- and Zig's `microbial_temperature_water_response[left*population_count+population]` indexes only `left`, matching. **Disposition: `preserved`.**

**DOC/acetate/DON/DOP adsorption-desorption** (`:3460-3525`, CSORP/CSORPA/ZSORP/PSORP) -- Zig: `ecosys-ng/src/soil/organic/sorption.zig` (`calculate`/`state_update`). N-parallel-blocks check across the 4 pools: DOC and acetate correctly apply the `FOCA`/`FOAA` fraction split to both solid and aqueous capacity (`nitro.f:3493-3506`), while DON and PO4 correctly use the *unsplit* full capacity (`nitro.f:3507-3508`) -- Zig's `exchange()` only multiplies by `carbon_fraction` when it is `> 0`, called with `0` for `don_g_n`/`dop_g_p` (`sorption.zig:39-40`). No asymmetry defect. **Disposition: `preserved`.**

**Litter colonization** (`:3860-3902`, OSA update from `DOSAK=DOSA(K)*AMAX1(0,ROQCK(K))`, bounded above by OSC) -- Zig: `ecosys-ng/src/soil/organic/litter_colonization_step.zig` (`applyTile`/`calculateColonization`). Matches; the resulting increment is committed downstream through the same path as decomposition (see open item below). **Disposition: `preserved`** (flux/equation level).

**Mixing of microbial C,N,P between adjacent soil layers** (`:4162-4246`, FOMCX activity-density gradient, gated by `BKDS(LL).GT.ZERO` and `DLYR(3,L).GT.DLYRM`) -- Zig: `ecosys-ng/src/soil/microbial/layer_mixing.zig` (`applyTile`/`mixingFraction`/`mixPool`), which mutates persistent microbial state directly (not deferred to `applyZone`). Term-for-term match including both gates, confirmed via the file's own doc comments citing `NITRO.F 4189`. **Disposition: `preserved`.**

**Fire/combustion event** (`:4286-4592` -- combust microbial biomass OMC/OMN/OMP for K=0-5 excluding K=3,4 at L=0; microbial residue, DOC/DOA/DON/DOP, adsorbed OM, and SOM for K=0-4 (600K Arrhenius threshold); charcoal (M=5) separately at a 700K threshold with its own rate constant) -- Zig: `ecosys-ng/src/soil/organic/combustion.zig` (`burnOrganicState`, extensively cross-referenced to `NITRO.F` line numbers in its own doc comments: `4301-4303`, `4305-4307`, `4313-4359`, `4344-4346`, `4389-4391`, `4420-4434`, `4463-4477`) and `ecosys-ng/src/soil/biogeochemistry/organic_matter_fire_exchange.zig` (shared ledger consumed by other fire producers too). Verified the domain asymmetry I flagged while reading the Fortran -- residue/DOC/adsorbed/SOM combustion loops run `K=0,4` with no explicit `L=0` guard, while microbial-biomass combustion runs `K=0,5` with an explicit `IF(L.NE.0.OR.(K.NE.3.AND.K.NE.4))` guard -- is *not* a translation bug: it mirrors the legacy's own domain structure (K=3 POC and K=4 humus pools simply do not exist at the L=0 litter surface, so the missing guard is harmless because those pools are always zero there). Zig reproduces this exactly via two distinct constants (`SoilOrganic.substrate_count`=5 vs `microbial_substrate_count`=6) and an explicit `surface_litter and (substrate==3 or substrate==4)` skip applied only to the microbial loop. **Disposition: `preserved`.**

**Gas-flux aggregation for `redist.f`** (`:3996-4020`, RCO2O/RCH4O/RH2GO/RUPOXO/RN2G/RN2O) -- Zig: `ecosys-ng/src/soil/gas/biogeochemical_gas_aggregation.zig` (`aggregate`). This function is explicitly documented and tested as an **equation-level oracle only**: its own doc comment states "the former unread runtime aggregation shadow was removed after independent comparison proved that it had zero consumers and contained stale, incomplete terms," and a dedicated test (`"dead gas aggregation shadow cannot re-enter production"`) asserts no `State`/`ApplyContext`/`applyTile` exists in the module. Production state is instead committed by "the nitrogen, methane, oxygen, and autotrophic-carbon owners" (per the same comment) -- I did not independently re-trace those distributed owners this pass. The equation itself is verified correct (`aggregate()`'s formula and its unit test reproduce the exact legacy signs/terms for all six outputs). **Disposition: `preserved`** at the equation level; the distributed production commit path is not re-audited here and is noted below as extending the standing open item rather than a new gap.

**Redistribution of decomposition/sorption/autotrophic-litterfall products into persistent state, and microbial growth-vs-senescence bookkeeping** (`:3527-3858`, plus the `TRINH`/`TRGOM`-family aggregate totals at `:3904-4160` including the mineral-N/P flux arrays `XNH4S`/`XNO3S`/`XNO2S`/`XH2PS`/`XH1PS` and band variants, and the pH driver `XZHYS`) -- read in full; the underlying flux math (decomposition, priming, sorption, colonization -- all verified above) is correct, but the actual commit of these fluxes into persistent OSC/OQC/ORC/OHC/OMC/mineral-N state is performed by `ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig`'s `applyZone` -- the same function already flagged as the standing open item since pass 1. This pass's reading confirms `applyZone`'s scope now effectively covers the state-commit for nearly this entire file (nitrification, denitrification, mineralization, decomposition, priming, colonization all funnel through it), not just the NH4/NO3 mineralization potentials originally scoped. **No traceability row added for this range** to avoid overclaiming a commit-path audit that wasn't done; see "Not covered" below.

**Cross-check against other files' findings:** none of this pass's items overlap with `solute.f`'s open issues, `starte.f`'s partial coverage, `redist.f`'s or `watsub.f`'s closed audits, or the concurrent `hour1.f` pass. No new issue filed -- this pass found clean, well-documented, already-thoroughly-cross-referenced Zig code with no new "N parallel blocks, 1 outlier" defect; the one apparent asymmetry investigated (K=0-4 vs K=0-5 combustion loops) resolved as a faithful reproduction of the legacy's own domain structure, not a bug.

**Coverage:** this pass added the full remaining ~1,620-line block (`2973-4592`). Cumulative with the prior three passes, ~3,720-3,770 of 4,592 lines (~81-82%). **This does not close `nitro.f`'s audit** -- see "Not covered" below for the remaining ~820-870 lines.

## Addendum 2026-09-19 (third pass): denitrification cascade completion (NO2->N2O, autotrophic NO2 reduction) + chemodenitrification -- both clean, one prior finding independently re-verified

Read-only static pass. Confirmed no `zig`/`gfortran`/`ecosys_ng`/`ecosys_oracle` process running and `git status --short` clean before starting; no overlap with the concurrent `hour1.f` pass.

**Full statement-level read this pass:** `nitro.f:1667-2063` (heterotrophic denitrification NO3->NO2->N2O completion, `:1732-1953`, and autotrophic/nitrifier-denitrification NO2 reduction, `:1955-2063`) and `nitro.f:2919-2972` (chemodenitrification, previously undocumented in this dossier). ~451 newly-verified lines.

**Heterotrophic denitrification NO2->N2O and autotrophic NO2 reduction** (`nitro.f:1732-2063`) -- Zig: `ecosys-ng/src/soil/microbial/denitrification.zig`, `calculateHeterotrophicPotential` (`:72-141`) and `calculateAutotrophicPotential` (`:191-219`). Independently re-derived term-for-term, including the subtle asymmetries that make this section a good "N parallel blocks" test: (a) N2O concentration/pool has no band/non-band split (`CZ2OS`/`Z2OS` used unbanded throughout `nitro.f:1806,1897,1920`, matched by Zig's single `nitrous_oxide_*` fields vs the banded `non_band_`/`band_` pairs for NO3/NO2) -- correct, not a bug; (b) the NO2-reduction DOC budget split reuses the NO3 band fractions `FNO3S`/`FNO3B` rather than dedicated NO2 fractions (`nitro.f:1855-1856`), because `FNO2S`/`FNO2B` were earlier aliased to `FNO3S`/`FNO3B` at `nitro.f:338-339` -- Zig's `calculateHeterotrophicPotential` reuses `inputs.non_band.nitrate_fraction`/`band.nitrate_fraction` for the same split (`:113-114`), correctly reproducing the alias rather than treating it as a typo; (c) the NO2->N2O step carries an extra `*2.0` stoichiometric factor (`nitro.f:1919` `VMXD1=(VMXD2-RDN2T)*2.0`) not present at the NO3->NO2 step -- matched exactly at `denitrification.zig:119` (`nitrous_oxide_demand_g_n = ... * 2`). No asymmetry defect found. **Disposition: `preserved`.**

**Finding #2 from the 2026-09-18 pass, now independently confirmed (upgrade from tentative):** the previous pass reported the `3.0`/`0.333` distinct-constants fix (`denitrification.zig:165-176`, `AutotrophicInputs.ammonium_supply_per_nitrite_reduction`) as "found in Zig comment evidence, not independently re-read." This pass directly read `nitro.f:2029-2041`: `RDNO2(N,K)=AMAX1(0.0,AMIN1(VMXD4S,ZNO2SX,FNH4*3.0*ZNH4S(L,NY,NX)*XNFH))` (electron-donor ceiling, factor `3.0`) at `:2028-2029`, and `RVOXA(N)=RVOXA(N)+0.333*RDNO2(N,K)` (coupled NH4 oxidation feedback, factor `0.333`) at `:2040`. These are confirmed as two textually and numerically distinct legacy constants (`3.0` and `0.333`, not exact reciprocals: `1/0.333=3.003...`), and the current Zig code correctly keeps them distinct rather than deriving one from the other. **Revised disposition: `preserved`** (not `legacy-defect-corrected` -- the defect being corrected was a prior *Zig-side* translation draft that conflated the two constants, not a defect in the legacy Fortran itself, which has always kept them separate; the contract's `legacy-defect-corrected` label is reserved for cases where the legacy source itself is wrong and Zig deliberately diverges from it, which is not the case here).

**Chemodenitrification (abiotic HNO2 reduction; SBB 119:203-209)** (`nitro.f:2919-2972`) -- not previously in this dossier. Legacy: NO2 fraction/competition factors (`:2943-2954`, reusing the same `FNO3S`/`FNO3B`-derived pattern as above), unlimited capacity `VMXC4S/B=0.5E-03*CHNO2*VOLWM*VLNO3*TFNX*XNFH` (`:2955-2956`), triple product distribution of the reduced NO2: 50% to N2O (`RCN2O`/`RCN2B`, split non-band/band), 0% to N2 (`RCN2G=0.00*(...)`, always zero but structurally retained), 50% to DON (`RCOQN`, combined across both zones) (`:2959-2962`). Traced the downstream state-commit at `nitro.f:4019-4020` confirming `RCN2O+RCN2B` are summed into the single non-banded N2O pool flux `RN2O`, and `nitro.f:3623` confirming `RCOQN` is added to `OQN` without zone split -- so the zone-split-for-N2O-but-combined-for-N2/DON asymmetry in the production formulas is not a bug, it mirrors the fact that only the NO2 pool (the substrate) is banded; N2O, N2 and DON pools are not. Zig: `ecosys-ng/src/soil/microbial/chemodenitrification.zig`, `calculate`/`calculateZone` (`:44-92`, doc-tagged "Exact NITRO.F lines 2920--2972"), called from `chemodenitrification_step.zig`'s `applyTile` (`:43-74`). Constants match exactly (`reaction_rate_per_h=0.0005`≡`0.5E-03`; product fractions `0.5/0/0.5` for N2O/N2/DON, validated to sum to 1 at `chemodenitrification.zig:100-104`). Term-for-term match confirmed, including the same combined-vs-split asymmetry. **Disposition: `preserved`.**

**Minor observation (not filed as an issue, no science impact):** `chemodenitrification.zig` also contains a second, fuller-featured implementation (`calculateBatch`/`State`/`Inputs`, `:145-288`) of the same `NITRO.F 2920-2972` equations, used only by this file's own tests -- zero production callers found (grepped whole `ecosys-ng/src` tree). Unlike the file's own `state_update`/`state_updateAutotrophicZone` dead-code pattern in `denitrification.zig` (tagged `NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001`), this dead `calculateBatch` path carries no such tag/comment. Harmless (a bug there would have no simulation effect, since production uses `calculate`/`applyTile` instead), but inconsistent with this codebase's own documentation convention for dead reference implementations. Not significant enough for its own issue file; noted here for whoever next touches `chemodenitrification.zig`.

**Cross-check against `solute.f`/`starte.f` findings:** reviewed both files' existing audit notes; none of this pass's three items (denitrification NO2->N2O completion, the `3.0`/`0.333` constants, chemodenitrification) overlap with `solute.f`'s six open issues (solute transport/charge balance) or `starte.f`'s partial coverage (state initialization). No cross-reference needed.

**Coverage:** this pass added ~451 newly-verified lines (`1667-2063`, `2919-2972`). Cumulative with the prior two passes, ~2,100-2,150 of 4,592 lines (~46-47%).

## Addendum 2026-09-18 (same session, follow-up pass): methanogenesis, N2 fixation, litter mineralization -- two clean confirmations, one real undocumented anomaly

**Acetotrophic + hydrogenotrophic methanogenesis** (`:986-1059,1290-1334`) -- Zig: `ecosys-ng/src/soil/microbial/methanogenesis.zig`, `acetotrophic`/`hydrogenotrophic` (`:41-55,94-121`), term-for-term match. Hydrogenotrophic path carries an already-closed, fully-evidenced defect fix (`GAS-METHANOGENESIS-DOUBLE-0.111-001`, `:76-84,112-117`, regression test `:138-177`) correcting a prior double-application of a gram-C-to-gram-H factor that had suppressed hydrogenotrophic CH4 production ~9x -- independently re-verified against `nitro.f:1317-1327` directly, not just trusted from the comment. **Disposition: `preserved`, plus one already-closed `legacy-defect-corrected` sub-finding.**

**Nonsymbiotic N2 fixation** (`:2511-2553`) -- Zig: `ecosys-ng/src/soil/microbial/nonsymbiotic_nitrogen_fixation_step.zig`, term-for-term match. Carries an approved, well-documented extension (`NITRO-N2FIX-SUPPLY`, `:19-31`) adding a dissolved-N2 mass-conservation bound the legacy intensive-Monod term lacks (over-fixes against near-zero N2 mass in frozen/dry layers) -- correctly flagged as a feature with regression tests for both activation and inactivity. **Disposition: `preserved` + approved feature, fully evidenced.**

**Litter-surface NH4/NO3/H2PO4/HPO4 mineralization-immobilization** (`:2296-2481`, the surface sibling of the already-audited soil-layer blocks) -- **real, triangulated anomaly found**: 7 of 8 parallel blocks (soil-layer NH4/NO3/H2PO4/HPO4 and litter NH4/H2PO4/HPO4) use `AMIN1` (demand capped by uptake capacity); litter NO3 alone (`nitro.f:2377`) uses `AMAX1`, contradicting its own header comment and its NH4 sibling three lines above. Triangulated against three axes (soil-vs-litter, NH4-vs-NO3, N-vs-P) to rule out an intentional design choice -- most likely a legacy Fortran typo. Zig (`surface/microbial_mineral_exchange_step.zig`) applies `@min` uniformly for both pools, correctly NOT reproducing the anomaly -- but this deviation from the literal source has no tag/comment/record anywhere, unlike the two clean findings above. **Disposition: `unresolved`** -- filed as `audit/issues/issue-020-nitro-litter-no3-amax1-anomaly-undocumented.md` (Zig's behavior almost certainly correct, but needs a formal review record, not an implicit assumption).

**Soil-layer P mineralization-immobilization** (`:2184-2285`, read as the control/cross-check) -- fully `AMIN1`-consistent, Zig `soil/microbial/phosphorus_exchange_step.zig` matches. `preserved`.

**Coverage**: this pass added ~660 newly-verified lines; cumulative with the prior pass, ~1,650-1,700 of 4,592 lines (~36-37%). Remaining unaudited: colonization/priming/growth-respiration bookkeeping (~lines 160-900,1060-1150,1335-2093,2554-4592) and `nitrogen_state_update.zig`'s `applyZone` (flagged open by the prior pass, still unverified).

## Scope and provenance

**Legacy source:** `f77src/nitro.f` (sha256 `26D2222512F672E12500A5C3253218808C4A83722D7127F35A9D655A21305A2A`).

**Nitrification (NH3->NO2->NO3):** `nitro.f:1153-1170` (NH3 oxidizers) / `:1251-1265` (NO2 oxidizers). Unlimited rate x temp/N,P/CO2/biomass/timestep activity, ammonia self-inhibition `1/(1+CNH3S/VHKI)`, Monod NH4 term, O2-demand coefficients `2.667`/`3.429`(NH4)/`1.143`(NO2). Params `nitro.f:150-159`: `VMXH=0.125`, `VMXN=0.125`, `ECNH=0.30`, `ECNO=0.10`, `RNFNI=2.0E-04`, `ZHKI=7.0E+03`, `VMKI=1.0`, `VHKI=14.0`.

**New (Zig):** `ecosys-ng/src/soil/microbial/nitrification.zig` (sha256 `7EE3EA8DDE00EDC65536C211112E980CD754A725B25E6A5ECBA4862B065C80D5`), `calculatePotential` (`:77-124`), called from `nitrification_step.zig`. All constants verified identical by name/value: `ammonia_oxidation_rate_g_n_per_g_c_h=0.125`, `nitrite_oxidation_rate_g_n_per_g_c_h=0.125`, `ammonia_oxidizer_carbon_efficiency_g_c_per_g_n=0.3`, `nitrite_oxidizer_carbon_efficiency_g_c_per_g_n=0.1`, `oxygen_per_respired_carbon=2.667`, `oxygen_per_ammonium_n=3.429`, `oxygen_per_nitrite_n=1.143`, `inhibition_decay_per_h=0.0002`, `inhibition_decay_ammonium_constant=7000`, `ammonia_product_inhibition=14`.

**Disposition: `preserved`.**

**Denitrification (heterotrophic, NO3->NO2->N2O):** `nitro.f:1732-1769`. Unmet-O2-demand-driven capacity (`ROXYD`, `VMXD3=0.875*ROXYD`), competitive NO2/NO3 Monod inhibition, product inhibition `1/(1+cap/(K*V))`, triple-min (capacity/DOC-budget/supply) at `RDNO3` (`:1762`). Params `nitro.f:152-159`: `Z3KM=1.4`, `Z2KM=1.4`, `VMKI=1.0`, `ECN3=0.429`, `ECN2=0.429`, `ECN1=0.214`.

**New (Zig):** `ecosys-ng/src/soil/microbial/denitrification.zig` (sha256 `18826B49FCD50B2E498B0C51FDB7FC30C9F87C4C5D82B877AE2B837A6F475223`), `calculateHeterotrophicPotential` (`:72-141`). Same chain and constants verified identical: `nitrate_half_saturation=1.4`, `nitrite_half_saturation=1.4`, `product_inhibition_rate=1`, `carbon_per_nitrate_n=0.429`, `carbon_per_nitrite_n=0.429`, `carbon_per_nitrous_oxide_n=0.214`, `nitrate_n_per_unmet_oxygen=0.875`.

**Disposition: `preserved`.**

**NH4/NO3 mineralization-immobilization:** `nitro.f:2094-2116` (NH4), `:2154-2172` (NO3, leftover demand after NH4). Sign convention: positive `RINHP=(OMC3*CNOMC-OMN3)` = immobilize, negative = mineralize; Monod-capped uptake capacity/competition/min-clamp sequence.

**New (Zig):** `ecosys-ng/src/soil/microbial/nitrogen_exchange_step.zig` (sha256 `CB2EF6ADE6358D2131FE6C18113B516E1E82C909B0D3DF3EBF71B4EDB0885BD3`), `applyTile` (`:71` on, doc comment `:32-34` explicitly cites "Ports NITRO RINHP/RINHO/RINHB/RINH4/RINB4 and the following RINOP/RINOO/RINOB/RINO3/RINB3 sequence"). Same sign convention, same C:N-deficit driver, same two-stage NH4-then-NO3 sequencing including the "leftover demand" pattern (`:88`).

**Disposition: `preserved`** (functional-form/sign match confirmed; constant-level cross-check of `Z4MX/Z4KU/ZOMX/ZOKU/CNOMC` against `nitrogen_parameters.zig` NOT done this pass).

## Two findings worth tracking separately

**1. Dead reference code (not a science gap):** `nitrification.zig`'s `state_updateZone` (`:139-149`) and `denitrification.zig`'s `state_update`/`state_updateAutotrophicZone` (`:223-239,258-267`) are tagged `NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001` (in-code comment) -- zero production callers. Production applies potentials via an independently-maintained reimplementation, `soil/nutrients/nitrogen_state_update.zig`'s `applyZone` (`:214-215,1438`), **not audited this pass**. Disposition on the dead helpers themselves: cosmetic/harmless (a fix there would have no simulation effect) -- but `applyZone` itself is an open verification gap: `unresolved` until independently traced against the same Fortran equations.

**2. Corrected translation defect, found via in-code evidence -- independently re-derived 2026-09-19 (see addendum above):** `denitrification.zig:143-176`'s doc comment on `AutotrophicInputs.ammonium_supply_per_nitrite_reduction` documents a previously-reconstructed bound that conflated two distinct source constants -- `nitro.f:2029/2031` (`FNH4*3.0*ZNH4S*XNFH`) vs `nitro.f:2040/2041` (`0.333`) -- computing `NH4/0.333 = 3.003x NH4` instead of keeping `3` and `0.333` as separate factors, overstating the electron-donor ceiling by `1.001001x`. **`nitro.f:2029-2041` was independently re-read in the 2026-09-19 pass and confirms the comment exactly**: the two constants are textually and numerically distinct in the legacy source. Disposition: **`preserved`** (revised from the prior pass's tentative `legacy-defect-corrected` -- the thing that was corrected was a prior Zig-side translation draft conflating the two constants, not a defect in the legacy Fortran; current Zig state matches legacy exactly, so `preserved` is the correct disposition per the contract's vocabulary).

## Not covered (historical -- superseded, see fifth-pass closing summary above)

As of the fourth pass, ~820-870 of 4,592 lines and the two loose ends below
were still open. **All were closed by the fifth pass (2026-09-19, see
addendum above).** Kept here for history:
- `:160-900`, `:1060-1150`, `:1335-1666`, `:2482-2918` -- closed, fifth pass.
- `nitrogen_state_update.zig`'s `applyZone` -- closed, fifth pass (verified
  correct for its actual scope; prior passes' description of its scope was
  corrected).
- Constant-level check of `Z4MX/Z4KU/ZOMX/ZOKU/CNOMC` -- closed, fifth pass
  (all six constants confirmed identical).

Already covered (do not re-audit): the entire file, `:1-4592`. See the
fifth-pass closing summary above for the full Zig-home list and final tally.

## Acceptance and review

Author: this session's audit fork, 2026-09-18/2026-09-19 (five passes,
explicitly scoped per each addendum above). Independent reviewer: not yet
done -- this is the single largest remaining action item for this dossier.
Evidence: file:line citations above; each pass confirmed `git status
--short` clean of unrelated changes and no `zig`/`gfortran`/`ecosys_ng`/
`ecosys_oracle` process running before starting (static read-only passes
throughout this dossier's history; no `zig build`/test/run ever executed as
part of this feature's audit). **Decision: source-audit coverage of
`nitro.f` is now complete (4,592/4,592 lines, 100%) with one new open
`unresolved` issue (`issue-054`) and one pre-existing open `unresolved`
issue (`issue-020`), both needing reviewer/build-time follow-up. This
dossier remains NOT_ASSESSED for formal gate purposes** (per contract,
"Missing evidence is never a pass" and independent review is a distinct,
not-yet-performed step) **but `nitro.f`'s G1 source-audit work itself is
complete.**
