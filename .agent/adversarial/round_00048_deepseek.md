# Round 00048: Snowpack Energy Budget & Physics Mismatch

## 1. Quantification: Legacy Snow Energy Terms (DOY 6-10)
Legacy energy budget components over DOY 6-10 (values in MJ/m2, from f25eh1 and gbf98h):
- Precipitation: Rain = 1.60 mm (DOY 6: 1.3 mm, DOY 8: 0.3 mm; Tair > -0.25 C), Snow = 62.60 mm.
- Rain Heat Input: Q_rain = 4.19 * Tair * P_rain = +0.01 MJ/m2.
- Net Radiation: Rn = -22.06 MJ/m2 (nighttime LW cooling dominates; daytime positive Rn sum is +1.20 MJ/m2).
- Latent Heat Flux: LE = 0.00 MJ/m2 (no sublimation/evaporation).
- Ground Storage Flux: G = +0.015 MJ/m2.
- Sensible Heat Flux: H = -8.26 MJ/m2 (net upward; daytime downward positive H sum is +1.24 MJ/m2).
- Thermal Conductance from Ground: Snow-litter conduction (watsub.f:2028, HFLWSR ~ 0) is negligible because topsoil Layer 1 remains frozen (-0.1 to -0.5 C).

Decisive Finding: Total external environmental heat input (SW + sky LW + rain + ground heat) is < 2.5 MJ/m2. External thermal energy cannot provide the 18.4 MJ/m2 needed for 55 mm of phase-change melt.

## 2. Source of the Apparent 55 mm Melt: Numerical Snow Ablation in Legacy
In legacy, snow is not melted by external heat; it is removed by an unconditional state-transfer bug in redist.f:2416-2588:
1. In watsub.f:1384, FLW0S(1) = FLQ0S2 + EVAP02S records new snowfall into snow layer 1.
2. In watsub.f:2254, TFLWSX = FLW0S(L).
3. In watsub.f:2488, XFLWS(L) = XFLWS(L) + FLW0S(L).
4. Then in redist.f:2416-2588, inside the vertical boundary loop N=3, redist.f executes:
   TFLWS(LS,N2,N1) = TFLWS(LS,N2,N1) + XFLWS(LS,N2,N1) - XFLWS(LS2,N2,N1)
   For the bottom layer LS, line 2588 executes without subtracting downward snow:
   TFLWS(LS,N2,N1) = TFLWS(LS,N2,N1) + XFLWS(LS,N2,N1)
   This duplicates or drops snow mass across the subcycling interfaces when VHCPWM2 <= VHCPWX.
5. Simultaneously, watsub.f:1457 drains liquid FLWQX = max(0, VOLW02 - 0.05*VOLS02) * XNPSX into soil regardless of snow temperature whenever VOLW02 > 0.

## 3. Comparison with ecosys-ng Implementation
- Sensible Conductance: snow_surface_atmosphere_exchange.zig:508-527. Correct analytic solve against air temperature.
- Rain Heat / Phase Routing: snow_surface_atmosphere_exchange.zig:492-494 (carrier_sensible).
- Ground Thermal Coupling: snow_base_thermal_coupling.zig:41-80. Correct harmonic conduction.
- The Gap: ng enforces rigorous conservation of energy (Q = m * L_f). Because winter net radiation and sensible heat are negative, ng snow temperature stays below freezing and does not ablate snow without physical heat. Legacy rapid winter snow depletion on DOY 6-10 is non-physical numerical leakage through watsub.f:1458 / redist.f:2588.
