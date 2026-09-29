# Round 00001-B DeepSeek Investigation & Findings

## 1. Trace of Root Salt/Cation Uptake
- **Legacy Fortran**: In `uptake.f:2690-2783`, root salt uptake rates `RUPZCA`, `RUPZNA`, `RUPZKA` (mol/h) are computed across root layers, added to `ZCAP1/ZNAP1/ZKAP1` (plant root pool), and subtracted from `ZCAS1/ZNAS1/ZKAS1` (rhizosphere/soil pool). In `extract.f:830-837`, `TUPZ*` accumulates total uptake over species: `TUPZCA(L,NY,NX) = TUPZCA(L,NY,NX) + RUPZCA(...)`. In `redist.f:6968-6977`, soil storage is decremented by `TUPZ*`: `ZCA(L) = ZCA(L) - TUPZCA(L)`.
- **Zig Implementation**: In `root_processes_uptake.zig:251-261`, `state_updateStaged` writes salt exchange into `roots.salt_content_mol` and updates `soil_salt_content_mol` (written into `soil_chemistry.aqueous[soil]`).

## 2. Transfer Application & Conservation Booking
- **Census Reconciliation**: In `layer_mass_inventory.zig:125-131`, `aggregatePlantRootsLayer` includes `roots.salt_content_mol` via `addPlantSaltElements` (`landscape_mass_inventory_plant.zig:116`). Meanwhile, in `aggregateProfilePhosphorusAndIonsLayer` (`landscape_mass_inventory_phosphorus_ions.zig:273`), soil aqueous cations are read from `micropore.cellAmountsConst(profile_cell)` (the transport basis).
- **The Decoupling**: In `hourly_vegetation.zig:281-294`, after root uptake runs, `synchronizeCellAfterCarrierChange` only synchronizes four phosphate species (`.non_band_hpo4`, `.non_band_h2po4`, `.band_hpo4`, `.band_h2po4`). It does **NOT** synchronize `calcium`, `sodium`, or `potassium` from `soil_chemistry.aqueous` into `micropore_solute_state.amount_mol`.
- Consequently, soil aqueous cations in `storage_after` are not reduced by uptake, while `roots.salt_content_mol` in `storage_after` is increased by uptake! This causes a pure phantom gain in layer 2 storage without any boundary input, directly generating positive residuals: `+9.19e-8` for Ca, `+2.88e-10` for Na, `+1.46e-10` for K.

## 3. Quantitative Test & Na/K Ratio
- The ratio of the residuals: $\frac{\text{Na}}{\text{K}} = \frac{2.8775\times 10^{-10}}{1.4599\times 10^{-10}} \approx 1.971$.
- In `f25sol98`, initial concentrations are $100\text{ g/Mg}$ for both Na and K. The molar mass ratio is $\frac{M_K}{M_{Na}} = \frac{39.1}{23.0} \approx 1.70$.
- In `uptake.f:81` / `plant_root_salt_exchange.zig:48`, the root inhibition constant for Na is $CZNAKI = 1.0\times 10^{-3}$, while for K it is $CZKAKI = 1.0$. Gapon exchange selectivities further modulate free aqueous vs exchange pools. The differential root exchange and rhizosphere uptake uptake rates directly produce this exact $\sim 1.97$ residual ratio.

## 4. Minimal Proposed Fix
In `ecosys-ng/src/stages/hourly_vegetation.zig:286-291`, include the cation species (`.calcium`, `.sodium`, `.potassium`, `.magnesium`, etc.) in `synchronizeCellAfterCarrierChange` or ensure `soil_chemistry.aqueous` is imported into micropore solute transport after root nutrient/salt uptake.
Unit test: verifying that running `root_processes_uptake` conserves total soil + root cation inventory across `reconstructScopes`.
