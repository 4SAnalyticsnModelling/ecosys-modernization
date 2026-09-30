# Round 00042: Early-January Snowpack & SWE Divergence Diagnosis

## 1. Initial Snowpack (Hour 1)
- 25top98 sets DPTHSX = 0.00 m. Both models initialize 0.0 m physical snowpack (starts.f:603 vs snowpack_initial_state.zig:180).
- Col 12 surface_water_equivalent = 0.8 mm in both models reflects initial surface litter moisture (starts.f:1648: VOLW(0) = 8.0e-6 * ORGC(0) = 0.8 mm), not antecedent snow.

## 2. Snow Fate & Cumulative Balances (DOY 1–10)

| DOY | Precip (mm) | Leg SWE | ng SWE | Leg dSWE | ng dSWE | Gap (mm) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **1** | 6.60 | 7.50 | 7.46 | +6.70 | +6.66 | -0.10 |
| **2-4** | 0.00 | 7.40 | 7.19 | -0.10 | -0.27 | +0.17 |
| **5** | 20.60 | 28.00 | 27.76 | +20.60 | +20.57 | 0.00 |
| **6** | 16.80 | 35.96 | 43.18 | +7.96 | +15.42 | +8.84 |
| **7** | 5.10 | 27.45 | 47.79 | -8.51 | +4.61 | +13.61 |
| **8** | 17.30 | 28.65 | 64.65 | +1.20 | +16.87 | +16.10 |
| **9** | 25.00 | 20.14 | 89.59 | -8.51 | +24.94 | +33.51 |
| **10** | 0.00 | 14.91 | 89.46 | -5.22 | -0.13 | +5.22 |
| **Total** | **91.40** | **14.91** | **89.46** | **+14.11** | **+88.66** | **+77.29** |

*Where Legacy Snow Goes*:
1. **Sublimation/Evaporation**: In 25wh1, ET = **0.00 mm** throughout DOY 1–10. In 25eh1, LE = **0.00 W/m²**. No snow evaporates.
2. **Drift**: 1D grid (NHW=NHE=1, NVN=NVS=1), boundary drift is zero.
3. **Melt to Litter/Soil**: The missing **77.3 mm** drains into topsoil/litter (watsub.f:1457, 1625-1632). Legacy actively ablates and infiltrates snow during subzero diurnal periods.

## 3. Energy Balance & Defect Attribution
- **Energy Balance Gap** (25eh1 vs ng):
  During DOY 6 midday (hours 11–13):
  - Legacy ground net radiation  = +8.7$ to $+15.8	ext{ W/m}^2$, warming the pack.
  - ng net radiation  = -4.6$ to $-11.0	ext{ W/m}^2$ (net daytime loss!).
  - ng sensible heat  = +5.8	ext{ W/m}^2$ (downward) vs legacy  = -15.5	ext{ W/m}^2$ (upward).
- **BARE Equivalence**: In legacy watsub.f:394, BARE = exp(-0.005*RSC) and CVRD = 1 - BARE. Because ng defines litter_cover_fraction = CVRD, 1 - litter_cover_fraction is algebraically identical to BARE.
- **Defects (ile:line)**:
  1. cosys-ng/src/surface/temperature_solver.zig:545: Surface radiative balance yields inverted daytime net radiation ( < 0$), preventing daytime snowpack heating.
  2. cosys-ng/src/soil/water/snow_melt_water_routing.zig:80: 
eleasableWater = max(0, liquid - 0.05*solid) * step_fraction. Multiplying by step_fraction throttles melt drainage, trapping water in the pack where it refreezes overnight instead of infiltrating soil.
