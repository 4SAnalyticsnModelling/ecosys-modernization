# Adversarial Analysis: Round 00015 — Near-Zero Layer-0 Solids and Intermediate Richards Renormalization

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Ottawa hour 4037 (1998 d169 h05) failure: `SoilHeatRenormalizedTemperatureOutsidePhysicalDomain` (temperature 127.2 K, prior 298.59 K, $C_{dry} \approx 1.03\times 10^{-8}\text{ MJ/K}$, $C_{total} \approx 1.896\times 10^{-2}\text{ MJ/K}$, $W_{matrix} \approx 4.5165\times 10^{-3}\text{ m}^3$).  
**Legacy Sources**: `f77src/starts.f:1124-1145,1195-1215`, `f77src/hour1.f:3681-3720`, `f77src/watsub.f:939-955,2570-2600,6850-6920`, `f77src/redist.f:9640-9675`  
**Zig References**: `soil/profile/relayering.zig:1095-1120`, `soil/water/heat_layer_remap.zig:188-255,359-368`, `soil/water/heat_step.zig:2070-2095,2619-2712,2759-2802`

---

### 1. Root Cause Analysis of Anomaly 1: Near-Zero Dry Solid Heat Capacity

1. **Writers of `dry_solid_heat_capacity_megajoules_per_m3_k`**:
   - `initialization.zig:89,209`: Initialized to standard mineral/organic density $\sim 2.2\text{ MJ m}^{-3}\text{ K}^{-1}$.
   - `runtime_adapter.zig:1044` (tillage): Recomputed from physical dry mass.
   - `pond_water_heat_transfer.zig:82`: Pond drainage / deposition.
   - `heat_layer_remap.zig:365`: During boundary movement ($FX$), assigns:
     $$\text{dry\_solid\_heat\_capacity\_megajoules\_per\_m3\_k}[index] = C_{dry} / \text{volume}$$
   - `relayering.zig:1111` (`rebaseThermalVolumeToGeometry`): Re-evaluates intensive capacity after geometry disturbances:
     $$\text{ctx.soil\_thermal.dry\_solid\_heat\_capacity\_megajoules\_per\_m3\_k}[g] = \frac{C_{dry,\text{prev}} \cdot V_{\text{prev}}}{V_{geom}}$$

2. **The Culprit Driving Layer-0 Solids to Zero**:  
   In `heat_layer_remap.zig:246-247`, when dynamic boundary shift occurs ($DDLYRX < 0$ or $> 0$):
   $$\text{source\_dry\_heat\_capacity} = (1 - FX) \cdot \text{source\_dry\_before}$$
   When a top mineral layer shrinks ($FX \to 1$), its extensive solid heat capacity $VHCM(L0)$ is stripped nearly to zero:
   $$VHCM(L0) = (1 - FX) \cdot VHCM(L0) \to 0$$
   However, pore capacity ($7.75\times 10^{-3}\text{ m}^3$) remains non-zero because macropore/litter/residue geometry or bulk volume adjustments do not simultaneously zero the layer. In legacy Fortran (`starts.f:1211`, `watsub.f:125`, `hour1.f:3704-3715`):
   - Layer 0 is surface residue/litter with $VHCM(0) = 0$ ($BKVL(0)$ is organic matter).
   - Soil mineral layers start at $L = NU(NY,NX)$. Legacy never runs dynamic layer-remap on layer 0; layer 0 has no mineral matrix.
   - In Zig, layer 0 is the top soil mineral layer. When boundary re-layering contracts layer 0 against layer 1, $FX$ transfers almost 100% of the solid minerals to layer 1, leaving layer 0 with negligible mineral solids ($C_{dry} \sim 10^{-8}\text{ MJ/K}$) while retaining pore space that can hold $>4.5\times 10^{-3}\text{ m}^3$ of liquid water.

---

### 2. Analysis of Anomaly 2: Intermediate Richards Enthalpy Renormalization

1. **The Intermediate State Bug**:
   In `heat_step.zig:2787-2790`:
   $$H_{target} = H_{before} - Q_{departed} \cdot c_l \cdot T_{old}$$
   For internal flows between layers, $Q_{departed} = 0$, so $H_{target} = H_{before}$.
   Then `temperatureForCellEnthalpy` inverts:
   $$T = \frac{H_{target}}{C_{dry} + c_l W_{after}}$$
   If layer 0 had $W_{before} \approx 1.5\times 10^{-3}\text{ m}^3$ at $T = 298.6\text{ K}$, $H_{before} \approx 0 + 4.19 \times 1.5\times 10^{-3} \times 298.6 \approx 1.88\text{ MJ}$.
   Rain infiltration then injects $3.0\times 10^{-3}\text{ m}^3$ into layer 0 so $W_{after} \approx 4.5\times 10^{-3}\text{ m}^3$.
   Because $H_{target}$ is held at the pre-inflow enthalpy ($1.88\text{ MJ}$), the temperature is calculated as:
   $$T = \frac{1.88\text{ MJ}}{4.19 \times 4.5\times 10^{-3}\text{ m}^3/\text{K}} \approx 100\text{ K} \quad (\text{log reports } 127.2\text{ K})$$
   This is an **unphysical decoupling**: water mass entered layer 0, but its advected enthalpy was omitted during the water-step rebase under the assumption that the spatial heat solver will add it later. When $C_{dry} \approx 0$, $C_{total}$ is dominated entirely by liquid water; doubling water content without adding inflow heat inevitably cuts absolute temperature in half!

2. **Legacy Ground Truth (`watsub.f:2539,2579,3446-3450,6871-6909`)**:
   In legacy Fortran, Richards transport and heat advection are strictly coupled per cycle:
   $$T_{new} = \frac{ENGY_{old} + \sum HFLWL}{VHCP_{new}}$$
   Legacy *never* adds incoming water while holding total enthalpy constant. Inflow water $FLWL$ is always accompanied by its advective enthalpy $HFLWL = c_l \cdot T_{donor} \cdot FLWL$.

---

### 3. Proposed Minimal Legacy-Faithful Fix

1. **Include Internal Advective Enthalpy in `renormalizeTemperatureToConservedEnthalpy`**:  
   In `heat_step.zig:2787-2790`, instead of only accounting for external boundary flux `departed_m3`, account for net internal Richards water exchange at donor temperature:
   $$H_{target}[i] = H_{before}[i] + \sum_{j} Q_{j \to i} \cdot c_l \cdot T_{donor}[j] - \sum_{k} Q_{i \to k} \cdot c_l \cdot T_{old}[i]$$
   Alternatively, if internal advection is reserved for the downstream spatial heat solver, the pre-heat temperature of the layer must be **conserved or bounded by donor/recipient temperatures** ($\min(T_{old}, T_{inflow}) \le T \le \max(T_{old}, T_{inflow})$), rather than artificially dropping to $127\text{ K}$.
2. **Floor Layer-0 Minimum Dry Solid Capacity**:  
   Enforce legacy's minimum solid threshold in `heat_layer_remap.zig` and `relayering.zig` so an active mineral layer cannot be stripped below $DLYRM \cdot \rho_{mineral} \cdot c_{mineral} \approx 10^{-3}\text{ MJ/K}$. If layer thickness drops below $DLYRM$, merge it completely ($FX = 1$) rather than leaving a zombie layer with zero solids and large pores.
