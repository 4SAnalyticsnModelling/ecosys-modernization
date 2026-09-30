# Adversarial Review: Round 00027 — Commits 2444df3 & 84c09d5

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target Commits**:  
- `2444df3`: Single melting point override for surface freeze-thaw (`surface/temperature_solver.zig:1513`, `surface/litter_freeze_thaw_energy_limit.zig:63,116`)  
- `84c09d5`: SOLUTE entry $H^+/OH^-$ RHHX reset (`soil/solute/reaction_solve.zig:960-990, 1036-1058`)  
**Legacy Sources**: `f77src/watsub.f:3134-3155`, `f77src/solute.f:824-853`  

---

### 1. Audit of Commit 2444df3 (Surface Melting Point & Rate Discrepancy)

1. **Dall'Amico $T_m$ vs Legacy $T_{\text{freeze}}$ for Unsaturated Litter ($\psi < 0$)**:
   - In `phase_change.zig:153-162`, the generalized Clapeyron equation yields:
     $$T_{m,\text{DallAmico}} = T_0 \exp\left(\frac{\psi}{L_f}\right) \approx T_0 \left(1 + \frac{\psi}{L_f}\right) = 273.15 + 0.820 \cdot \psi \quad (\psi\text{ in MPa})$$
   - In `watsub.f:3145` and `litter_freeze_thaw_energy_limit.zig:112`:
     $$T_{\text{freeze},\text{legacy}} = \frac{-90959}{\psi - 333} = \frac{273.15}{1 - \psi/333} \approx 273.15 + 0.82027 \cdot \psi$$
   - **Numerical Discrepancy**: The difference between the two expressions is second-order in $\psi/L_f$:
     $$|T_{m,\text{DallAmico}} - T_{\text{freeze},\text{legacy}}| \approx 0.5 \cdot T_0 \left(\frac{\psi}{L_f}\right)^2 \approx 1.23\times 10^{-3} \psi^2$$
     Even at severe wilting drying ($\psi = -1.5\text{ MPa}$), $|T_m - T_{\text{freeze}}| \approx 2.8\times 10^{-3}\text{ K}$ ($2.8\text{ mK}$).
   - **Freeze-Thaw Rate Impact**: In `litter_freeze_thaw_energy_limit.zig:133`, the energy limit is:
     $$H_{\text{limit}} = \frac{C_{\text{litter}} (T_m - T_{\text{surface}})}{1 + 6.29\times 10^{-3} T_m}$$
     A shift of $< 3\text{ mK}$ on driving deficits of $0.5\text{--}5.0\text{ K}$ represents $< 0.1\%$ relative rate change, well within environmental and numerical noise.
2. **Methodological Fidelity vs DEV-002**:  
   Under **DEV-002**, Dall'Amico continuous freeze-thaw replaces legacy's stepped Picard freeze-thaw. Overriding the energy limiter's threshold with `depressed_melting_temperature_k` preserves Dall'Amico's thermodynamic equilibrium while retaining legacy's kinetic energy damping without creating artificial dead zones.

**Verdict on 2444df3: ACCEPT**

---

### 2. Audit of Commit 84c09d5 (SOLUTE Entry RHHX Reset & Extent Consumption)

1. **Caller Audit for `solveCellWithWorkspace` / `solveCellWithWorkspaceAndTrace`**:
   - `stages/soil_chemistry_convergence.zig:545` (Hourly SOLUTE): Consumes `accepted_water_equilibrium_extent_mol_per_m3` and calls `publishAcceptedWaterEquilibriumBalance(layer, extent, water_volume)` at line 611.
   - `ecosys_ng.zig:10253, 10420` (STARTE startup initialization): Runs before weather stepping begins. The returned extent is deliberately discarded because water balances start at hour 1.
   - `soil/chemistry/snow_initialization.zig:639` (Snow chemistry pre-equilibration): Discards `result.accepted_water_equilibrium_extent_mol_per_m3`; snow water is tracked in `snow_solute_transport`.
   - **Conclusion**: No caller double-applies or misallocates the entry extent.
2. **Water Ledger Accounting**:
   - `reaction_solve.zig:989, 1039`: `result.accepted_water_equilibrium_extent_mol_per_m3 += entry_water_extent`.
   - In `stages/soil_chemistry_convergence.zig:611`:
     `publishAcceptedWaterEquilibriumBalance` adds `extent * water_volume` to `soil_chemistry.water_equilibrium_balance_mol[layer]`.
   - It is executed **exactly once per layer per hour** upon successful solve completion.
   - On error, `errdefer` unwinds `original_state`, cleanly dropping `entry_water_extent`.

**Verdict on 84c09d5: ACCEPT**
