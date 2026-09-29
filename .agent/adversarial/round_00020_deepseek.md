# Adversarial Review: Round 00020 — Explicit Boundary Gas Pressure Displacement (DEV-012)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: DEV-012: `explicit_boundary_pressure` in `coupled_gas_solver_residual.zig:227-256`, `atmosphere_exchange.zig:73-95`, and `transport.zig:515-531`.  
**Legacy Reference**: `f77src/trnsfr.f:3300-3335, 3350-3375, 5300-5325`  
**Problem Identified by CLAUDE**: Hour 2169 `CoupledGasSolverStagnated` when litter air space is small ($2.9\times 10^{-5}\text{ m}^3$) under ponded water, and initial dry gas is 2% of capacity. Implicit candidate evaluation causes $(C - \Sigma n)\cdot n_i / \Sigma n$ to have a near-singular Jacobian ($J_{ii} \propto 1/\Sigma n \to \infty$ or vanishes), preventing Newton convergence.

---

### 1. Stability, Conservatism, and Overshoot Risk (Question 1)

1. **Conservation & Bounds**:  
   In `transport.zig:525-528`:
   ```zig
   const bulk_flux_mol = (capacity_mol - actual_mol) * iteration_fraction;
   flux.* = bulk_flux_mol * (mass / molar_mass) / actual_mol * molar_mass;
   flux.* = @max(-mass * iteration_fraction, flux.*);
   ```
   And in `coupled_gas_solver_residual.zig:232, 259`:
   ```zig
   const accepted = @max(-gas_target[index], flux);
   gas_target[index] += accepted;
   ```
   The outward flux is strictly donor-clamped to `gas_target` and never exceeds available resident mass. Atmospheric influx draws from an infinite boundary pool, perfectly matching legacy `RFL*G`.
2. **Overshoot Under Combined Influx (Diffusion + Pressure)**:  
   Could an inflow with $f=1$ overshoot pore capacity if diffusion simultaneously fills the air?  
   - Yes, locally in total moles. If pressure influx brings inventory to $100\%$ capacity and diffusion also drives net inflow, total pressure slightly exceeds atmospheric.  
   - However, in the very next substep/cycle, `actual_mol > capacity_mol` generates a negative `bulk_flux_mol` (outward advective vent), restoring isobaric equilibrium.
   - For subsurface boundaries (`inputs.subsurface_boundaries`), boundary flux is similarly clamped against `gas_target`. Because diffusion and phase dissolution are solved *after* boundary pressure is added to `gas_target` (`residual.zig:233`), the state remains physically well-posed without blowing up.

---

### 2. Legacy Sub-cycling vs Single-Step Form (Question 2)

1. **Legacy Mechanism (`trnsfr.f:3311-3330`)**:  
   Legacy runs inside an inner loop `DO 1000 MM=1,NPG` with subcycle step $XNPGX = 1/NPG$:
   $$VGFLW = (VTATM - VTGAS) \cdot XNPGX, \quad RFL*G = VGFLW \cdot \frac{V*G2}{VTGAS}$$
   Each subcycle updates $VTGAS$ explicitly.
2. **Alternative Formulations**:  
   - **Lagged Composition with Implicit Total**: Solving total gas volume implicitly ($\Sigma n \to C$) while using base fractions $n_i / \Sigma n$ linearizes the diagonal blocks without the $1/\Sigma n$ singularity.
   - However, evaluating the entire pressure displacement at `base` ($f = 1$ or $f = \Delta t$) is **completely consistent with an operator-split convection step**. Since TRNSFR's bulk pressure flow is fundamentally an advective relaxation rather than a chemical equilibrium, treating it as an explicit pre-solve target modification is mathematically sound and matches legacy's sequential structure.

---

### 3. Consistency with Intercell Face Pressure Displacement (Question 3)

In `coupled_gas_solver_residual.zig:163-196`:
```zig
// TRNSFR pressure displacement is a sequential donor-bounded inventory
// correction, not a constitutive equilibrium. Assemble it explicitly from
// the conservative target before solving the differentiable diffusion...
```
Intercell face convective displacement (`adjacentPressureDrivenFluxesGFromValidatedInputs`) **is already evaluated explicitly on `gas_target`** before the implicit Newton diffusion solve.  
Evaluating atmospheric/subsurface boundary pressure displacement explicitly on `base` brings the boundary condition into **exact symmetry and consistency** with intercell face transport.

---

### Verdict: ACCEPT
Commit DEV-012 resolves the artificial singularity in thin/ponded air layers while preserving physical conservation and solver consistency across boundaries.
