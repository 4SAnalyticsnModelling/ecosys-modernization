# Comprehensive Audit: Round 00021 — Soil Geometry, Thermal Properties, and Mass Carriers

**Author**: DEEPSEEK (Architecture / Challenger)  
**Task**: Exhaustive audit of all production writers of soil geometry, volumes, dry capacities, bulk density, mineral masses, and litter-to-soil transfers; evaluate carrier rebases vs conservation.  
**Legacy Sources**: `f77src/redist.f:7720-8350, 9600-9680`, `f77src/hour1.f:2920-2955, 3680-3720`, `f77src/starts.f:1120-1145, 1200-1215`  
**Modern Sources**: `ecosys-ng/src/soil/profile/relayering.zig:710-746, 1095-1120`, `ecosys-ng/src/soil/water/heat_layer_remap.zig:180-250, 359-368`, `ecosys-ng/src/surface/pond_domain_transaction.zig:270-345`, `ecosys-ng/src/soil/nutrients/mineral_layer_remap.zig:120-144`, `ecosys-ng/src/soil/chemistry/layer_remap.zig:265-300`

---

### 1. Audit of Production Writers & Legacy Gates

| State Variable | Production Writer(s) (file:line) | Legacy Equivalent | Legacy Gate & Status in `ecosys-ng` |
| :--- | :--- | :--- | :--- |
| **`soil_geometry` boundaries** | `layer_geometry.zig:104` (`applyDisturbances`) | `redist.f:8050-8090, 8199` | **FIXED / WEAK**: `freeze_thaw_m` gated out of `ddlyrx` (`627634a`), and `current_layer_thickness_m` in SOC leg unhooked from freeze-thaw (uncommitted). |
| **`soil_thermal.layer_volume_m3`** | `relayering.zig:1110` (`rebaseThermalVolumeToGeometry`), `heat_layer_remap.zig:364` | `redist.f:9645` ($VOLY$) | **ACCURATE**: Tied to $DLYR \cdot \text{Area}$. |
| **`dry_solid_heat_capacity`** | `relayering.zig:1111`, `heat_layer_remap.zig:365` | `redist.f:9646-9648` ($VHCM$) | **SUBTLE FLAW**: $FX \to 1$ transfers extensive $VHCM$, leaving trace $10^{-8}\text{ MJ/K}$ behind without merging the depleted layer. |
| **`bulk_density`** | `relayering.zig:728`, `pond_domain_transaction.zig:342` | `hour1.f:2929-2935`, `redist.f:8585` | **MISSING GATE**: In `pond_domain_transaction.zig:342`, surface litter settling recalculates mineral layer BD by amalgamating litter volume into $BKVL$ without verifying $NU > NUI$. |
| **`sand/silt/clay` masses** | `mineral_layer_remap.zig:122` (`refresh`) | `redist.f:8570, 9650` | **STRICTLY CONSERVED**: Extensive mass is never generated or destroyed; only intensive fractions are restated against carrier mass. |
| **Litter $\to$ Soil transfer** | `pond_domain_transaction.zig:278`, `layer_transition.zig:108` | `redist.f:8308-8338` ($NN=3$) | **FIXED**: Gated behind `topsoil_replaced_pond_layer` ($NU > NUI$), eliminating the surface elevation creep. |

---

### 2. Carrier Rebase Analysis: Mass Conservation under Elastic Geometry

1. **Mechanisms in `mineral_remap` & `chemistry_remap`**:  
   - `relayering.zig:734`: `accepted_soil_mass_megagrams = density * matrix_volume_m3`.
   - `mineral_remap.rebaseLayerCarrier` (`mineral_layer_remap.zig:122-127`): Takes `accepted_soil_mass` and updates only *fractions*:  
     `sand_fraction = sand_mass / accepted_soil_mass`.
   - `chemistry_remap.rebaseSolidSoilMassCarrier` (`layer_remap.zig:286-294`): Rescales adsorption capacity concentrations ($mol/Mg$) such that:  
     $\text{Amount } [mol] = \text{Concentration } [mol/Mg] \times M_{soil} = \text{invariant}$.
2. **Conservation Verdict**:  
   - **No extensive mass is created or destroyed**. Absolute sand/silt/clay kilograms and absolute exchange moles ($XCEC, XN4$) remain strictly invariant under boundary dilation.
   - **However**, because $M_{soil} = \rho_b \cdot V_{matrix}$ depends on elastic geometry, frost heave temporarily lowers intensive concentrations ($mol/Mg$), and seasonal thaw restores them. Mineral mass is in the mass balance census and closes to machine precision.

---

### 3. Risk Ranking for 30-Year Ottawa Run

1. **Rank 1 (Critical / Imminent): `heat_step.zig:2659-2671` Renormalization Floor Threshold**  
   `negligible_capacity_limit_megajoules_per_k` uses $8.38\times 10^{-5}\text{ MJ K}^{-1}\text{ m}^{-2}$. When a top layer holds $4.5\times 10^{-3}\text{ m}^3$ liquid water ($C_{total} \approx 0.019\text{ MJ/K}$), it bypasses the floor even when $C_{dry} \sim 0$, causing Richards uncoupled water rebase to plunge temperatures into deep freeze ($127\text{ K}$).
2. **Rank 2 (High): `pond_domain_transaction.zig:278` Unchecked Bulk Density Dilution**  
   If ponded transitions occur on any multi-cell boundary, moving litter dry volume into mineral soil dilutes mineral bulk density without $NU > NUI$.
3. **Rank 3 (Medium): Intensive Concentration Fluctuations from Frost Heave**  
   Seasonal oscillation of $M_{soil}$ modulates effective mineral reactivity ($mol/Mg$) by $\sim 5\text{--}10\%$ during frozen winter months.
