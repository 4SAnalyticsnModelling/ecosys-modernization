# Adversarial Review: Round 00014 — Commits a83519a (FLQRS Rain Overflow) & 1b098e1 (Phosphate Site Projection)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target Commits**:  
- `a83519a`: Legacy per-cycle FLQRS rain overflow to litter (`stages/hourly_heat_water_solute.zig`)  
- `1b098e1`: Exact phosphate exchange-site projection (`soil/solute/reaction_solver_evaluate.zig`, `reaction_solve.zig`, `ecosys_ng.zig`)

---

### 1. Audit of Commit a83519a (FLQRS Rain Overflow)

#### 1.1 Water Conservation & Rollback
- **Accounting & Double Counting**: In `Forcing.prepareSubstep` (`:719-754`), overflow is calculated against instantaneous available air capacity ($\text{capacity} - \theta_l - \theta_i/\rho_i$). The exceeding portion is moved from `water_to_matrix_m3_per_h` / `water_to_macropore` to `water_to_litter_m3_per_h`. Both `state_updateLitterIngress` (`:755`) and `state_updateSoilIngress` (`:872`) consume the edited substep rates.
- **Substep Rejections vs Schedules**: In `soil/water/heat_step.zig:707-710`, before any recovery ladder attempt, `hooks.restore_schedule` calls `Forcing.restoreSchedule` (`hourly_heat_water_solute.zig:649-666`), which strictly zeroes `ingress_overflow_matrix_total_m3` and `ingress_overflow_macropore_total_m3`. Substeps *inside* an attempt execute monotonically; if a substep fails, `heat_step.zig:733,789` breaks the loop, triggers `restore_schedule`, and restarts from clean totals. Thus, rolled-back substeps can never contaminate the accepted schedule totals.
- **Atmospheric Route Closure**: In `acceptedCellActivity` (`:9297-9305`), the ledger routes:
  $$\text{litter} = \text{base} + \text{matrix\_overflow\_total} + \text{macro\_overflow\_total}$$
  $$\text{matrix} = \text{base} - \text{matrix\_overflow\_total}, \quad \text{macro} = \text{base} - \text{macro\_overflow\_total}$$
  The sum equals $\sum \text{base}$, satisfying `AtmosphericLocalPrecipitationRouteMismatch` to machine precision.

#### 1.2 Heat Remainder & Snowmelt Interactions
- **Heat Exactness**: In `CoupledState.prepareSubstep` (`:4381-4433`), `overflow_heat_rate = c \cdot T_{atm} \cdot \text{overflow\_rate}` is priced out of soil heat and into litter heat before `bindSoilHeatIngress` (`:4434`). Topsoil heat remainder (`soilIngressHeatRemainder` at `surface/precipitation.zig:465`) computes $(H_{soil} - c T_{soil} W_{soil}) dt$. Because $H_{soil}$ and $W_{soil}$ are reduced by matching advective rates $c T_{atm} \Delta W$ and $\Delta W$, thermal conservation holds exactly.
- **Snowmelt Edge Case**: Snowmelt is added to `surface_precipitation` rates in `advanceSnowBeforeSoil` (`:5648-5650`) while direct heat binding uses `base_water_to_matrix_m3_per_h`. In `:4418`, `overflow_matrix_rates[cell] = @max(0, overflow_matrix_rates[cell] - matrix_overflow_rate)` caps at zero. If snowmelt alone causes topsoil saturation, direct rain rates are clamped to 0 and excess snowmelt overflows to litter; snow melt heat is handled separately in `snow_surface_transfer_heat.zig`. No enthalpy is fabricated or lost.

**Verdict: ACCEPT**

---

### 2. Audit of Commit 1b098e1 (Phosphate Site Projection)

#### 2.1 Charge-Gate Invariance & Tolerance
- **Mechanism**: In `restoreInterpolatedPhosphateSites` (`reaction_solver_evaluate.zig:407-422`), the residual $\Delta \Sigma = \Sigma_{entry} - \Sigma_{current}$ is added directly to the largest FREE site owner (`deprotonated`, `hydroxyl`, or `protonated`).
- **Charge Implication**: `reaction_charge.zig:47-52` assigns charges:
  $$\text{SXOH}_2^+ (+1), \quad \text{SXOH}^0 (0), \quad \text{SXO}^- (-1)$$
  If the roundoff correction ($\sim 10^{-11}\text{ mol/Mg}$) is applied to $\text{SXO}^-$ instead of $\text{SXOH}^0$, it alters net charge by $\Delta q = \Delta \Sigma \cdot \rho_{soil} \approx 3\times 10^{-11}\text{ mol charge/m}^3$.
- **Charge Gate Comparison**: In `reaction_charge.zig:65`, the charge closure threshold is:
  $$\text{limit} \ge 2048 \cdot \epsilon_{\text{float64}} \cdot \text{scale} \approx 4.5\times 10^{-13} \cdot 10^2 \approx 4.5\times 10^{-11}\text{ mol/m}^3$$
  The drift correction magnitude ($3\times 10^{-11}$) is safely within the $2048 \epsilon$ gross scale gate. Furthermore, since $\Delta \Sigma$ represents numerical interpolation dust, adjusting the predominant free site does not perturb physical chemistry while successfully restoring elemental site conservation.

**Verdict: ACCEPT**
