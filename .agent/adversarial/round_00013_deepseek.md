# Adversarial Review & Architecture Design: Round 00013 — Per-Substep FLQRS Rain Overflow to Litter

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Legacy per-cycle rain overflow from saturating topsoil micropores/macropores to litter (`FLQRS`, `FLQRH`) in `watsub.f:939-947`.  
**Blocker**: Hour 3917 (1998 d164 h05, 8.5 mm/h storm): `surface/precipitation.zig:338 state_updateSoilIngress` fails with `SurfaceIngressExceedsPoreCapacity` at 20/32/64 substeps because topsoil saturates during the storm.  
**Legacy Ground Truth**: `f77src/watsub.f:939-947` inside every NPH cycle:
```fortran
FLQRS = AMAX1(0.0, FLQ1(NY,NX) - VOLP1(NUM(NY,NX),NY,NX)*FSNX(NY,NX))
FLQRH = AMAX1(0.0, FLH1(NY,NX) - VOLPH1(NUM(NY,NX),NY,NX)*FSNX(NY,NX))
HFLQR1 = 4.19*TKAM(NY,NX)*(FLQRS + FLQRH)
FLYM = FLY1(NY,NX) + FLQRS + FLQRH
HWFLYM = HWFLY1(NY,NX) + HFLQR1
FLQM = FLQ1(NY,NX) - FLQRS
FLHM = FLH1(NY,NX) - FLQRH
HWFLQM = HWFLQ1(NY,NX) - HFLQR1
```

---

### 1. Root Cause & Architectural Tension
Zig currently evaluates `redistribute` once per hour at `precipitation.zig:184-200` using hour-start air capacity (`precipitation.zig:143-154`). When heavy rain saturates topsoil mid-hour, `state_updateSoilIngress` (`precipitation.zig:365-395`) aborts. Retrying finer substeps fails because the hour-level base rates are unchanged and the pore capacity is genuinely exhausted. In legacy, `FLQRS` dynamically diverts the excess water and its heat ($C_l T_{atm} \Delta W$) to surface residue (litter).

---

### 2. Exact Insertion Point(s)

#### Phase A: Ingress Re-partitioning inside `Forcing.prepareSubstep`
In `stages/hourly_heat_water_solute.zig`:
Currently, lines 704–713 update litter ingress, lines 760–785 rebase topsoil vapor, and line 821 updates soil ingress.
Because litter ingress executes *before* topsoil ingress, the per-substep overflow must be evaluated **before litter ingress is committed**:
1. **At `hourly_heat_water_solute.zig:704`**:
   Compute available topsoil air capacity right now:
   ```zig
   const top = try context.grid.layerIndex(cell, 0);
   const matrix_air_m3 = context.grid.matrix_pore_capacity_m3[top] -
       context.grid.matrix_liquid_water_m3[top] -
       context.grid.matrix_ice_water_m3[top] / ice_density;
   const macro_air_m3 = context.grid.macropore_pore_capacity_m3[top] -
       context.grid.macropore_liquid_water_m3[top] -
       context.grid.macropore_ice_water_m3[top] / ice_density;
   ```
2. Compute substep candidate inputs from `water_to_matrix_m3_per_h * dt` and `water_to_macropore_m3_per_h * dt`.
3. Compute `matrix_overflow_m3 = @max(0, matrix_input - @max(0, matrix_air_m3))` and `macro_overflow_m3 = @max(0, macro_input - @max(0, macro_air_m3))`.
4. Add `(matrix_overflow_m3 + macro_overflow_m3)` directly to `self.litter_ingress_step_m3[cell]` (and adjust `self.base_water_to_matrix_m3_per_h` / `water_to_macropore` or substep actual inputs).
5. Accumulate substep overflow water and heat into hourly accumulators on `CoupledState`:
   `self.overflow_water_total_m3[cell] += overflow_m3`,
   `self.overflow_heat_total_megajoules[cell] += 4.19 * T_atm * overflow_m3`.

---

### 3. State & Ledger Adjustments

1. **Water**:
   - `litter_water_m3` receives `(normal_litter + overflow_m3)`.
   - `grid.matrix_liquid_water_m3[top]` receives `matrix_input - matrix_overflow_m3`.
   - `state_updateSoilIngress` will never exceed pore capacity.
2. **Heat (Avoiding Rate Accumulation Drift)**:
   - `bindSoilHeatIngress` (`hourly_heat_water_solute.zig:4327`) and `state_updateLitterHeatIngress` (`:4358`) run *before* `CoupledHooks.prepareSubstep` in `advanceSubstep`.
   - Instead of trying to alter the rates in `direct_precipitation` per substep, subtract the accumulated `overflow_heat_total_megajoules[cell]` from topsoil sensible/boundary heat and add it to litter heat when closing the hour in `acceptedCellActivity` (`hourly_heat_water_solute.zig:9195-9218`).
3. **Ledger Booking (File:Line)**:
   - In `stages/hourly_heat_water_solute.zig:9195-9197` and `atmosphere/local_conservation_sidecar.zig:88-91`:
     ```zig
     .liquid_to_surface_litter_m3 = self.base_water_to_litter_m3_per_h[cell] + self.overflow_water_total_m3[cell],
     .liquid_to_topsoil_matrix_m3 = self.base_water_to_matrix_m3_per_h[cell] - self.matrix_overflow_total_m3[cell],
     .liquid_to_topsoil_macropore_m3 = self.base_water_to_macropore_m3_per_h[cell] - self.macro_overflow_total_m3[cell],
     ```
     This perfectly preserves $\sum \text{routed} = \text{rain}$, maintaining bit-for-bit closure in `acceptedCellActivity` without triggering `AtmosphericLocalPrecipitationRouteMismatch`.
4. **Precipitation-Solute Routing**:
   - In legacy, rain solute routing (`solute.f:3865-3898`) uses pre-redistributed volume or initial partition.
   - `hourly_process_driver.zig:755-776` partitions `direct_surface_solute_input` at hour start. To remain strictly conservative without re-speciating solutes inside the water substep, do NOT move already-deposited solute; water alone overflows as dilute/clean runoff into litter, exactly matching `watsub.f:943` where only water ($FLYM$) and convective heat ($HWFLYM$) are updated.

---

### 4. Discriminating Unit Test

Add to `surface/precipitation.zig`:
```zig
test "substep pore capacity saturation diverts excess rain to litter preserving water and enthalpy" {
    // Topsoil with matrix_air = 0.0001 m3, macropore_air = 0.
    // Incoming rain matrix_input = 0.0005 m3.
    // Verify FLQRS diverts 0.0004 m3 to litter.
    // Verify matrix_liquid increases by exactly 0.0001 m3.
    // Verify total water (litter + soil) == 0.0005 m3.
    // Verify redirected heat == 4.19 * T_atm * 0.0004 MJ.
}
```
