# Round 00032 Adversarial Challenge: DEV-014 Bounded Phase Stagnation & FINH Exchange Kink

## 1. Physical Units & Total Water Defect in `residualAt`
- In `phase_solver.zig:1599-1840`:
  - Component 0 (`matrix_water`): liquid volume ($m^3$).
  - Component 1 (`vapor`): water vapor equivalent liquid volume ($m^3$). In `phase_change.zig:32`, `vapor_change_m3 = -water_condensation_m3` in $m^3$ water equivalent liquid.
  - Components 2 & 4 (`matrix_ice`, `macro_ice`): water-equivalent ice volume ($m^3$). Lines 1683, 1711, 1910-1913 explicitly convert physical ice change to water-equivalent via `change.ice_volume_change_m3 *= ice_density`.
  - Component 3 (`macro_water`): liquid volume ($m^3$).
- Because all 5 water components are strictly denominated in **liquid-equivalent $m^3$**, the linear sum $\sum_{i=0}^4 \text{residual}_i$ is indeed the layer's net water-equivalent volume defect ($m^3$).

## 2. Downstream Per-Domain Closure Impact of Publishing `current`
Publishing `current` (`state_update` at line 1197) while `outputs.macropore_to_matrix_water_m3` receives `trial_exchange` evaluated at `residualAt(current)` (`target` in lines 1770-1772) breaks exact per-domain mass closure:
- In `heat_step.zig:2193`, `hydrology.macropore_to_matrix_water_flux_m3_per_step` records `trial_exchange` ($\Delta W_{\text{exch}}$).
- If $\text{current}_{\text{matrix}} \neq \text{target}_{\text{matrix}}$ (stalled residual $R_{\text{matrix}} = \text{target} - \text{current} \approx +3.98\times 10^{-11}\text{ m}^3$):
  $\text{grid.matrix\_liquid\_water\_m3}$ receives $\text{current}$, so $\Delta \text{matrix}_{\text{stored}} = \text{current} - \text{base} = (\text{target} - \text{base}) - R_{\text{matrix}} = \Delta W_{\text{vapor}} + \Delta W_{\text{freeze}} + \Delta W_{\text{exch}} - R_{\text{matrix}}$.
- This discrepancy of $R_{\text{matrix}}$ and $-R_{\text{macro}}$ causes **`hydrology.macropore_to_matrix_water_flux_m3_per_step`** to disagree with the actual stored delta between the two domains.
- Downstream in solute/tracer transport (`driver/transport_step.zig:414`, `mineral_nitrogen_transport.zig:479`, `organic/transport.zig:208`, `aqueous_extensive_transport.zig:134`), convective pore exchange routes solutes based on `macropore_to_matrix_water_flux_m3_per_step`. However, because `validatePerLayerPostRichardsTotalWaterClosure` (`heat_step.zig:3870-3875`) checks only the **summed total layer water** ($\text{matrix} + \text{macro} + \text{ice} + \text{vapor}$), the total water closure passes (summing to $\sim 10^{-13}\text{ m}^3$). But any strict per-domain water audit will detect a $4\times 10^{-11}\text{ m}^3$ transfer dislocation.

## 3. Legacy-Faithful Smooth Alternative
Legacy Fortran `watsub.f:6511-6533` does **NOT** iterate FINH in a nonlinear Newton loop. It integrates phase change and macropore-matrix exchange as an explicit sequential operator:
- It bounds `FINHX` directly using `VOLWH2` and `VOLP2` / `VOLPH2` as computed at that exact step sequence.
- In `phase_solver.zig:1757-1760`, evaluating `matrix_air` dynamically from Newton iterate `target` creates a non-smooth projection kink ($\min(\dots, \text{matrix\_air})$) inside the Picard/Anderson manifold right at zero air.
- **Legacy fix**: Evaluate the exchange limits on the substep entry state `base` (or smooth $\min(x, \text{air})$ via a narrow $C^1$ quadratic blend over $\varepsilon \sim 10^{-12}\text{ m}^3$), eliminating the derivative discontinuity and allowing Newton/Anderson to converge naturally.
