# Adversarial Review Round 17: Legacy Unit 22 State Family Mapping & Provenance Audit

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Exhaustive mapping of all distinct state families serialized in Fortran Unit 22 (`wouts.f` / `routs.f`, lines 357–462) to `ecosys-ng` checkpoint structures.

---

### Executive Summary & Count Line
**families: 11, mapped: 10, unmapped: 1**

- **Mapped Families (10)**:
  1. Microbial kinetic properties & respiration rates (`ROXYS`, `RVMX1-4`, `RVMB2-4`)
  2. Microbial nitrogen & phosphorus mineral exchange rates (`RINHO`, `RINOO`, `RIPOO`, `RINHB`, `RINOB`, `RIPBO`, `RINHOR`, `RINOOR`, `RIPOOR`)
  3. Soluble microbial turnover products (`ROQCS`, `ROQAS`)
  4. Microbial structural & nonstructural biomass pools (`OMC`, `OMN`, `OMP`)
  5. Decomposable particulate organic residue pools (`ORC`, `ORN`, `ORP`)
  6. Soluble & adsorbed dissolved organic pools (`OQC`, `OQN`, `OQP`, `OQA`, `OQCH-AH`, `OHC`, `OHN`, `OHP`, `OHA`)
  7. Microbial structural residue & humus pools (`OSC`, `OSA`, `OSN`, `OSP`)
  8. Soil total organic carbon & charcoal derivatives (`RVMXC`, `ORGC`, `ORGCC`, `DORGCC`, `ORGR`)
  9. Mineral fertilizer band inventories (`ZNH4FA/B`, `ZNH3FA/B`, `ZNHUFA/B`, `ZNO3FA/B`, `WDNHB`, `DPNHB`, `WDNOB`, `DPNOB`, `WDPOB`, `DPPOB`)
  10. Aqueous & gaseous nitrogen/phosphorus species (`Z2GG/S/SH`, `Z2OG/S/SH`, `ZNH3G/S/SH`, `ZNH4S/SH/B/BH`, `ZNO3S/SH/B/BH`, `ZNO2S/SH/B/BH`, `H1PO4/H`, `H2PO4/H`, `H1POB/H`, `H2POB/H`, `ZNHUI/0`, `ZNFNI/0`)
- **Unmapped Family (1)**:
  1. Profile combustion heat release carrier (`HCBFL`, `wouts.f:462` / `routs.f:488`)

---

### Detailed Family-by-Family Mapping

#### Family 1: Microbial Kinetic Properties & Specific Respiration Capacities
- **Legacy Variables & Location**:
  `ROXYS` (`wouts.f:357`), `RVMX4` (`:358`), `RVMX3` (`:359`), `RVMX2` (`:360`), `RVMX1` (`:361`), `RVMB4` (`:362`), `RVMB3` (`:363`), `RVMB2` (`:364`).
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:76` / `soil/nutrients/reactive_nitrogen_state.zig:25-34` (`previous_non_band_ammonia_oxidation_capacity_g_n`, `previous_band_ammonia_oxidation_capacity_g_n`, `previous_non_band_nitrite_oxidation_capacity_g_n`, `previous_band_nitrite_oxidation_capacity_g_n`, `previous_non_band_nitrate_reduction_capacity_g_n`, `previous_band_nitrate_reduction_capacity_g_n`, `previous_non_band_nitrite_reduction_capacity_g_n`, `previous_band_nitrite_reduction_capacity_g_n`, `previous_nitrous_oxide_reduction_capacity_g_n`).
- **Status**: MAPPED.

#### Family 2: Microbial Mineral Nutrient Exchange & Uptake Capacities
- **Legacy Variables & Location**:
  `RINHO` (`wouts.f:365`), `RINOO` (`:366`), `RIPOO` (`:367`), `RINHB` (`:368`), `RINOB` (`:369`), `RIPBO` (`:370`), `RINHOR` (`:375`), `RINOOR` (`:376`), `RIPOOR` (`:377`).
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:76-78` / `soil/nutrients/reactive_nitrogen_state.zig:35-38` (`previous_non_band_microbial_ammonium_capacity_g_n`, `previous_band_microbial_ammonium_capacity_g_n`, `previous_non_band_microbial_nitrate_capacity_g_n`, `previous_band_microbial_nitrate_capacity_g_n`) and `soil_biogeochemistry_checkpoint.zig:77` / `soil/microbial/phosphorus_state.zig:11-14` (`previous_non_band_h2po4_capacity_g_p`, `previous_band_h2po4_capacity_g_p`, `previous_non_band_hpo4_capacity_g_p`, `previous_band_hpo4_capacity_g_p`).
- **Status**: MAPPED.

#### Family 3: Soluble Microbial Turnover Products (DOC/Acetate)
- **Legacy Variables & Location**:
  `ROQCS` (`wouts.f:372`), `ROQAS` (`:373`).
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:76` / `soil/nutrients/reactive_nitrogen_state.zig:41-42` (`previous_doc_respiration_demand_g_c`, `previous_acetate_respiration_demand_g_c`) and `soil_organic_checkpoint.zig:37-38` / `soil/organic/initialization.zig:408-409` (`state.dissolved_acetate_carbon_g_c`, `state.adsorbed_acetate_carbon_g_c`).
- **Status**: MAPPED.

#### Family 4: Microbial Structural & Nonstructural Biomass Pools
- **Legacy Variables & Location**:
  `OMC(M,N,K,L)` (`wouts.f:379`), `OMN(M,N,K,L)` (`:380`), `OMP(M,N,K,L)` (`:381`) across fractions $M=1..3$, populations $N=1..7$, substrates $K=0..5$.
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:51-52` / `soil/microbial/state.zig:14-15` (`view.microbial.nonstructural`, `view.microbial.structural`) and `soil_organic_checkpoint.zig:36` / `soil/organic/initialization.zig:405` (`state.microbial: []ElementPool`).
- **Status**: MAPPED.

#### Family 5: Decomposable Particulate Organic Residue Pools
- **Legacy Variables & Location**:
  `ORC(M,K,L)` (`wouts.f:385`), `ORN(M,K,L)` (`:386`), `ORP(M,K,L)` (`:387`) across fractions $M=1..2$, substrates $K=0..4$.
- **Ecosys-ng Target Field & File**:
  `soil_organic_checkpoint.zig:36` / `soil/organic/initialization.zig:406` (`state.residue: []ElementPool`).
- **Status**: MAPPED.

#### Family 6: Soluble & Adsorbed Dissolved Organic Pools (DOC, DON, DOP)
- **Legacy Variables & Location**:
  `OQC`, `OQN`, `OQP`, `OQA` (`wouts.f:389-392`), `OQCH`, `OQNH`, `OQPH`, `OQAH` (`:393-396`), `OHC`, `OHN`, `OHP`, `OHA` (`:397-400`).
- **Ecosys-ng Target Field & File**:
  `soil_organic_checkpoint.zig:36-38` / `soil/organic/initialization.zig:407-408` (`state.dissolved: []ElementPool`, `state.adsorbed: []ElementPool`, `state.dissolved_acetate_carbon_g_c`, `state.adsorbed_acetate_carbon_g_c`).
- **Status**: MAPPED.

#### Family 7: Microbial Structural Residue & Humus Pools
- **Legacy Variables & Location**:
  `OSC(M,K,L)` (`wouts.f:402`), `OSA(M,K,L)` (`:403`), `OSN(M,K,L)` (`:404`), `OSP(M,K,L)` (`:405`) across structural fractions $M=1..5$ ($M=5$ is charcoal residue).
- **Ecosys-ng Target Field & File**:
  `soil_organic_checkpoint.zig:36, 39` / `soil/organic/initialization.zig:410-411` (`state.structural: []ElementPool`, `state.colonized_structural_carbon_g_c`).
- **Status**: MAPPED.

#### Family 8: Profile Total Organic Carbon & Charcoal Derivatives
- **Legacy Variables & Location**:
  `RVMXC` (`wouts.f:408`), `ORGC` (`:409`), `ORGCC` (`:410`), `DORGCC` (`:411`), `ORGR` (`:412`).
- **Ecosys-ng Target Field & File**:
  `soil_runtime_checkpoint.zig:45-46, 223` (`charcoal_retention_increment_fraction`, `previous_charcoal_carbon_g_c`), `soil_geometry_checkpoint.zig:514` (`surface_litter_geometry.previous_charcoal_carbon_g_c`), and derived totals reconstructed via `soil/organic/initialization.zig:457` (`totalCarbon_g_c`).
- **Status**: MAPPED.

#### Family 9: Fertilizer Inorganics & Fertilizer Band Geometry
- **Legacy Variables & Location**:
  `ZNH4FA`, `ZNH3FA`, `ZNHUFA`, `ZNO3FA` (`wouts.f:413-416`), `ZNH4FB`, `ZNH3FB`, `ZNHUFB`, `ZNO3FB` (`:417-420`), `WDNHB`, `DPNHB`, `WDNOB`, `DPNOB`, `WDPOB`, `DPPOB` (`:452-457`).
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:66, 71` / `management/fertilizer_nitrogen_inventory.zig:10` (`view.fertilizer.soil`), `soil_biogeochemistry_checkpoint.zig:73` / `management/mineral_fertilizer_inventory.zig:23` (`view.mineral_fertilizer.soil`), and `soil_biogeochemistry_checkpoint.zig:75` / `management/fertilizer_band_state.zig:1020-1035` (`fertilizer_band_checkpoint.writeCheckpoint`).
- **Status**: MAPPED.

#### Family 10: Soil Inorganic Reactive Nitrogen, Phosphate, & Intermediate Gases
- **Legacy Variables & Location**:
  `Z2GG/S/SH` (`wouts.f:421-423`), `Z2OG/S/SH` (`:424-426`), `ZNH3G` (`:427`), `ZNH4S/SH` (`:428-429`), `ZNH3S/SH` (`:430-431`), `ZNO3S/SH` (`:432-433`), `ZNO2S/SH` (`:434-435`), `H1PO4/H2PO4/H` (`:436-439`), `ZNH4B/BH` (`:440-441`), `ZNH3B/BH` (`:442-443`), `ZNO3B/BH` (`:444-445`), `ZNO2B/BH` (`:446-447`), `H1POB/H2POB/H` (`:448-451`), `ZNHUI/0` (`:458-459`), `ZNFNI/0` (`:460-461`).
- **Ecosys-ng Target Field & File**:
  `soil_biogeochemistry_checkpoint.zig:58-65` (`view.chemistry.packCell`), `soil/solute/chemistry_state.zig:665-675` (`aqueous`, `non_band_phosphate`, `band_phosphate`), `soil/nutrients/reactive_nitrogen_state.zig:11-12, 44-45` (`non_band_nitrite_g_n`, `band_nitrite_g_n`, `initial_nitrification_inhibition_activity`, `current_nitrification_inhibition_activity`), and `soil_biogeochemistry_checkpoint.zig:69-70` (`view.fertilizer.initial_urease_inhibition_fraction`, `current_urease_inhibition_fraction`).
- **Status**: MAPPED.

#### Family 11: Combustion Heat Release Carrier (`HCBFL`)
- **Legacy Variables & Location**:
  `HCBFL(L,NY,NX)` (`wouts.f:462` / `routs.f:488`).
- **Ecosys-ng Analysis**:
  In `ecosys-ng`, combustion heat is tracked on `soil_geometry_checkpoint.zig:46, 278` as `delayed_subsurface_combustion_heat_megajoules` (allocator-owned in `ecosys_ng.zig:11375`). However, `delayed_subsurface_combustion_heat_megajoules` is persisted under the `ECOSGEOM` checkpoint header (`soil_geometry_checkpoint.zig:278`), **NOT** under the biogeochemistry/organic checkpoints (`ECOSBIOG` / `ECOSORGN`).
  Furthermore, `HCBFL` in Fortran is explicitly cleared at hour entry in `hour1.f:3177` (`HCBFL(L,NY,NX)=0.0`), meaning any non-zero value survives across restarts only if an event occurs precisely at the checkpoint hour.
- **Status**: UNMAPPED in the Unit 22 counterpart stream (persisted instead in `ECOSGEOM`, but with differing lifecycle semantics).

---

### Conclusion & Final Counts

**families: 11, mapped: 10, unmapped: 1**

- **Unmapped Family**: Family 11 (`HCBFL`, subsurface combustion heat flux, `wouts.f:462`).
