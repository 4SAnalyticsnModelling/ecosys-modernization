# Round 00003 Implementation Proposal (DEEPSEEK)

## 1. Trace & Verification
- **Census State Read**: In `layer_mass_inventory.zig:93-107`, soil aqueous cations/salts are read directly from `micropore.cellAmountsConst(profile_cell)` (`landscape_mass_inventory_phosphorus_ions.zig:273`), not from `soil_chemistry.aqueous`.
- **Root State Read**: In `layer_mass_inventory.zig:125-131`, `aggregatePlantRootsLayer` includes `roots.salt_content_mol` via `addPlantSaltElements` (`landscape_mass_inventory_plant.zig:116`).
- **The Defect**: At hour 3,289 (the first hour root uptake occurs), `root_processes_uptake.zig:251-261` decrements `soil_chemistry.aqueous` and credits `roots.salt_content_mol`. However, between root uptake and the end-of-hour conservation gate, `hourly_vegetation.zig:beginRootGrowthAndSynchronizePhosphate` (`:281-294`) only passed four phosphate species (`.non_band_hpo4`, `.non_band_h2po4`, `.band_hpo4`, `.band_h2po4`) to `synchronizeCellAfterCarrierChange`.
- **Legacy Match**: In legacy Fortran `redist.f:6968-6977`, soil storage is decremented by root uptake in the same hour (`ZCA(L) = ZCA(L) - TUPZCA(L)`). Without syncing the cations to `micropore_solute_state`, the census in Zig sees the uptake credited in the roots while the soil micropore state retains its pre-uptake amount, creating the positive residuals `Ca +9.19e-8`, `Na +2.88e-10`, `K +1.46e-10`.

## 2. Minimal Fix Implemented
- **File**: `ecosys-ng/src/stages/hourly_vegetation.zig:286-300`
- Updated the `changed_species` slice passed into `synchronizeCellAfterCarrierChange` to include all 8 root-uptake salt species:
  `.aluminum, .iron, .calcium, .magnesium, .sodium, .potassium, .sulfate, .chloride`.

## 3. Discriminating Regression Unit Test
- **File**: `ecosys-ng/src/soil/solute/aqueous_transport_bridge.zig:621-655`
- Added test: `"carrier synchronization publishes root cation changes into micropore solute transport"`.
- Verifies that when root uptake reduces `soil_chemistry.aqueous` concentrations for cations, `synchronizeCellAfterCarrierChange` publishes the updated amounts to `transport_state.amount_mol`.

## 4. Verification
- `zig fmt --check src/stages/hourly_vegetation.zig` -> PASS (clean format)
- `zig fmt --check src/soil/solute/aqueous_transport_bridge.zig` -> PASS (clean format)
- `zig test src/module_index.zig --test-filter aqueous_transport_bridge` -> **All 66 tests passed** (including the new regression test).
