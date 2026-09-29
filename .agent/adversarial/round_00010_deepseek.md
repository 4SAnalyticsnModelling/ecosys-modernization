# Round 00010 Adversarial Review & Verdicts (DEEPSEEK)

### 1. Commit `f0389ce`: Snow Vapor / Soil Water / Root Salt Delta
- **Verdict**: **ACCEPT**
- **Analysis**:
  - *(a) Snow vapor*: Removing `error.SnowVaporInventoryWithoutAirVolume` matches `watsub.f:1431-1435` (`VP1=0.0` when `VOLP02<=ZEROS`) and `:1499-1517` (`FLVSS=0.0` if either layer is airless). In legacy Fortran, vapor in an airless layer is simply not diffused across boundaries. Skipping flux preserves state without throwing a non-physical simulation error.
  - *(b) Soil water stagnation*: WATSUB evaluates explicit/semi-implicit transfers additively without an assert loop. In `solver_solve.zig:1140`, falling back to iterate flux-map publication under tight stagnation ($\le 4\times\text{tol}$) strictly maintains mass balance via conservative flux accumulation and avoids aborting on numerical jitter at drying fronts (DEV-009).
  - *(c) Root salt delta*: `root_processes_uptake.zig:255` publishes only the net change `delta_mol = after_mol - before_mol` to `micropore_solute_state.amount_mol`. This correctly preserves pre-uptake hours (zero delta) bit-for-bit while reconciling hour-3289 layer-2 cation conservation.

---

### 2. Commit `56dfca4`: Root Respiration RCO2A Lag & Hour-3294 Carbon
- **Verdict**: **ACCEPT** (with legacy verification of `RCO2M`/`RCO2N`)
- **Analysis**:
  - In `grosub.f:379`, `RCO2A` is zeroed at GROSUB entry, accumulated during growth (`:2053, :5794, :6383`), and consumed in the *next* hour's UPTAKE (`uptake.f:2087` `RCO2PX = -RCO2A*XNPG`). Removing `actual_respiration_g_c_per_h = 0` from `resetHourlyFluxes` and carrying pending $R_{\text{CO2,A}}$ in census (`landscape_mass_inventory_gas.zig:388`) restores exact carbon conservation across the hour boundary.
  - *Symbiotic/O2 respiration check*: `RCO2M` (maintenance) and `RCO2N` (C-unlimited) are zeroed at `grosub.f:377-378` and updated in `grosub.f:2049, 2051`. In `uptake.f:1705, 1872`, they are strictly diagnostic/intermediate drivers for current-hour root O2 demand (`ROXYP = 2.667*RCO2M`) and root nutrient uptake inhibition. Unlike `RCO2A`, they are not persistent mass carriers transferred across hours. Hence, clearing them at hour-start does not break conservation.

---

### 3. Commit `d38218a`: Root Salt Fallback & Zero-Volume Band Dissolution
- **Verdict**: **ACCEPT**
- **Analysis**:
  - In `plant_root_salt_exchange.zig:309`, falling back to `legacyExplicitExchange` (`uptake.f:2647-2783`) when implicit solver iterations stagnate/diverge mirrors legacy explicit Euler substeps with $R_{\text{DX}}\times X_{\text{NPHX}}$ bounds. It preserves mass conservation while bypassing Picard stalling.
  - In `fertilizer_dissolution.zig:320-334`, routing band dissolution into non-band when band water is zero matches `hour1.f:4970-4973`, where a zero-volume band is amalgamated into non-band amounts.

---

### 4. Commit `e2e4679`: Band Shrink/Collapse Amount Preservation
- **Verdict**: **ACCEPT WITH ONE CAVEAT (MONITORING REQUIREMENT)**
- **Analysis**:
  - Rescaling concentrations by `old_fraction / new_fraction` in `preserveZoneAmountsAfterPrepare` (`fertilizer_band_production.zig:340-385`) perfectly matches how the census reconstructs extensive mass: in `landscape_mass_inventory_nitrogen.zig:167` and `landscape_mass_inventory_phosphorus_ions.zig:542-545`, adsorbed/site amounts are computed as $\text{conc} \times \text{mass} \times \text{fraction}$. Rescaling concentration guarantees extensive pool preservation as fraction shrinks.
  - *Omission check*: Solid fertilizer dissolution occurs after band geometry in HOUR1, so banded solid fertilizer is not affected. Gaseous NH3 in band pores is re-equilibrated in SOLUTE. Nitrate/nitrite are handled.
  - *Caveat*: Phosphate in macropores is purely aqueous and not partitioned by fertilizer band fractions (`transport_species.zig:116-118`). However, if an extreme collapse occurs when band volume vanishes, ensure `chemistry.band_phosphate` is completely zeroed and folded into non-band (which `preserveZonePair` correctly does at line 378).
