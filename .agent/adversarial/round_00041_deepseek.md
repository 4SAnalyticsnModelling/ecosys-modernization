# Round 00041: January Thaw Snowmelt & Runoff Diagnosis

## 1. Rain vs Snow Partitioning
Legacy splits precip at {thresh} = -0.25$ °C (wthr.f:50, 148, 201): {air} > T_{thresh} \implies$ rain = $, snow = $; {air} \le T_{thresh} \implies$ rain = $, snow = $ ($ if $<0.1	ext{ mm}$).
cosys-ng matches identically (weather.zig:299). January totals: **2.7 mm rain**, **132.3 mm snow** (0 mm rain on DOY 10–15).

## 2. January 10–15 Dynamics

| DOY | {air}$ | Leg SWE | ng SWE | Leg {L1}$ | ng {L1}$ | Leg Ice1 | ng Ice1 | Leg RO | ng RO |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **10** | +0.0 | 14.9 | 89.5 | -0.57 | +1.06 | 0.117 | 0.000 | 0.0 | 0.0 |
| **11** | -8.8 | 17.2 | 89.2 | -3.26 | +1.17 | 0.243 | 0.000 | 0.0 | 0.0 |
| **12** | -11.7 | 66.3 | 88.9 | -3.79 | +1.25 | 0.266 | 0.000 | 22.6 | 0.0 |
| **13** | -5.6 | 46.1 | 92.4 | -1.42 | +1.24 | 0.267 | 0.000 | 24.0 | 0.0 |
| **14** | -17.7 | 22.1 | 92.2 | -7.21 | +1.24 | 0.268 | 0.000 | 24.0 | 0.0 |
| **15** | -15.1 | 9.9 | 92.4 | -7.86 | +1.24 | 0.269 | 0.000 | 12.8 | 0.0 |

*Units: $ in °C, SWE/RO in mm, Ice in m³/m³.*

### Thaw & Runoff Diagnosis:
1. **Melt**: ng snow reaches 273.15 K on DOY 10 ({air} \le +1.5$ °C), melting 0.12 mm water.
2. **Path**: Meltwater percolates to lowest layer and enters litter/soil without refreezing.
3. **Runoff gap**: Legacy DOY 12–15 runoff (.4	ext{ mm}$) is **frost-heave displacement**, not melt runoff:
   - **Legacy**: Severe freeze freezes topsoil ({L1} = -3.8$ °C, ice = 0.266). Expanding ice creates negative pore space (watsub.f:3684: VOLP1ZN < 0), forcing water upward into litter (FLQR < 0). Ponding exceeds capacity (XVOLT > VOLWG), discharging 1.0 mm/h Manning runoff (watsub.f:3840-3852).
   - **ng**: Layer 1 **never freezes** ({L1} = +1.25$ °C, ice = 0.0). High snow entering DOY 10 (89.6 vs 14.9 mm SWE) insulates topsoil. Without freezing pore deficit, no water moves upward (0 mm runoff).

## 3. Code Owner and Defect
- **Owner**: cosys-ng/src/soil/water/snow_melt_water_routing.zig:66
- **Defect**: Lowest drainage are_delivery is scaled by (1 - inputs.litter_cover_fraction[cell]). In legacy watsub.f:1625, delivery to soil is FLWQGX = FLWQX * BARE(NY,NX), where BARE = exp(-0.005 * residue/area) (watsub.f:394) is residue-bare fraction ($pprox 0.95$–.0$). Confusing litter cover with bareness distorts melt drainage.
