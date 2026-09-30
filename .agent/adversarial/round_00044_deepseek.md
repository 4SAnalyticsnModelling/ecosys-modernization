# Round 00044: SWE Semantics, Snowpack Fate & Insulation Analysis

## 1. SWE Column Definition & Comparability
- **Legacy (outsh.f:123-124)**:
  HEAD(M) = max(0, (VOLSS + VOLIS*DENSI + VOLWS) * 1000 / AREA)
  Legacy reports **total snowpack water equivalent** (solid snow + ice + liquid water).
- **cosys-ng (cosys_ng.zig:934-936)**:
  Passes surface_precipitation.solid_snow_water_equivalent_m3 + **litter_water_m3** + **surface_litter_ice_m3**.
  **Semantics Defect**: Ng omits liquid water and ice inside snow layers (snow_transport.liquid_water_volume_m3, ice_volume_m3), mistakenly binding litter moisture instead!

## 2. Fate of Legacy Snow (DOY 6–10)
- **All Phases Included**: Legacy SWE includes all phases (VOLSS + VOLIS*DENSI + VOLWS).
- **Snowfall Partitioning (watsub.f:462)**: All snowfall is routed to snowpack (FLWSW = PRECW) with zero threshold gating.
- **Where does the 8–9 mm/day go?**
  In legacy watsub.f:1457, positive net radiation melts snow. Liquid exceeding the 5% holding capacity (FLWQX = max(0, VOLW02 - 0.05*VOLS02)) drains into topsoil/litter (FLWQG/FLWQR). Legacy continuously infiltrates meltwater into Layer 1 even while snow falls.

## 3. Insulation & Thermal Regimes (DOY 6–15)

| DOY | Leg SWE | ng SWE | Leg Depth (cm) | ng Depth (cm) | Leg {L1}$ (°C) | ng {L1}$ (°C) | Leg Ice1 | ng Ice1 |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **6** | 35.9 | 43.6 | 13.8 | 21.8 | -0.38 | -0.16 | 0.092 | 0.042 |
| **8** | 29.1 | 66.1 | 11.2 | 33.1 | -0.24 | +0.37 | 0.109 | 0.000 |
| **10** | 14.9 | 89.5 | 5.7 | 44.7 | -0.57 | +1.06 | 0.118 | 0.000 |
| **11** | 17.2 | 89.2 | 6.6 | 44.6 | **-3.26** | **+1.17** | **0.243** | **0.000** |
| **12** | 66.3 | 88.9 | 25.5 | 44.5 | **-3.79** | **+1.25** | **0.266** | **0.000** |
| **15** | 9.9 | 92.4 | 3.8 | 46.2 | -1.84 | +1.71 | 0.267 | 0.000 |

- **Insulation Contrast**: Melt drainage keeps legacy pack thin (5.7–11 cm on DOY 8–10). On DOY 11–12 ($-18$ °C air), freeze penetrates the thin pack, freezing Layer 1 to $-3.8$ °C (ice = 0.266). In ng, zero melt drainage accumulates 45 cm snow, insulating topsoil at $+1.2$ °C (0 ice).

## 4. Primary Defects & Corrections
- **Defect 1 (Output Binding)**: cosys-ng/src/ecosys_ng.zig:934-936: 25wh1 col 12 binds litter water/ice instead of the snowpack's internal liquid/ice (snow_transport.liquid_water_volume_m3, ice_volume_m3).
- **Defect 2 (Physics)**: cosys-ng/src/surface/temperature_solver.zig:887-889: Daytime absorbed solar is scaled by snow_free_fraction ( - F_{	ext{snw}} pprox 0$), eliminating solar warming over snow and preventing melt.
