# Round 00038 Comparability Audit: Soil Aeration & Winter Respiration

## 1. Monthly Soil Moisture, Porosity & Dissolved O2
- **Alignment**:
  - Legacy `f25wh1`: cols 13–24 are liquid water fractions $\theta_w$ (layers 1–12); cols 25–36 are ice fractions $\theta_i$. Porosity $\phi \approx 0.519$ (L1–6), $0.511$ (L7–10).
  - Legacy `f25ch1`: choices 36–43 write $\text{COXYS}(2\dots 9)$ to cols 16–23 ($O_2$ in layers 2–9; choice 35 for layer 1 is in col 15).
- **Monthly Means (1998)**:
  - **Moisture ($\theta_w$, $\text{m}^3\text{ m}^{-3}$)**:

| Mo | Leg L1 | ng L1 | Leg L2 | ng L2 | Leg L7 | ng L7 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Jan** | 0.244 | 0.281 | 0.245 | 0.280 | 0.332 | 0.329 |
| **Apr** | 0.307 | 0.436 | 0.305 | 0.426 | 0.348 | 0.439 |
| **Jul** | 0.312 | 0.547 | 0.311 | 0.507 | 0.347 | 0.480 |
| **Sep** | 0.306 | 0.558 | 0.306 | 0.506 | 0.346 | 0.476 |

  - **Dissolved $O_2$ ($g\text{ O}_2\text{ m}^{-3}$)**:

| Mo | Leg L2 | ng L2 | Leg L4 | ng L4 | Leg L7 | ng L7 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Jan** | 22.1 | 29.2 | 24.4 | 32.0 | 26.4 | 21.4 |
| **Apr** | 22.7 | 3.7 | 28.7 | 8.8 | 20.4 | 20.2 |
| **Jul** | 0.00 | 0.13 | 0.12 | 0.02 | 0.00 | 0.00 |

- **Divergence**: In summer, ng topsoil is **waterlogged** ($\theta_w \approx 0.55 > \phi = 0.519$), cutting off atmospheric $O_2$. Largest gap: **Layer 1 in Jul–Sep** (+75% water vs legacy).

## 2. Surface Soil–Atmosphere Gas Conductance
- Legacy `trnsfr.f:3549`: $\text{DFLG2} = \theta_a \cdot \text{POROQ} \cdot \frac{\theta_a}{\phi} \cdot \frac{\text{AREA}}{\text{DLYR}}$, scaled by gas step $XNPGX$.
- Legacy `watsub.f:4356`: $\text{PARG} = \frac{\text{AREA} \cdot XNPHX}{\text{RATG} + \text{RAGS} + \text{RAS}}$.
- ng `transport_step.zig:660` + `atmosphere_exchange.zig:113`: combines internal diffusion geometry with boundary resistance in harmonic series, scaled by `transport_iteration_fraction`.
- Formulations and units match legacy; no conductance scaling defect.

## 3. Cause of Winter 30× CO2 Emission
- **Soil Concentrations**: In Jan, dissolved $\text{CO}_2$ in layers 1–4 matches legacy closely (Layer 1: Legacy $10.56$ vs ng $12.26\text{ g C m}^{-3}$, ratio 1.16).
- **Root Cause**: ng accumulates $3.2\times$ more snow insulation (Jan SWE $83.5$ vs $25.8\text{ mm}$ in legacy). Consequently, **ng topsoil never freezes** (Layer 1 mean $T = +0.34^\circ\text{C}$, ice $= 0.018$) whereas **legacy soil freezes solid** (Layer 1 mean $T = -1.11^\circ\text{C}$, ice $= 0.209$).
- Subzero temperatures throttle respiration and ice seals pores in legacy; in ng, unfrozen soil maintains high sub-snow respiration, driving 30× higher fluxes.
