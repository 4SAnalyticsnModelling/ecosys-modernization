# Round 00045: Legacy Snowpack Mass Budget & Code Path Audit

## 1. Hour-by-Hour Snow Mass Budget (1998 DOY 6–10)
Budget from legacy outputs (25wh1, gbf98h):

| DOY | Snowfall (mm) | $\Delta (mm) | Evap/Subl (mm) | Runoff (mm) | Drainage (mm) | Soil $\Delta W$ (mm) | Deficit (mm) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **6** | 17.20 | +7.88 | 0.00 | 0.00 | 0.00 | +3.76 | **-5.56** |
| **7** | 5.40 | -8.26 | 0.00 | 0.00 | 0.00 | +3.62 | **-10.04** |
| **8** | 18.10 | +1.50 | 0.00 | 0.00 | 0.00 | +3.53 | **-13.07** |
| **9** | 23.50 | -9.63 | 0.00 | 0.00 | 0.00 | +3.95 | **-29.18** |
| **10** | 0.00 | -4.61 | 0.00 | 0.00 | 0.00 | +3.68 | **-0.93** |
| **Total** | **64.20** | **-13.12** | **0.00** | **0.00** | **0.00** | **+18.54** | **-58.78** |

*Findings*:
- Soil water increases by $+18.5	ext{ mm}$ (layers 1–10 recharge from melt infiltration).
- Evaporation/sublimation is **0.00 mm**; runoff is **0.00 mm**.
- The remaining mass is ablated directly at the snowpack–soil/litter boundary.

## 2. Legacy Code Path & Mechanics
Three mechanisms move snow water out of legacy's pack:
1. **Meltwater Drainage Percolation (watsub.f:1457-1458)**:
   FLWQX = max(0.0, VOLW02(L) - 0.05 * VOLS02(L)) * XNPSX
   Liquid melt exceeding 5% holding capacity drains downward at time step rate XNPSX (/	ext{NPS}$).
2. **Lowest Snow Layer Infiltration (watsub.f:1625-1633)**:
   FLWQGX = FLWQX * BARE(NY,NX)
   FLWQGS = min(VOLP1 * XNPSX, FLWQGX * FGRD)
   FLWQG  = FLWQGS + FLWQGH
   FLWQR  = FLWQX - FLWQG
   Meltwater reaching layer bottom is routed directly into soil micropores (FLWQGS), macropores (FLWQGH), and litter (FLWQR).
3. **Thin Snowpack Thermal Collapse (watsub.f:6655-6673)**:
   When snow layer heat capacity falls below threshold (VHCPW(1) <= VHCPWX where VHCPWX = 8.38e-4 * AREA) and ground air $> 0$ °C:
   `ortran
   FLWS = VOLS0(1,NY,NX)
   VOLS0(1,NY,NX) = VOLS0(1,NY,NX) - FLWS
   VOLI1(0,NY,NX) = VOLI1(0,NY,NX) + FLWS / DENSI
   `
   Residual solid snow collapses entirely into litter ice and liquid water!

## 3. Equivalent Code Path in ng & Decisive Physics Gap
- **ng Equivalent**:
  - Melt drainage: cosys-ng/src/soil/water/snow_melt_water_routing.zig:64-77.
  - Disappearance: cosys-ng/src/soil/water/snowpack_litter_heat_water_transfer.zig:228-245.
- **The Decisive Physics Gap**:
  In legacy watsub.f:1457, FLWQX drainage occurs on **every internal subcycle** (MM=1,NPS, NPS=20), so all meltwater continuously escapes to soil/litter. In ng (snow_melt_water_routing.zig:80), drainage rate is scaled down by step_fraction (/1	ext{ h}$), throttling percolation by 	imes$, trapping meltwater in the pack where it refreezes overnight into ice, accumulating an unnaturally deep, insulating pack.
