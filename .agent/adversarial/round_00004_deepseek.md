# Round 00004 Diagnosis: Hour-277 Solute Reaction Stagnation

## 1. Inventory Component Dominating the 0.3656 Residual
- **Computation**: In `reaction_solve.zig:1676`, `balance_quality = try reaction_progress.balanceQuality(residual, &search_references)` evaluates `ratio = @abs(change) / inventory` for each packed component (`reaction_progress.zig:10-21`).
- **Trigger**: Line `reaction_solve.zig:1685-1687` detects `repeated_state` (`repeatsState(current, previous_state)` within 64 eps) after alternating or stalled iterates, which sets `terminal_stagnation = true` and aborts with `SoluteReactionSolverStagnated` at `:1734`.
- **Dominating Component**: The 0.3656 maximum residual is governed by the trace **carbonate/bicarbonate** equilibrium system (`aqueous.bicarbonate` / `aqueous.carbonate`, packed indices 10-11, and metal-carbonate pairs). In wet rain at pH 7.0, `starteDynamicInput` introduces carbon dioxide, bicarbonate, and trace carbonate pairs into a cold topsoil layer with virtually zero initial carbonate inventory, causing Newton-Raphson/Anderson step oscillations between carbonate association and dissociation.

## 2. What T-00075 Injects into Layer 0 vs. Legacy & Pre-T-00075
- **Pre-T-00075**: Used `equilibratedDynamicInput` which ran an equilibrium solver over an aggregated rain+irrigation bulk droplet, zeroing out trace pairing and suppressing individual source charge-balance distinctions.
- **T-00075**: Replaces this with `starteDynamicInput` invoking `speciateFixedPhSource` (`snow_initialization.zig:866-1030`), which populates both `primary_g` and `salt_mol` (including `CHY1`, `COH1`, `CCO31`, `CHCO31`, and all metal pairs `CCAC1`, `CCAH1`, etc.).
- **Legacy Reality (`starte.f:127-151, 1234-1310` & `trnsfrs.f:710-880`)**:
  - In legacy Fortran, precipitation concentrations $C*R$ are computed in $\text{mol/m}^3$ of rain water.
  - In `trnsfrs.f:710-880`, the flux to soil layer $NU$ is $FLQGQ \times C*R$. Note that in legacy, $FLQGQ$ is precipitation reaching the ground surface (either through snowpack or bare ground), and is applied **either** as primary ions **or** speciated pairs—**NEVER BOTH**.
- **Critical Units / Double-Counting Defect in `snow_surface_discharge.zig`**:
  - In `hourly_process_driver.zig:731-778`, `direct_surface_solute_input` receives **BOTH** `direct_input` (`dynamic.primary_g`, containing total Ca, Mg, Na, K, SO4, Cl, etc.) and `direct_salt_mol` (`dynamic.salt_mol`, containing speciated free ions AND ion pairs).
  - When `snow_surface_discharge.zig:state_update` executes:
    - Loop 1 (`:132-252` over `snow.species_count`): adds free/bulk cations to topsoil (`staged_aqueous[topsoil].calcium += non_band_mol_per_m3`).
    - Loop 2 (`:253-290` over `snow.salt_species_count`): calls `addSoilSalt` (`:415-450`), which **AGAIN** adds `aqueous.calcium += shared`, plus `aqueous.calcium_carbonate`, `calcium_bicarbonate`, `calcium_sulfate`!
  - **Verdict on Defect**: Double-injection of free cations and uncoupled charge injection into layer 0. The soil chemistry state receives double the input mass of all cations/salts, creating severe charge and stoichiometric unbalance in `undampedReactionBalanceWithWater` at hour 277.

## 3. Hypothesis Ranking & Recommended Fix
1. **Hypothesis 1 (Primary)**: `snow_surface_discharge.zig` double-applies atmospheric deposition by adding both `inputs.discharge[cell].soil_nonband_g` (species 10..17, cations/salts) AND `soil_nonband_salt_mol` (salt species 0..11, free cations).
   - *Test*: In `snow_surface_discharge.zig:132-252`, skip species $\ge 10$ (`.aluminum .. .chloride`) when `inputs.discharge` contains active `salt_mol` (or when dynamic salts are enabled).
2. **Hypothesis 2**: `starteDynamicInput` in `hourly_process_driver.zig:754` writes `dynamic.primary_g` to `direct_input`, where `primary_g[10..17]` are left as zero or duplicate raw inputs while `direct_salt_mol` carries the speciated moles.
