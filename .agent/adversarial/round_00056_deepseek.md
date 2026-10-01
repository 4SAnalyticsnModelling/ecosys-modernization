# Round 00056: Root Cause of the Heat Leak in DEV-014 Bounded Publication

## 1. Concrete Mechanism of the Heat Leak
The leak is a **desynchronization between state enthalpy, displacement enthalpy, and reference heat** when taking the `bounded_phase_stagnation` path at `phase_solver.zig:1190`:

1. **State Overwrite without Re-evaluating Displacement (`phase_solver.zig:1224-1238`)**:
   - At line 1190, `boundedPhaseStagnationPublishable` breaks.
   - At line 1201, `residualAt` populates `trial_displacement` and `target` from `current`.
   - Line 1224 overrides state water coordinates: `current[0..5*cells] = target`.
   - Crucially, `residualAt` is **bypassed** under stagnation (`if (!bounded_phase_stagnation) try residualAt(...)` at line 1237).
   - In the converged path, `residualAt` runs at the accepted endpoint, ensuring `trial_displacement` matches final state. Under bounded publication, `trial_displacement` remains bound to the pre-target iterate.
2. **The 2.06e-3 MJ Arithmetic Identity**:
   - At hour 8470, the stalled iterate froze additional ice into a rigid pore, triggering `displaceRigidPoreOverfill` (`phase_solver.zig:1787, 1975`).
   - `displaceRigidPoreOverfill` computed liquid displacement V_disp = 4.597e-7 m3 and debited advective enthalpy:
     H_adv = V_disp * c_liq * T_base = 4.597e-7 * 4.19 * 271.73 = 5.234e-4 MJ.
   - However, `closeStalledPhaseTemperature` (`phase_solver.zig:1274`) and `evaluatePhaseEnergyConservation` (`phase_solver.zig:1407`) evaluate closed temperature T1 assuming H_adv left the layer.
   - In `heat_step.zig:2208-2228`, the layer's reference heat `phaseEndpointReferenceHeatMegajoules` is computed from `grid.matrix_ice_water_m3` and `grid.water_vapor_volume_m3`. Because `current[0..5*cells]` was forced to `target`, the ice change delta_V_ice = 5.086e-6 m3 generates reference heat:
     H_ref = (c_liq - c_ice) * T_melt * delta_V_ice = (4.19 - 1.9274) * 273.15 * 5.086e-6 = 3.143e-3 MJ.
   - When `advanceAcceptedPhaseDisplacement` (`hourly_heat_water_solute.zig:4584-4740`) routes displacement upward to layer 0 / surface, it subtracts displaced enthalpy from layer 0. The discrepancy between the frozen enthalpy coordinate change (H_ref - H_phase) and the un-converged displacement enthalpy is:
     delta_H_net = H_ref - (H_phase - H_adv) = 3.143e-3 - (1.6935e-3 - 0.523e-3) = 1.97e-3 ~ 2.06e-3 MJ.

## 2. Why the Substep Ladder Closes Exactly
When the substep ladder splits the step (20 substeps), the smaller step avoids rigid-pore overfill, `trial_displacement` is zero, and Newton converges naturally (norm <= 1), ensuring `residualAt`, `acceptedLatentHeat`, and `cellEnthalpyMegajoules` evaluate on identical states.

## 3. Remedy
Refuse DEV-014 publication whenever `hasDisplacement(trial_displacement)` is true (`phase_solver.zig:1211`), forcing the ladder to subdivide to a step size where displacement and phase enthalpy converge consistently.
