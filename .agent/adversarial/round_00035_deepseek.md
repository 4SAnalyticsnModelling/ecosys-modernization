# Round 00035 Adversarial Challenge: Pre-Emergence Termination & Root Gas Withdrawal

## 1. Planting Event, Fate in Legacy Fortran, and Seedling Termination
- **Plant Sown**: In `runottawa_input_files/management/plant/plant_grid_1998.txt`, cell 1 is sown with `maiz33` managed by `f25plt98`:
  - Line 1: `18059999,6.6,0.025` (sown 18-05-1998 = day 138 at 6.6 plants/m², depth 0.025 m).
  - Line 2: `13100000,1,1,0.0,0.0,1.00,1.00,1.00,1.00,0.00,0.95,0.00,0.00`
    - Date `13100000` corresponds to **13-10 = Day 286** (`readq.f:364-373`).
    - Termination code `JCUT=1` terminates the PFT (`readq.f:339`, `PCUT=1.0`), and `ICUT=1` (`grain harvest`).
- **Legacy Behavior**: In legacy Fortran, day 286 noon (`grosub.f:8566-8575, 10283-10290`), `JCUT=1` sets $PP = 0$, terminating the crop:
  `IF(PP(NZ,NY,NX).LE.ZERO) THEN IDTHR=1; IDTHP=1; IDTH=1; ENDIF` (`grosub.f:10284-10286`).
  In the legacy run, the crop was harvested/killed on day 286!
- **Hour 6241 vs Hour 6852**: Hour 6852 is **day 286 hour 12 (solar noon)**. The death event on day 286 is **not a premature failure or science gap**, but the scheduled harvest/termination event in `f25plt98`!
- At termination, `grosub.f:11265-11303` executes `IF(IDTHR.EQ.1)`: roots are killed, and root gas contents are dumped into $R\text{CO}_2Z \dots R\text{H}_2GZ$ (`lines 11292-11303`). Then `extract.f:952-957` loops over all $NZ=1 \dots NP_0$ (`loop 9985`) without checking if the plant is currently active, adding $R\text{CO}_2Z$ into $T\text{CO}_2Z$.
- Therefore, the assertion in `uptake_coupled_transaction.zig` forbidding gas withdrawal when `active_by_plant == false` was an **artificial guard** that contradicted legacy semantics during harvest/termination. Removing it is legacy-faithful.

## 2. Conservation Closure Verification
The released root gas reaches both the layer and cell ledgers identically to legacy:
- **Layer Ledger**: `ecosys_ng.zig:5538-5547` invokes `accumulateRootGasActivity`, recording `withdrawal_loss_g_per_h_by_gas_and_layer` into `hourly_layer_boundary_ledger` (mirroring `REDIST 6530--6582`).
- **Cell Ledger**: `ecosys_ng.zig:5682-5700` calls `canopyGasBoundaryForCell`, which aggregates `loss_g_element_per_h_by_gas_and_cell` into `canopy_co2_exchange_g_c_timestep` and `plant_atmosphere_domain_candidate`, matching legacy `XCNET/XONET` accumulation (`extract.f:942-957`).
- Both `hourly_cell_conservation.zig` and `layer_local_conservation.zig` receive matching boundary activity and storage deltas, guaranteeing that element mass conservation closes exactly.
