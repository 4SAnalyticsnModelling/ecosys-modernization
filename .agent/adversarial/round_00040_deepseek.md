# Round 00040 Water Balance Decomposition & Root Cause Audit

## 1. Monthly Water Balance Decomposition (1998, mm)
Precip $708.3\text{ mm}$ (Jan–Oct). Jan snow $132.3\text{ mm}$, rain $2.7\text{ mm}$.

| Mo | Precip | Leg RO | ng RO | Leg Drn | ng Drn | Leg SWE | ng SWE | Leg L1 $\theta_w$ | ng L1 $\theta_w$ |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Jan** | 135.0 | 83.4 | 0.0 | 1.6 | 0.3 | 40.4 | 128.0 | 0.244 | 0.281 |
| **Feb** | 19.6 | 66.9 | 0.0 | 1.2 | 0.3 | 5.5 | 115.7 | 0.245 | 0.280 |
| **Mar** | 85.4 | 100.8 | 81.8 | 17.4 | 0.6 | 5.5 | 111.7 | 0.288 | 0.422 |
| **Apr** | 55.3 | 24.0 | 154.8 | 33.6 | 3.0 | 5.5 | 4.5 | 0.307 | 0.436 |
| **May** | 33.4 | 11.7 | 51.7 | 41.4 | 2.2 | 0.0 | 0.0 | 0.295 | 0.433 |
| **Jun** | 119.5 | 52.9 | 140.0 | 56.5 | 1.6 | 0.0 | 0.0 | 0.314 | 0.475 |
| **Jul** | 84.4 | 37.3 | 166.0 | 66.7 | 1.3 | 0.0 | 0.0 | 0.312 | 0.547 |
| **Aug** | 50.5 | 17.6 | 132.7 | 48.2 | 0.8 | 0.0 | 0.0 | 0.305 | 0.554 |
| **Sep** | 71.7 | 33.0 | 149.3 | 49.9 | 5.9 | 0.0 | 0.0 | 0.306 | 0.558 |
| **Oct** | 71.3 | 25.2 | 122.4 | 67.5 | 28.7 | 0.0 | 0.0 | 0.317 | 0.558 |

Drainage: Legacy $384.0\text{ mm}$ vs ng $44.7\text{ mm}$ (**$8.6\times$ deficit**).

## 2. Root Causes of Divergence

### A. Winter Snowpack Thaw Runoff (Jan–Feb)
- **Defect**: During Jan 12–15 thaw, legacy generates $83.4\text{ mm}$ runoff from snow meltwater overflow (`watsub.f:1457, 1632, 3852`), reducing SWE from $68.3$ to $9.3\text{ mm}$.
- In ng, `snow_melt_water_routing.calculate` (`snow_melt_water_routing.zig:53, 65`) scales release by `step_fraction`, choking melt delivery to litter. ng retains $128.0\text{ mm}$ SWE until April, causing delayed spring flush ($154.8\text{ mm}$ in Apr) and insulative soil warming.

### B. Soil Drainage Gating Defect (Spring–Summer)
- **Deck Setup**: Ottawa site `f25si98` specifies `IDTBLG = 3` (tile drain at $1.5\text{ m}$), lower boundary `RCHGD = 0.0`, and tile drain exchange fraction `RCHGFB = 1.0`.
- **Legacy (`watsub.f:5352-5368, 5934-5956`)**:
  Tile drainage activates if $\text{PSISA1}(L) > \text{PSISA}(L)$ (layer potential exceeds air-entry potential $\text{PSISA}$, draining gravity water above field capacity). Legacy drains $40\text{--}70\text{ mm/month}$.
- **ng Defect (`soil/water/solver_residual.zig:480, 506-518`)**:
  Line 480 gates discharge on `base_matric_megapascal > grid.matric_potential_megapascal[layer]`, requiring soil to become wetter during current hour instead of comparing against air-entry potential $\text{PSISA}$. Lines 509–518 also abort discharge if deeper layer has lower potential.
- This strangles tile drainage ($0.8\text{--}2.2\text{ mm/month}$), trapping water until it backs up into Layer 1 ($\theta_w = 0.558$), causing topsoil waterlogging and excessive runoff.
