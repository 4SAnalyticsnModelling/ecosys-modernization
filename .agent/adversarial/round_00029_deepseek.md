# Round 00029 Adversarial Science Check: Post-Tillage High pH Root Cause

## 1. Fertilizer Schedule & Representation (f25fr98 on Day 105)
`management/soil/fertilizer/f25fr98` line 3:
`15041998  0 0 0 0  0 0 0 0  0 0 0  360.0  0  0 0 0  0 0 0  0 0 0 0 0`
- **Application**: Day 105 (15-04-1998) applies **agricultural lime** ($360\text{ g Ca m}^{-2}$ as $\text{CaCO}_3$, column 13: `CAC`), **NOT urea or NH4**. Columns 2–9 (broadcast/banded $\text{NH}_4^+, \text{NH}_3\text{, urea, } \text{NO}_3^-$) are strictly 0.0.
- **Layer & Depth**: Depth is 0.0 m (col 21). In legacy `hour1.f:274-287`, because `FDPTHF <= 0` but `CAC > 0`, `LFDPTH` is assigned to topsoil `NUI` (layer 1 in Fortran 1-based soil index, which maps to `ecosys-ng` soil layer 0: 0–1 cm). It is placed as solid broadcast calcite: `PCACO(LFDPTH) += CACX` (`hour1.f:580`, $360 / 40.0 = 9.0\text{ mol Ca m}^{-2} = 9.0\text{ mol }\text{CaCO}_3\text{ m}^{-2}$).
- **Band Plausibility**: No band exists (`VLNHB = VLPOB = 0`). For agricultural lime broadcast onto topsoil, dissolution $\text{CaCO}_3 \rightleftharpoons \text{Ca}^{2+} + \text{CO}_3^{2-}$ followed by $\text{CO}_3^{2-} + \text{H}_2\text{O} \rightleftharpoons \text{HCO}_3^- + \text{OH}^-$ generates substantial alkaline buffering. In an open system with atmospheric $p\text{CO}_2$, equilibrium pH is ~8.2–8.4. When topsoil dissolved $\text{CO}_2$ is depleted or restricted, pure calcite-water closed equilibrium reaches pH 9.9. Thus, pH 8.2–9.8 in a limed top layer is **thermodynamically plausible**.

## 2. Process Raising Layer-0 pH to 8.2–9.8
- **Liming vs Urea**: Urea hydrolysis does not occur on d105/d106 (urea is first broadcast on d136). The pH jump is driven by **calcite dissolution** (`solute.f:2509-2533` / `geochemistry_reaction_rates.zig:71-73`), consuming $\text{H}^+$ via carbonate speciation:
  $\text{CaCO}_3 + \text{H}^+ \rightleftharpoons \text{Ca}^{2+} + \text{HCO}_3^-$.
- **Day 106 Tillage (f25til98)**: On 16-04-1998 (d106) h12, tillage mixes to 0.15 m depth (`redist.f:11316-12555`). Tillage homogenizes accumulated topsoil $\text{CaCO}_3$ across the top 15 cm (`redist.f:12049, 12407`).
- **No Area/Volume Scaling Defect**: `mineral_fertilizer_inventory.zig:92` adds `event.calcium_carbonate_g_ca_per_m2 * cell_area_m2 / 40.0` to `next_soil.calcite_mol`, faithfully matching `hour1.f:533, 580` (`CAC * AREA / 40.0`).

## 3. Diagnosis & Defect Classification
- The high pH (~8.2–9.8) is **physically authentic** for a massive 3.6 t/ha lime application ($9\text{ mol m}^{-2}$ of $\text{CaCO}_3$) in topsoil.
- The SOLUTE crawl is **pure numerical stiffness** in the surface-complexation / carbonate equilibrium: at $\text{pH} > 9.0$, $[\text{H}^+]$ drops below $10^{-6}\text{ mol m}^{-3}$ ($10^{-9}\text{ M}$), where tiny absolute Picard shifts in $\text{OH}^-$ or surface hydroxyl protonation ($\text{SOH}_2^+ \rightleftharpoons \text{SOH} \rightleftharpoons \text{SO}^-$) produce multi-unit swings in $\log[\text{H}^+]$, trapping unrelaxed Picard iteration in 2-cycle oscillations.
