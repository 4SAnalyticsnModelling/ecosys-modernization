# Adversarial Diagnosis: Round 00022 — Post-Tillage SOLUTE Convergence Failure (Day 106 Hours 18–24)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Hours 2538/2542/2544 (1998 d106 h18/h22/h24) failure: `SoluteReactionSolverDidNotConverge` (max scaled ~1.8e3, limiting `aqueous.hydroxide`, DEV-011 quality 161).  
**Legacy Reference**: `f77src/redist.f:11260-12840` (Tillage block), `f77src/solute.f:820-860, 2170-2220`  
**Modern Sources**: `ecosys-ng/src/redistribution/tillage/runtime_adapter.zig:2015-2040, 2290-2330, 2485-2515`, `ecosys-ng/src/soil/solute/chemistry_state.zig:426-445`, `ecosys-ng/src/soil/solute/water_equilibrium.zig:250-295`

---

### 1. Snapshot Inspection: Entry State of Layer 0 at Day 106 Hour 18
From `ecosys-ng-solute-failure-*-day106-hour18.bin`:
- **Aqueous pH & Cations**:
  - $[H^+] = 6.67\times 10^{-6}\text{ mol/m}^3 \implies \mathbf{pH = 5.176}$
  - $[OH^-] = 2.12\times 10^{-5}\text{ mol/m}^3$ ($\gg [H^+]$, unprojected water ion product $K_w \sim 1.4\times 10^{-10}$)
  - $[Ca^{2+}] = 2.00\times 10^{-4}\text{ mol/m}^3$, $[Mg^{2+}] = 3.96\times 10^{-11}\text{ mol/m}^3$
  - $[Na^+] = 5.36\times 10^{-7}\text{ mol/m}^3$, $[K^+] = 2.71\times 10^{-7}\text{ mol/m}^3$
  - $[Al^{3+}] = 5.70\times 10^{-10}\text{ mol/m}^3$, $[Fe^{3+}] = 1.22\times 10^{-14}\text{ mol/m}^3$
- **Carbonate & Phosphate**:
  - $[CO_2(aq)] = 1.012\text{ mol/m}^3$, $[HCO_3^-] = 6.69\times 10^{-3}\text{ mol/m}^3$, $[CO_3^{2-}] = 3.15\times 10^{-6}\text{ mol/m}^3$
  - $H_2PO_4^- = 5.47\times 10^{-4}\text{ mol/m}^3$, $HPO_4^{2-} = 4.62\times 10^{-5}\text{ mol/m}^3$, $H_3PO_4 = 3.47\times 10^{-7}\text{ mol/m}^3$
  - Exchange sites: $XCa = 78.8\text{ mol/Mg}$, $XAl = 2.21\text{ mol/Mg}$, $XN4 = 3.41\text{ mol/Mg}$, $XMg \approx XNa \approx XK \approx 0.034\text{ mol/Mg}$
  - Phosphate sites: deprotonated $= 10.66\text{ mol/Mg}$, hydroxyl $= 8.74\text{ mol/Mg}$, protonated $= 5.80\times 10^{-3}\text{ mol/Mg}$, adsorbed $= 0.296\text{ mol/Mg}$.

---

### 2. Root Cause: Tillage Inconsistent Water/Carbonate State & Dropped CO2 Mixing

1. **Unmixed Aqueous $CO_2$**:  
   In `redistribution/tillage/runtime_adapter.zig:2015-2018`:
   `salt_fields` lists 33 aqueous species, but **`carbon_dioxide` is completely missing from `salt_fields`** (lines 2016–2018 stop at `carbonate` and `bicarbonate`).
   In `scatterChemistryAssumeValid` (`:2509`):
   ```zig
   inline for (salt_fields, 0..) |name, coordinate| @field(state.aqueous[global], name) = ...
   ```
   Tillage mixed $HCO_3^-$, $CO_3^{2-}$, and all mineral cations across the 15 cm tillage zone, but **left $[CO_2(aq)]$ untouched in each layer**.
   In legacy `redist.f:12078, 12462, 12725`, $CO_2S$ (aqueous $CO_2$) is mixed across the tillage depth in lockstep with $ZHCO3$ and $ZCO3$.

2. **Severe Acid-Base / Water Imbalance**:  
   Because $HCO_3^-$ was mixed from deeper alkaline layers ($6.69\times 10^{-3}\text{ mol/m}^3$) while topsoil kept unmixed high $[CO_2]$ ($1.012\text{ mol/m}^3$), the ratio $[CO_2]/[HCO_3^-]$ jumped violently.
   At the start of the solve, `water_equilibrium.projectProvisional` tries to project $[H^+]$ and $[OH^-]$. With unmixed $CO_2$ driving $CO_2 + H_2O \rightleftharpoons HCO_3^- + H^+$ at $\text{rate} \sim 0.20\text{ mol/m}^3$, $[OH^-]$ sees an enormous initial residual of $+45.5\text{ mol/m}^3$ (line 5 in `err.txt`), driving Newton steps outside the feasibility region.

3. **Cation Exchange vs Solution Mixing**:  
   `runtime_adapter.zig:2302, 2495` mixes exchangeable cations ($X*$) using soil mass carrier ($BKVL$), which matches legacy `redist.f:12160, 12380-12400`. The mass and charge balances for exchangeable ions are strictly conserved. The defect is solely the omission of aqueous $CO_2$ from the solution-mixing roster.

---

### 3. Minimal Legacy-Faithful Fix

1. **Add `carbon_dioxide` to `salt_fields` in `redistribution/tillage/runtime_adapter.zig:2016`**:
   Insert `"carbon_dioxide"` into `salt_fields` and `salt_transport_species` (updating offsets `33 -> 34`), so aqueous $CO_2$ is stored into `storage`, mixed across the tillage zone $TL$, and scattered into `state.aqueous[global].carbon_dioxide`.
2. **Synchronize Post-Tillage Gas-Transport Dissolved $CO_2$**:  
   In `runtime_adapter.zig`, mirror `stages/soil_chemistry_convergence.zig:708`:
   `context.soil_gas.dissolved_mass_g[co2_idx] = state.aqueous[layer].carbon_dioxide * 12.0 * water_m3`.
