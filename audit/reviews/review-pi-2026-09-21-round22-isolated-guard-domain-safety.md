# Adversarial Review Round 22: Safety Audit of the Isolated Entry Overfill Guard Relaxation

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Safety evaluation of relaxing the hour-entry guard in `ecosys-ng/src/soil/profile/runtime_material_refresh.zig:307` from `previous_matrix_capacity_m3` to `matrix_bulk_volume_m3` in isolation.

---

### Verdict: SAFE

Auditing the complete consumption chain in `solver_flux.zig`, `solver_residual.zig`, `flux.zig`, and `solver_hydraulics.zig` confirms that relaxing the entry guard to `matrix_bulk_volume_m3` does **NOT** create a silent invalid/panicking state or unphysical calculation path:
1. **No division by zero or negative air**: All consumers of air volume evaluate `derivedPhysicalAirVolumeM3` or clamp with `@max(0, ...)`. When occupied > capacity, air volume evaluates cleanly to $0.0$. Vapor flux explicitly returns 0 when air volume is 0.
2. **Derived air is universally clamped nonnegative**: The published carrier `grid.matrix_air_volume_m3` is set via `derivedPhysicalAirVolumeM3` (which returns `if (raw > 0) raw else 0`), exactly matching legacy Fortran `VOLP1 = AMAX1(0.0, VOLP1Z)`.
3. **Overfill cannot grow unbounded across hours**: The optimizer trial bounds in `solver_residual.zig:187-211` (`acceptedEntryLiquidCeilingM3`) strictly forbid the solver from manufacturing any additional overfill beyond what entered the hour. Furthermore, the entry state itself remains hard-capped by `matrix_bulk_volume_m3`, and vertical mechanical displacement continuously moves excess liquid upward whenever destination excess is negative.

---

### Detailed Audit Questions

#### (a) Does Any Consumer Divide by, or Assume Nonnegative, the Derived Air Volume in a Way That Misbehaves When `occupied > capacity`?
- **Finding: NO.**
- In `solver_flux.zig:88-90`:
  ```zig
  grid.matrix_air_volume_m3[cell] = try derivedPhysicalAirVolumeM3(grid.matrix_pore_capacity_m3[cell], matrix, grid.matrix_ice_water_m3[cell], properties.ice_density_megagrams_per_m3);
  ```
- In `solver_flux.zig:134-137`:
  ```zig
  pub fn derivedPhysicalAirVolumeM3(...) !f64 {
      const raw = try physicalPoreSpaceM3(capacity_m3, liquid_m3, ice_water_equivalent_m3, ice_density_megagrams_per_m3);
      return if (raw > 0) raw else 0;
  }
  ```
  When `matrix_occupied > matrix_pore_capacity_m3`, `raw < 0`, and `derivedPhysicalAirVolumeM3` returns `0.0`.
- In `flux.zig:208-210` (Vapor flux):
  ```zig
  if (inputs.source_air_volume_m3 == 0 or inputs.destination_air_volume_m3 == 0) return .{ .unlimited_vapor_m3 = 0, .limited_vapor_m3 = 0, .conductance_m_per_h = 0 };
  const source_concentration = @max(0.0, inputs.source_vapor_volume_m3 / inputs.source_air_volume_m3);
  ```
  Zero air volume is guarded by an explicit early return of zero vapor flux before any division occurs.
- In `flux.zig:69-76` (Richards matrix face flux):
  Air volume enters only as an upper bound on incoming water flux into the destination:
  ```zig
  limited = @max(0.0, @min(unlimited, @min(source_available * inputs.time_fraction, inputs.destination_air_m3 * inputs.time_fraction)));
  ```
  When `destination_air_m3 == 0`, `limited = 0.0`. It prevents Darcy influx into an already full/overfilled cell.
- In `solver_hydraulics.zig:301-325`:
  Matric potential is evaluated on volumetric moisture fraction `matrix / matrix_bulk_volume_m3`, and clamped to `[residual, saturated]`. Overfill beyond pore capacity simply clamps to saturated water content (pressure head $\to 0$).

#### (b) Is the Derived Air Carrier Genuinely Clamped at Zero Everywhere It is Published, So No Consumer Ever Sees Negative Air?
- **Finding: YES.**
- In `runtime_material_refresh.zig:332`:
  ```zig
  const matrix_air = @max(0, matrix_capacity - matrix_occupied);
  const macro_air = @max(0, macro_capacity - macro_occupied);
  ```
- In `solver_flux.zig:136`:
  `derivedPhysicalAirVolumeM3` guarantees nonnegative air.
- In `boundary.zig:209-211`:
  ```zig
  grid.matrix_air_volume_m3[layer] = if (matrix_air_m3 < 0) 0 else matrix_air_m3;
  ```
- In `hydrology.zig:112`:
  ```zig
  result.matrix_air_volume_m3[layer] = @max(0.0, matrix_pore_volume_m3 - matrix_water_m3 - matrix_ice_m3);
  ```
- Across all modules, published `matrix_air_volume_m3` and `air_volume_m3` are strictly non-negative.

#### (c) Can the Overfill Grow Without Bound Across Hours, or Is It Bounded?
- **Finding: It CANNOT grow without bound.**
- **Bound 1: Solver Residual Ceiling**:
  In `solver_residual.zig:187-211`:
  ```zig
  const matrix_entry_ceiling = try group_flux.acceptedEntryLiquidCeilingM3(grid.matrix_pore_capacity_m3[cell], base[cell], grid.matrix_ice_water_m3[cell]);
  if (trial[cell] > matrix_entry_ceiling + group_hydraulics.poreCapacityRoundoffToleranceM3(matrix_entry_ceiling))
      return error.SoilWaterCandidateExceedsPoreCapacity;
  ```
  Where `acceptedEntryLiquidCeilingM3` (`solver_flux.zig:127`) defines the ceiling as `@max(capacity_m3, entry_liquid_m3 + ice) - ice`.
  The Newton-Raphson/Anderson solver is strictly prohibited from proposing or accepting a state that has *more* overfill than the hour entered with.
- **Bound 2: Physical Bulk Volume Ceiling**:
  `runtime_material_refresh.zig` rejects any state exceeding `matrix_bulk_volume_m3`.
- **Bound 3: Mechanical Displacement Drainage**:
  In `solver_residual.zig:53-73`:
  ```zig
  const matrix_excess = try group_flux.physicalPoreSpaceM3(grid.matrix_pore_capacity_m3[destination], target[destination], ...);
  const requested_matrix = try water_flux.mechanicalFreezingDisplacementM3(target[destination], matrix_excess, ...);
  ```
  Whenever `matrix_excess < 0` (overfill), `requested_matrix` generates an upward displacement flux into `source` (layer above), relieving the overfill.
- Therefore, overfill cannot accumulate or drift unbounded; it is monotonically bounded from above by the solver ceiling and continuously drained by mechanical displacement.

---

### Conclusion

The isolated relaxation of the hour-entry guard to `matrix_bulk_volume_m3` is **SAFE**. It faithfully mimics legacy Fortran's admittance of transient compaction/freeze overfill without violating physical invariants, causing negative air divisions, or permitting unbounded runaway overfill.
