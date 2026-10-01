# Round 00046: Audit of Non-Fire Step Constants Lacking XNFH

## 1. Inventory of Non-XNFH Constants
In wthr.f:619-622:  = 1/NPH$,  = XNPXX/NPS$,  = XNPXX/NPR$,  = XNPXX/(NPS\cdot NPRS)$. Because soil.f:145-157 calls WATSUB =4$ times/h, state-fraction clamps scaled by these constants repeat $ times per hour. All occurrences are **Fraction of State** donor clamps, none are dimensional Rate $	imes$ Time fluxes.

| Routine : Line | Quantity / Expression | Type | ng Equivalent | Match? | Rank |
| :--- | :--- | :--- | :--- | :--- | :---: |
| watsub.f:1458 | Melt drainage: (VOLW02-0.05*VOLS02)*XNPSX | Fraction | snow_melt_water_routing:80 | Fixed (r00045) | **1** |
| watsub.f:1626 | Topsoil melt entry: min(VOLP1*XNPSX, ...) | Fraction | snow_melt_water_routing:69 | Fixed (r00045) | **2** |
| watsub.f:6407,6438 | Soil freeze/thaw: clamp(±333*VOL*XNPXX) | Fraction | soil_water_thermal_phase | ng Newton solve | **3** |
| watsub.f:3739,3770 | Ponded water drainage: min(XVOLW*XNPXX) | Fraction | surface/water_flow.zig | ng per-hour | **4** |
| watsub.f:2391,2397 | Snow freeze clamp: clamp(±333*VOL*XNPSX) | Fraction | snow_phase_change.zig:279 | Full inventory | **5** |
| watsub.f:2779,3202 | Soil/litter evap clamp: max(-VOLW*XNPXX) | Fraction | surface/temperature_solver.zig| ng per-substep | **6** |
| watsub.f:4973,5894 | Macropore drainage: clamp(-VOLWH1*XNPXX)| Fraction | solver_hydraulics.zig | ng MvG solve | **7** |
| watsub.f:6064,6128 | Water table clamp: min(FLWU, VOLPD*XNPXX)| Fraction | solver_hydraulics.zig | ng boundary | **8** |
| watsub.f:1279,2318 | Snow vapor clamp: clamp(-VOL*XNPSX) | Fraction | snow_vapor_diffusion.zig | ng per-substep | **9** |
| watsub.f:3126,3153 | Litter freeze/evap: clamp(±333*VOL*XNPRX)| Fraction | surface_water_flow.zig | ng Picard solve | **10** |
| watsub.f:1928,2054 | Sub-snow vapor: clamp(-VOL*XNPSRX) | Fraction | hourly_heat_water_solute.zig | ng per-substep | **11** |
| rosion.f:86,165 | Soil detachment: min(BKVL*XNPXX, ...) | Fraction | surface/erosion.zig | ng per-hour | **12** |

*Note on Heave*: watsub.f:3684, 4899 uses XNPZX = XNPHX*XNPR, which already contains XNFH.

## 2. Impact Ranking & Findings on Ottawa Run
1. **Rank 1–2 (Snowmelt Drainage - watsub.f:1458, 1626)**: Highest impact. Fixed in commit ee72fb (1 - exp(-NFH*dt)). Resolves the 77 mm early-January SWE gap.
2. **Rank 3 (Soil Freeze/Thaw Bounds - watsub.f:6407-6440)**: High impact during freeze-up. ng's Newton solve directly captures the continuous physical freeze rate without step-size distortion.
3. **Rank 4 (Ponded Water Drainage - watsub.f:3739, 3770)**: Clamps infiltration of ponded surface water into soil macropores. In ng, macropore exchange is solved concurrently with the matrix hydraulics.
4. **Rank 5–12 (Vapor/Infiltration Clamps)**: Low impact. Mostly safeguard clamps on secondary vapor diffusion and macropore drainage where physical conductances are already limiting.
