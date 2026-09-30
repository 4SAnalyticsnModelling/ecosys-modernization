# Round 00043: Snowpack Surface Radiation & Energy Balance Decomposition

## 1. Surface Radiation & Energy Balance (1998 DOY 6, Hours 10–14)

Comparison (matched solar hours, in $	ext{W/m}^2$, LE = 0):

| Hour | SW | Alb | SW Abs | LW In | LW Out | $ | $ | {	ext{sfc}}$ |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **10** | 52.4 | 0.88 / 0.90 | +6.3 / 0.0 | 238.8 / 0.0 | -236.4 / -4.6 | **+8.7 / -4.6** | -18.9 / +6.2 | -0.01 / -0.28 |
| **11** | 61.4 | 0.88 / 0.90 | +7.7 / 0.0 | 239.4 / 0.0 | -231.3 / -7.8 | **+15.8 / -7.8** | -15.5 / +5.8 | +0.05 / -0.27 |
| **12** | 58.6 | 0.87 / 0.90 | +7.6 / 0.0 | 238.8 / 0.0 | -234.0 / -11.0 | **+12.4 / -11.0** | -9.0 / +5.9 | +0.07 / -0.27 |
| **13** | 40.1 | 0.87 / 0.90 | +5.2 / 0.0 | 238.8 / 0.0 | -246.8 / -14.5 | **-2.8 / -14.5** | -0.8 / +7.0 | +0.05 / -0.26 |
| **14** | 66.5 | 0.86 / 0.90 | +9.0 / 0.0 | 239.4 / 0.0 | -229.3 / -10.0 | **+19.0 / -10.0** | -5.2 / +5.7 | +0.06 / -0.25 |

*Format*: Legacy / ng. In legacy, positive $ warms snow to $ °C, producing melt. Legacy  < 0$ (heat absorbed by snow); ng  > 0$ and  < 0$.

## 2. Root Cause of Negative Daytime Net Radiation in ng

**Defect**: cosys-ng/src/surface/temperature_solver.zig:801-804, 887-889
1. **Suppression of Solar & Sky Radiation by snow_free_fraction**:
   In 	emperature_solver.zig:887-889, incoming solar and sky longwave are multiplied by snow_free_fraction ( - F_{	ext{snw}}$). Under snow ({	ext{snw}} pprox 1.0$), snow_free_fraction $pprox 0$, forcing absorbed SW and incoming LW to **zero**.
2. **Spurious Radiative Cooling**:
   Zeroing incoming radiation while subtracting emitted longwave ($-\epsilon\sigma T^4$) forces net radiation negative ( = -	ext{LW}_{	ext{emit}} < 0$), causing daytime cooling ($-5$ to $-15	ext{ W/m}^2$).
3. **Decoupled Snow Radiation**:
   Snow radiation (snow_surface_atmosphere_exchange.zig:748) is never published to context.surface_energy, leaving 25eh1 with only suppressed litter cooling.

## 3. Legacy-Faithful Formula

In legacy watsub.f:1241-1243, 4183:
`ortran
RFLX0  = (1.0 - ALBW) * RADXW(NY,NX) + THRYW(NY,NX)
THRMXW = EMMGW(NY,NX) * TK02(1)**4
RFLXW2 = RFLX0 - THRMXW + THRMCW + THRMDW
HEATI  = HEATI + RFLXG + RFLXR + RFLXW
`
Ground net radiation must sum snow ({	ext{flxw}}$), litter ({	ext{flxr}}$), and bare soil ({	ext{flxg}}$). Under snow, absorbed shortwave warms the pack to $ °C and drives snowmelt.
