# Round 00030 Adversarial Review: Surface Freeze-Thaw Drive Clamping

## 1. Continuity in T at $T_{\text{FREEZ}}$ and $T_m$
`surface/temperature_solver.zig:1524-1527` clamps `freezing_point_override_k` to $\min(T_{\text{FREEZ}}, T_m)$ for freezing ($\Delta \theta_{\text{ice}} > 0$) and $\max(T_{\text{FREEZ}}, T_m)$ for thawing ($\Delta \theta_{\text{ice}} < 0$).
- **Freezing**: At $T = \min(T_{\text{FREEZ}}, T_m)$, deficit $\Delta T \to 0$, giving continuous zero change. When $T_m < T_{\text{FREEZ}}$ (dry litter), equilibrium requests freezing only when $T < T_m$. Clamping sets $T_{\text{override}} = T_m$, so $\Delta T \to 0$ as $T \to T_m^-$. In $(T_m, T_{\text{FREEZ}})$, equilibrium requests no ice ($\Delta \theta_{\text{ice}} \le 0$).
- **Thawing**: At $T = \max(T_{\text{FREEZ}}, T_m)$, $\Delta T \to 0$ continuously. In $(\min, \max)$, if equilibrium requests thaw while $T < T_{\text{FREEZ}}$, override is $T_{\text{FREEZ}}$ ($\Delta T > 0$, freezing energy). In `litter_freeze_thaw_energy_limit.zig:125-132`, thawing requires $\Delta T < 0$, so thaw energy is 0, yielding `limited_ice_change_m3 = 0`.
- Permitted change is **C0 continuous** in $T$ everywhere; no steps exist.

## 2. Rate Comparison vs Legacy
- **Freezing rate**: Never exceeds legacy (`watsub.f:3150`). Clamping by $\min(T_{\text{FREEZ}}, T_m)$ ensures $\Delta T \le T_{\text{FREEZ}} - T$. Furthermore, `limited_ice_change_m3` is bounded by `requested_ice_change_m3` (`line 1537`), preventing Dall'Amico over-freezing.
- **Thawing rate**: Slower than legacy only in $(T_m, T_{\text{FREEZ}})$ when $T_{\text{FREEZ}} > T_m$ (held at 0 until $T > T_{\text{FREEZ}}$). For spring melt, ponded/snow-covered surfaces are near saturation where $T_{\text{FREEZ}} \approx T_m \approx 273.15\text{ K}$; the difference is negligible and water balance is strictly conserved.

## 3. Potential Provenance & Agreement
- **Context PSISVR**: From step-start `matric_plus_osmotic_water_potential_megapascal` (`watsub.f:3084-3121` Campbell piecewise retention + osmotic).
- **Dall'Amico head**: Inverted from total water content via continuous Mualem-van Genuchten (`surface/temperature_solver.zig:1460-1476`).
- **Agreement**: They disagree because Campbell piecewise fits vs smooth van Genuchten diverge at unsaturated litter moisture. The directional clamp harmonizes both without step artifacts.
