# Adversarial Analysis: Round 00026 — Surface Phase Discontinuity & Freeze-Thaw Energy Limit

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Hour 2786 (1998 d117 h02) `NewtonPicardDidNotConverge` in surface (litter/pond) temperature solve: Newton-Anderson pinned at $T \approx 273.14999308\text{ K}$ ($273.15 - 6.92\times 10^{-6}\text{ K}$).  
**Key Locations**: `surface/temperature_solver.zig:1441-1540`, `surface/litter_freeze_thaw_energy_limit.zig:107-135`, `soil/water/phase_change.zig:153-174`, `f77src/watsub.f:3134-3155`

---

### 1. Confirmation of the Discontinuity Mechanism

**Confirmed**. The root cause is a **mismatch between the freezing temperature used by Dall'Amico equilibrium and the threshold in the energy limiter**:
1. **Dall'Amico Equilibrium Temperature ($T_{m,\text{DallAmico}}$)**:  
   In `surface/temperature_solver.zig:1460-1468`, when ponded water saturates the layer ($W \ge W_{sat}$), `unfrozen_pressure_head_m = 0`. In `phase_change.zig:153-162`, `clapeyron_exponent = \rho g \psi / L = 0 \implies \exp(0) = 1.0`, so:
   $$T_{m,\text{DallAmico}} = T_{\text{pure}} = 273.15000000\text{ K}$$
   For any trial temperature $T < 273.15\text{ K}$, Dall'Amico computes $T < T_m$ and requests freezing: $\Delta \text{Ice}_{\text{req}} > 0$.
2. **Energy Limit Threshold ($T_{\text{freeze},\text{limit}}$)**:  
   In `temperature_solver.zig:1512` and `litter_freeze_thaw_energy_limit.zig:109-113`:
   $$T_{\text{freeze}} = \frac{-9.0959\times 10^4}{\psi - 333.0}$$
   At $\psi = 0\text{ MPa}$, $T_{\text{freeze}} = \frac{90959}{333} = 273.14984985\text{ K}$ (a numerical depression of $\Delta T = -1.5\times 10^{-4}\text{ K}$ due to single-precision truncation of $90959/333$ vs $273.15$). Even with $\psi = -0.0084\text{ MPa}$, $T_{\text{freeze}} \approx 273.14999308\text{ K}$.
3. **The Discontinuous Dead Zone**:  
   In the interval $T_{\text{freeze},\text{limit}} < T < T_{m,\text{DallAmico}}$:
   - Dall'Amico sees $T < 273.15\text{ K} \implies$ **requests freezing** ($\Delta \text{Ice}_{\text{req}} > 0$).
   - Energy limit sees $T > T_{\text{freeze}} \implies \text{deficit\_k} < 0 \implies$ **permits only thawing** ($\text{permitted\_ice} \le 0$).
   - `temperature_solver.zig:1525` computes:
     $$\text{limited\_ice\_change} = \min(\Delta \text{Ice}_{\text{req}}, \max(0, \text{permitted\_ice})) = 0$$
   - The phase latent heat drops instantaneously from finite values to $0$, creating a non-smooth step in $F(T)$. Newton-Anderson chatters across $T = 273.14999308\text{ K}$ and stagnates.

---

### 2. Legacy Ground Truth (`f77src/watsub.f:3134-3155`)

Legacy uses **one single variable, `TFREEZ`**, for both the threshold check and the flux drive:
```fortran
TFREEZ = -9.0959E+04 / (PSISVR - 333.0)
IF ((TKR2 .LT. TFREEZ .AND. VOLW2 .GT. 0) .OR. (TKR2 .GT. TFREEZ .AND. VOLI2 .GT. 0)) THEN
  HFLFRX = VHCPR2 * (TFREEZ - TKR2) * XNPR / (1.0 + 6.2913E-03 * TFREEZ)
```
Legacy does not employ a separate Clapeyron/Dall'Amico equilibrium for surface litter; both the branch switch and the kinetic driving force use identical $T_{\text{freeze}}$.

---

### 3. Minimal Legacy-Faithful Fix

Pass `depressed_melting_temperature_k` from the upstream equilibrium calculation into `freeze_thaw_energy_limit.apply` (or set `deficit_k = equilibrium.depressed_melting_temperature_k - temperature_k`):
1. In `surface/litter_freeze_thaw_energy_limit.zig:117`:
   Replace local `depressed_freezing_point_k` with `inputs.depressed_melting_temperature_k` (from `equilibrium.depressed_melting_temperature_k`).
2. This guarantees that `deficit_k` and `requested_ice_change_m3` change sign at the **exact same temperature**, making $\text{limited\_ice\_change}(T)$ continuous and Lipschitz at the phase transition boundary.
