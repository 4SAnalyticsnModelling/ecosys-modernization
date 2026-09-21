# Adversarial Review Round 14: Entry Overfill Drain Sufficiency Analysis

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial audit of drainage sufficiency for accepted hour-entry pore overfill (`matrix_liquid_water_m3 > matrix_pore_capacity_m3`) in `ecosys-ng`.

---

### Verdict: INSUFFICIENT

**Direct Answer to Question (1):**  
The upward drainage mechanism is **triggered by ENTRY overfill in the nonlinear water solve** (`applyMechanicalFreezingDisplacement`), **BUT that solve's upward transfer is BLOCKED from relieving overfilled layers whenever the shallower recipient is also at or near capacity**. Furthermore, the stage-level cascade (`advanceAcceptedPhaseDisplacement`) that reaches the surface litter is driven **ONLY by phase-change expansion (`phase_solver.solve`)**, NOT by unfrozen entry overfill.

Therefore, admitting the overfilled entry state in `runtime_material_refresh.zig` without an active, unblocked relief path will allow post-tillage excess liquid to persist and accumulate rather than reliably draining to the surface.

---

### Detailed Findings & Citations

#### (1) What triggers the drain: Entry overfill or Phase-change displacement?
There are two separate mechanisms with similar names and functions in `ecosys-ng`:

1. **The Solver-Internal Mechanical Prepass (`applyMechanicalFreezingDisplacement`)**:
   - **File & Lines**: `ecosys-ng/src/soil/water/solver_residual.zig:38-144`, called at `solver_residual.zig:212`.
   - **Trigger**: It inspects `matrix_excess = physicalPoreSpaceM3(...)` on the destination layer (`destination_cell`), which is computed from `target[destination]` initialized from `base[destination]` (the entry state). When `matrix_excess < 0` (entry overfill), it requests negative flux via `mechanicalFreezingDisplacementM3` (`flux.zig:93-106`).
   - **The Blockage**: Look at `solver_residual.zig:64-79`:
     ```zig
     const matrix_flux = group_flux.limitFluxForAssembledTarget(
         requested_matrix,
         target[0..cells],
         source,
         destination,
         try group_flux.physicalLiquidCapacityM3(source_capacity, ...),
         try group_flux.physicalLiquidCapacityM3(destination_capacity, ...),
     );
     ```
     In `solver_flux.zig:66-72`:
     ```zig
     return @max(
         flux_m3,
         -@min(
             @max(0.0, target[destination]),
             @max(0.0, source_capacity_m3 - target[source]),
         ),
     );
     ```
     For an upward flux ($flux < 0$), the relief amount is strictly clamped by `source_capacity_m3 - target[source]`.  
     **Consequence**: If layer $L$ is overfilled and the shallower layer $L-1$ is also full or overfilled (which Issue-078 proved is true for tillage: layers 1, 2, and 3 are all simultaneously over capacity), `source_capacity - target[source] <= 0`. Thus `matrix_flux` is clamped to **ZERO**. The internal prepass cannot move water upward through a saturated column.

2. **The Stage-Level Upward Cascade (`advanceAcceptedPhaseDisplacement`)**:
   - **File & Lines**: `ecosys-ng/src/stages/hourly_heat_water_solute.zig:4446-4571`, invoked via callback `acceptPhaseDisplacement` at line 4408 from `advanceMappedDeferred` (`heat_step.zig:793`).
   - **Trigger**: Driven strictly by `displacement_by_layer`, which originates in `phase_solver.zig:1668, 1820` (`displaceRigidPoreOverfill`). That routine only populates displacement when `phase_solver.solve` detects overfill during the freeze/thaw solve. In unfrozen conditions (or where ice is not expanding), `displacement_by_layer` is all zeros.
   - **Consequence**: Unfrozen tillage overfill does **not** trigger `advanceAcceptedPhaseDisplacement`.

#### (2) Is the drain rate donor-bounded?
- **Finding: YES.**
- In `ecosys-ng/src/soil/water/flux.zig:93-106` (`mechanicalFreezingDisplacementM3`):
  ```zig
  return @min(
      0,
      @max(
          -destination_liquid_water_m3 * time_fraction,
          destination_excess_pore_volume_m3,
      ),
  );
  ```
  This is the exact transliteration of legacy `watsub.f:4899-4900`:  
  `AMIN1(0.0, AMAX1(-VOLW2(N6,N5,N4)*XNPHX, VOLP1Z(N6,N5,N4)))`.

#### (3) Can the excess reach a sink outside the tilled zone (surface litter)?
- **Finding: NO, not during the water solve.**
- The stage-level cascade in `stages/hourly_heat_water_solute.zig:4540-4570` *does* terminate in the surface litter (`routePhaseDisplacementIntoSurfaceRecipient`), but as established in (1), it is only wired to `phase_solver.solve` displacement.
- In contrast, the solver-internal `applyMechanicalFreezingDisplacement` iterates only over soil-soil internal vertical faces (`faces` in `solver_residual.zig:40-43`). It has **no face connecting layer 0 to surface litter**.
- If layer 0 has no spare capacity, or if layers 1-3 cannot push water into layer 0 because `limitFluxForAssembledTarget` clamps to layer 0's spare capacity, the excess is trapped in the soil profile.

---

### Conclusion

Simply widening the entry guard in `runtime_material_refresh.zig` from `previous_matrix_capacity` to `matrix_bulk_volume_m3` admits the state, but `ecosys-ng` does **not** have an active mechanism to drain liquid overfill caused by tillage. The only path that terminates in the surface litter is gated on phase displacement, while the Richards solver's mechanical prepass is bounded by recipient spare capacity and lacks a surface sink. The excess will persist into subsequent hours.
