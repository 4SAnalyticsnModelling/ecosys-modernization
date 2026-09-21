# First-Pass Audit: f77src/grosub.f:2000-2551 (Canopy Growth, Partitioning & C4 Exchange)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Systematic source audit of legacy `f77src/grosub.f:2000-2551` against `ecosys-ng/src/`.  
Audit Scope: Growth respiration, C4 bundle sheath exchange/leakage, organ partitioning, node distribution, specific leaf area/length extension, and senescence recycling fractions.

---

## 1. Traceability & Source Mapping Table

| Item | Legacy Location (`grosub.f`) | Process & State Variables Written | Zig Counterpart (`ecosys-ng/src/`) | Live Wiring Status | Disposition |
|---|---|---|---|---|---|
| **1** | lines 2017–2030 | Non-structural C, N, P consumption in growth and N assimilation respiration (`CGROSM`, `CGROS`, `ZADDBM`, `ZADDB`, `PADDB`, `CNRDM`, `CNRDA`). | `plant/growth/shoot_growth_runtime.zig:1470-1550`, `canopy/photosynthesis/photosynthesis_organ_growth.zig:42-70` | **LIVE**: Invoked every hourly plant step in `shoot_growth_runtime.zig` via `calculateOrganGrowth`. | `preserved` |
| **2** | lines 2045–2055 | Above-ground autotrophic respiration accumulation (`RCO2TM`, `RCO2T`, `RCO2M`, `RCO2N`, `RCO2A`). | `plant/growth/shoot_growth_runtime.zig:1475-1485`, `plant/growth/shoot_growth_fluxes.zig` | **LIVE**: Wired to `context.carbon_exchange.shoot_respiration_g_c_per_h`. | `preserved` |
| **3** | lines 2072–2075 | Deduct growth and maintenance C, N, P from non-structural mobile pools (`CPOOL`, `ZPOOL`, `PPOOL`). | `plant/growth/shoot_growth_runtime.zig:1565-1575`, `canopy/photosynthesis/photosynthesis_mobile.zig:previewBranchMobilePools` | **LIVE**: Updates `canopy.branch_mobile_carbon_g`, `branch_mobile_nitrogen_g`, `branch_mobile_phosphorus_g`. | `preserved` |
| **4** | lines 2085–2160 | C4 mesophyll-to-bundle-sheath transfer (`CPL4M`), bundle sheath decarboxylation (`CPL3K`), and CO2 leakage (`CO2LK`). | `canopy/photosynthesis/c4_mesophyll_bundle_exchange.zig:38-64`, `canopy/photosynthesis/photosynthesis_misc.zig:66-105` (`advanceC4CarbonPools`) | **LIVE**: Executed in `canopy/photosynthesis/carboxylation.zig:225-245` when plant pathway is C4. | `preserved` |
| **5** | lines 2200–2240 | Organ C, N, P partitioning (`GROLF`, `GROSHE`, `GROSTK`, `GRORSV`, `GROHSK`, `GROEAR`, `GROGR` and organ weights `WT*B`, `WT*BN`, `WT*BP`). | `canopy/photosynthesis/photosynthesis_organ_growth.zig:42-70` (`calculateOrganGrowth`), `applyBranchOrganGrowth:72-105` | **LIVE**: Called in `shoot_growth_runtime.zig:1479, 1584`. | `preserved` |
| **6** | lines 2250–2260 | Etiolation coefficient (`ETOL`, `CCE`) from non-structural C:N:P imbalance. | `plant/growth/shoot_growth_runtime.zig:1500-1510`, `canopy/metabolism/nutrient_constraint.zig` | **LIVE**: Evaluates `etoliation_factor = 1 + nutrient_constraint` for leaf/stalk extension. | `preserved` |
| **7** | lines 2265–2330 | Node-level leaf growth distribution across active nodes (`ALLOCL`, `WGLF`, `WGLFN`, `WGLFP`, `WSLF`) and specific leaf area (`SLA`, `ARLF`, `ARLFB`). | `canopy/photosynthesis/photosynthesis_organ_growth.zig:137-180` (`distributeLeafGrowth`), `canopy/leaf/node_growth_state_update.zig:32-90` | **LIVE**: Called in `shoot_growth_runtime.zig:1585-1605`. Modulo-25 ring replaced by dynamic runtime node slice. | `replaced-by-approved-feature` |
| **8** | lines 2335–2395 | Node-level petiole/sheath growth (`WGSHE`, `WGSHN`, `WGSHP`, `WSSHE`) and petiole extension (`SSL`, `HTSHE`). | `canopy/photosynthesis/photosynthesis_organ_growth.zig:182-215` (`distributeSheathGrowth`) | **LIVE**: Called in `shoot_growth_runtime.zig:1606-1616`. | `replaced-by-approved-feature` |
| **9** | lines 2400–2490 | Node-level stalk internode growth (`WGNODE`, `WGNODN`, `WGNODP`), internode length (`SNL`, `HTNODE`, `HTNODX`), and stem diameter (`DSTK`, `RSTK`). | `canopy/photosynthesis/photosynthesis_reproductive.zig:193-270` (`distributeStalkGrowth`) | **LIVE**: Called in `shoot_growth_runtime.zig:1618-1645`. Stem diameter update gated by solar noon/biological day. | `preserved` |
| **10** | lines 2505–2530 | Non-structural nutrient recovery recycling fractions (`RCCC`, `RCCN`, `RCCP`) conditioned on `IGTYP` and C:N:P ratios. | `plant/growth/shoot_recycling_fraction.zig:33-100` (`calculate`), `shoot_growth_runtime.zig:355-375` | **LIVE**: Called in `shoot_growth_runtime.zig:1648`. | `preserved` |
| **11** | lines 2535–2551 | Lowest-node leaf senescence remobilization initiation (`FSNC`, `RCCLX`, `RCZLX`, `RCPLX`). | `canopy/photosynthesis/photosynthesis_node_layer.zig:820-890`, `canopy/leaf/leaf_senescence_snapshot.zig` | **LIVE**: Called in `shoot_growth_runtime.zig:1670-1685` (`state_updateSelectedNodeSenescence`). | `preserved` |

---

## 2. Key Findings & Potential Science Gaps

1. **Modulo-25 Node Ring vs. Dynamic Slice (`replaced-by-approved-feature`)**:
   - Legacy Fortran wraps node arrays modulo 25 (`K = MOD(KK, 25)` at lines 2285, 2355, 2415). When a plant exceeds 25 nodes, legacy recycles array slots and forcibly senesces older nodes (lines 2535–2551).
   - Ecosys-ng intentionally replaces this static ring with dynamic node indexing (`nodes.first..nodes.end` via `shoot_growing_node_window.zig`). The physical allocation equation ($1/\text{GNOD}$) and all growth arithmetic are identical.
2. **C4 Mesophyll/Bundle-Sheath Mass Balance**:
   - Legacy tracks aqueous $CO_2$ and $HCO_3^-$ separately in the bundle sheath (`CO2B`, `HCOB` at lines 2125–2140).
   - Zig faithfully translates this into `node_bundle_sheath_co2_carbon_g` and `node_bundle_sheath_bicarbonate_carbon_g` in `c4_mesophyll_bundle_exchange.zig` and `photosynthesis_misc.zig:advanceC4CarbonPools`.
3. **No Omissions Detected**:
   - Every state update in `f77src/grosub.f:2000-2551` has an active, live-wired Zig counterpart with zero dead-end routes.
