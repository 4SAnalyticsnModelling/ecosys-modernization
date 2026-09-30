# Round 00036 Output Comparability Audit: 1998 Gas Fluxes

## 1. Monthly Means & Ratios (1998 d1–d280)
Values in $\mu\text{mol m}^{-2}\text{ s}^{-1}$ (ratio = ng / legacy):

| Mo | Leg $\text{CO}_2$ | ng $\text{CO}_2$ | R $\text{CO}_2$ | Leg $\text{CH}_4$ | ng $\text{CH}_4$ | R $\text{CH}_4$ | Leg $\text{O}_2$ | ng $\text{O}_2$ | R $\text{O}_2$ |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Jan** | -0.015 | -0.467 | **31.1** | -0.0004 | 0.0000 | **0.0** | +0.377 | -0.064 | **-0.2** |
| **Feb** | -0.009 | -0.311 | **36.8** | -0.0005 | 0.0000 | **0.0** | +0.026 | +0.346 | **13.4** |
| **Mar** | -0.042 | -0.166 | **4.0** | -0.0034 | -0.0003 | **0.1** | +0.243 | +0.171 | **0.7** |
| **Apr** | -0.194 | -1.055 | **5.5** | -0.0236 | -0.2311 | **9.8** | +1.926 | +0.193 | **0.1** |
| **May** | -0.271 | -1.505 | **5.6** | -0.0320 | -0.9131 | **28.6** | +2.161 | +0.607 | **0.3** |
| **Jun** | -0.551 | -1.042 | **1.9** | -0.0643 | -0.6799 | **10.6** | +2.418 | +0.417 | **0.2** |
| **Jul** | -0.587 | -0.882 | **1.5** | -0.1770 | -0.8180 | **4.6** | +3.067 | +0.114 | **0.0** |
| **Aug** | -0.716 | -0.679 | **0.9** | -0.2267 | -0.6081 | **2.7** | +3.452 | +0.108 | **0.0** |
| **Sep** | -0.708 | -0.302 | **0.4** | -0.1728 | -0.3932 | **2.3** | +3.129 | +0.089 | **0.0** |
| **Oct** | -0.610 | -0.068 | **0.1** | -0.1243 | -0.2844 | **2.3** | +2.673 | +0.064 | **0.0** |

- **Earliest divergence**: **Day 1 Hour 1** (d01 h01: leg $\text{CO}_2 = +3.0\times 10^{-4}$ vs ng $-3.9\times 10^{-2}$; leg $\text{O}_2 = +0.21$ vs ng $+2.16$).

## 2. Column Semantics & Signs
- **Legacy Output (`outsh.f:54-57`)**:
  - `HEAD(1)` $\text{CO}_2$: `HCO2G * 23.14815 / AREA` ($\mu\text{mol C m}^{-2}\text{ s}^{-1}$).
  - `HEAD(2)` NEE: `TCNET * 23.14815 / AREA`.
  - `HEAD(3)` $\text{CH}_4$: `HCH4G * 23.14815 / AREA`.
  - `HEAD(4)` $\text{O}_2$: `HOXYG * 8.68056 / AREA` ($\mu\text{mol O}_2\text{ m}^{-2}\text{ s}^{-1}$).
- **Signs**: In legacy (`redist.f:4475-4502`) & ng (`ecosys_ng.zig:817-820`), **positive is influx; negative is emission**. Definitions match.

## 3. Top 3 Divergence Process Owners
1. **Microbial Respiration & $\text{O}_2$ Consumption**:
   - `nitro.f:4018` (`RUPOXO`) vs `nitrogen_state_update.zig:142-315`. Winter ng respiration is unsuppressed by freezing/snow (30× $\text{CO}_2$ over-emission in Jan/Feb).
2. **Methanotrophy / Methanogenesis**:
   - `nitro.f:4489` (`RC4OX`), `trnsfr.f:1614` vs `nitrogen_state_update.zig:303-315`. Winter $\text{CH}_4$ oxidation is missing in ng; summer methanogenesis is over-active.
3. **Boundary Aerodynamic & Snow/Ice Gas Conductance**:
   - `trnsfr.f:1580-1619` (`DFGS*`) vs `atmosphere_exchange.zig:88-124`. Snow/ice tortuosity differences alter diffusion across frozen boundaries.
