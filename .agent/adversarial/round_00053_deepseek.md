# Round 00053: 1998 Comparability Audit (ecosys-ng r00019 vs Legacy)

## 1. Compact Comparison Table (1998 DOY 1–350)

| Variable | Legacy (`f77src`) | `ecosys-ng` (r00019) | Relative Gap / Notes |
| :--- | :---: | :---: | :---: |
| **Cumulative ET** (mm) | 0.00 | 199.23 | Unreported in legacy `f25wh1` (internal `TEVAPG` unselected) |
| **Surface Runoff** (mm) | 478.14 | 752.55 | +57.4% (higher ng winter/melt runoff) |
| **Subsurface Drainage** (mm) | 459.17 | 449.56 | -2.1% (closely matched) |
| **Monthly Mean $	heta_1$** (m$^3$ m$^{-3}$) | 0.24–0.31 | 0.28–0.48 | +20% to +50% wetter in ng |
| **Monthly Mean $T_{	ext{soil}}$ L1** (°C) | -1.1 to 29.0 | 0.4 to 31.9 | ng warmer in winter, cooler in autumn |
| **Monthly Mean $T_{	ext{soil}}$ L3** (°C) | -0.1 to 31.8 | 0.7 to 30.9 | ng buffered; legacy subzero in early Jan |
| **Cumulative NEE** (g C m$^{-2}$) | -144.51 | -232.32 | +60.8% net carbon loss in ng |
| **Cumulative GPP** (g C m$^{-2}$) | 0.00 | 0.00 | 0.0% (unplanted fallow deck) |
| **Cumulative $R_{	ext{eco}}$** (g C m$^{-2}$) | -144.51 | -232.32 | Higher microbial respiration in ng |
| **Cumulative N$_2$O** (g N m$^{-2}$) | -0.0854 | -1.3501 | 15.8x larger emission in ng |
| **DIN Leaching at d350** (g N m$^{-2}$) | 0.0045 | 0.0003 | Both negligible (< 0.01 g N m$^{-2}$) |
| **Mineral N at d350** (g N m$^{-2}$) | ~58.0 (init) | 122.00 | Higher net mineralization in ng |
| **SWE Jan–Mar** (mean / max mm) | 20.8 / 56.2 | 124.1 / 176.2 | Legacy ablates winter snow via DEV-020 |
| **Snow Days Jan–Mar / Nov–Dec** | 90 / 46 | 90 / 11 | ng snow melts faster in Nov–Dec |

## 2. Top 3 Non-DEV-020 Relative Gaps & Root Cause Attribution

### Rank 1: N$_2$O Emission (-0.085 vs -1.35 g N m$^{-2}$, ~16x gap)
- **Likely Cause**: Legacy `f77src/nitro.f:1154-1165` and `f77src/redist.f:4581-4587` strongly limit N$_2$O gas diffusion and bubble release under near-saturated conditions. In `ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig:88-120` and `chemodenitrification_step.zig`, denitrification is sustained because ng topsoil maintains higher moisture ($	heta_1 pprox 0.45$ vs $0.31$), creating persistent anaerobic microsites.
- **Pointers**: `f77src/nitro.f:1154`, `ecosys-ng/src/soil/microbial/nitrification_step.zig:87`.

### Rank 2: Soil Heterotrophic Respiration / NEE (-144.5 vs -232.3 g C m$^{-2}$, +61% gap)
- **Likely Cause**: Legacy `f77src/hour1.f:2910` and `f77src/redist.f:4478` attenuate microbial decomposition when soil moisture exceeds field capacity ($FC pprox 0.28$). In `ecosys-ng`, warmer summer soil temperatures ($+2$ to $+3$ °C in May–July) accelerate decomposition.
- **Pointers**: `f77src/grosub.f:1848`, `ecosys-ng/src/stages/biogeochemistry_batches.zig:376`.

### Rank 3: Topsoil Moisture Retention ($	heta_1 pprox 0.47$ vs $0.31$, +50% gap)
- **Likely Cause**: Legacy `f77src/watsub.f:3739` rapidly drains ponded water via `FLQR = max(0, VOLW1(0) - 0.01/AREA) * XNPXX`. In `ecosys-ng/src/surface/water_flow.zig`, detention storage and slower pond drainage keep topsoil near porosity ($0.517$) for prolonged intervals.
- **Pointers**: `f77src/watsub.f:3739`, `ecosys-ng/src/surface/water_flow.zig:62`.
