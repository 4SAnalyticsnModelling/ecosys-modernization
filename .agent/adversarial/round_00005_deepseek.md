# Round 00005 Adversarial Assessment (DEEPSEEK)

### 1. Challenge on Legacy ZEROC = 1e-32 Floor Fix (Round 4 Asks)
- **(a) Can a 1e-32 floor mask a real sulfate/chloride source (e.g. gypsum/fertilizer at 1e-6+)?**
  - **No.** Real physical sources (fertilizer, dissolution, mineral weathering, gypsum) operate at macro/trace scales ($\ge 10^{-8}\text{ to }10^{-3}\text{ mol/m}^3$), which are 24 to 29 orders of magnitude above $10^{-32}$. A floor at $10^{-32}\text{ mol/m}^3$ only affects inert numerical dust from STARTE's $10^{-48}$ representation floor.
- **(b) Any other acceptance path scaling on raw dust pools?**
  - `reaction_charge.requireConserved` scales on `scale = max(before.gross(), after.gross())` (`reaction_charge.zig:63`), which uses total gross charge ($\sim \mathcal{O}(10^1-10^2)$), so it does not scale on raw dust pools. `requirePhysicalReactionBalance` delegates to `reaction_physical_quality.zig:measure`, which is fixed by CLAUDE's floor.

### 2. Deposition Cation Double-Injection Question
- **Verdict**: **REFUTED (as double-injection defect)**.
- **Evidence**:
  - In `snow_surface_discharge.zig:132-252` (`discharge[cell].soil_nonband_g`), species $10..17$ are the primary unassociated free ions (Al, Fe, Ca, Mg, Na, K, SO4, Cl).
  - In `snow_surface_discharge.zig:253-290` (`discharge[cell].soil_nonband_salt_mol`), only species $\ge 12$ are ion complexes/pairs and phosphates (`snow.SaltSpecies`), whereas free salt species $0..11$ are explicitly guarded/routed into litter/aqueous or pair mappings.
  - Furthermore, in `snow_initialization.zig:976-987` (`packSpeciatedSource`), `primary_g_per_m3` only sets indices $0..9$ (gases, NH4, NH3, NO3, HPO4, H2PO4); indices $10..17$ (cations) are left at zero (`@splat(0)` at `:733`). Thus, `direct_input[10..17]` is zero when `starteDynamicInput` runs, meaning cations enter **only once** via `direct_salt_mol`.
