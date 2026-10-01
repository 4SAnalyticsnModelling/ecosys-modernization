# Round 00055: Exact Legacy Hydraulics Specification for ecosys-ng

Implementable specification quoted from `f77src/` (`starts.f`, `hour1.f`, `watsub.f`).

## 1. Water Retention Relation psi(theta)
- **Constants** (`starts.f:78, 526-530`, `hour1.f:2052-2061`):
  - PSIPS = -0.5e-3 MPa, PSIHY = -1.5e4 MPa, PSISX = -1.5e12 MPa.
  - psi_fc = PSIFC(L), psi_wp = PSIWP(L) (deck line 1: -0.010, -1.500 MPa).
  - PSIMS = ln(-PSIPS), PSIMX = ln(-PSIFC), PSIMN = ln(-PSIWP).
  - PSISD = PSIMX - PSIMS, PSIMD = PSIMN - PSIMX.
  - PSL = ln(POROS), FCL = ln(FC), WPL = ln(WP).
  - PSD = PSL - FCL, FCD = FCL - WPL.
  - Exponents: SRP = 0.50 (`hour1.f:2052`), HCN = 0.50 (`hour1.f:2054`).
- **Moisture State Formation**:
  In `watsub.f:4481-4486`, theta = max(THETZ, min(POROS, V_w / V_y)), V_y = VOLX = VOLT * FMPR. If V_w > THETS * V_y, V_w = VOLW1; else mobile V_w = VOLWX1 (`watsub.f:207`). Ice excludes pore space (VOLP1Z = VOLA1 - VOLW1 - VOLI1, `watsub.f:212`).
- **Piecewise Branches psi(theta)** (`hour1.f:2256-2270`, `watsub.f:4514-4528`):
  1. theta >= theta_s - 1e-6: psi = PSISE = PSIPS = -0.5e-3 MPa.
  2. FC <= theta < theta_s - 1e-6:
     psi = -exp(PSIMS + ((max(0.0, PSL - ln(theta))) / PSD)^SRP * PSISD).
  3. WP <= theta < FC:
     psi = -exp(PSIMX + ((FCL - ln(theta)) / FCD) * PSIMD).
  4. theta < WP:
     psi = max(PSISX, -exp(PSIMN + HCN * ((WPL - ln(theta)) / FCD) * PSIMD)).

## 2. Hydraulic Conductivity K(theta) & Lookup Architecture
- **Class Table Construction** (`hour1.f:2252-2283`):
  - JK = 500 classes. Spacing (`hour1.f:2254-2255`):
    X_k = max(0.0, k - 0.01 * JK), theta_k = theta_s - (X_k / JK) * theta_s.
  - Evaluate psi_k = psi(theta_k). Compute SUM2 = sum_{k=1}^{JK} (2k - 1) / (psi_k^2).
  - Per class k, tortuosity Y_k = ((JK - X_k) / JK)^1.33.
    SUM1_k = sum_{m=k}^{JK} (2*X_m + 1 - 2*X_k) / (psi_m^2).
  - Vertical: HCND(3, k, L) = SCNV(L) * Y_k * SUM1_k / SUM2.
  - Lateral: HCND(1..2, k, L) = SCNH(L) * Y_k * SUM1_k / SUM2.
  - Air-entry threshold: when HCND < 0.1 * SCNV (`hour1.f:2285-2288`), PSISA = psi_{k-1}, THETS = theta_{k-1}.
- **Runtime Lookup** (`watsub.f:4789-4811`):
  - Step index: K1 = max(1, min(JK, int(JK * (theta_s - theta) / theta_s) + 1)). No interpolation.
  - Effective K = HCND(N, K1, L) * FKSAT.
- **Face Averaging** (`watsub.f:4840-4841`):
  - Strictly harmonic mean across adjacent layer centers:
    AVCNDL = 2.0 * K1 * KL / (K1 * dz_L + KL * dz_1).
  - Flux: q = AVCNDL * (psi_t,1 - psi_t,L) * Area * dt (`watsub.f:4862`).
- **Macropore Conductivity** (`hour1.f:2318-2328`): Poiseuille flow CNDH = 3600 * pi * N_hol * r^4 / (8 * mu).

## 3. Inverse theta(psi) and Derivatives
- **Inverse theta(psi)**: Used only at scene start (`starts.f:1154-1162`) or boundary setup (`hour1.f:2175-2200`). Never evaluated during subhourly flux routing.
- **d(theta)/d(psi)**: Never computed or used.

## 4. Ottawa Deck Layer-1 Reference Values
- Deck inputs: theta_s = 0.5170, FC = 0.2800, WP = 0.1500, Ksat = 20.40 mm/h.
- Air-entry output: THETS = 0.4291, PSISA = -0.002607 MPa.
- Five sample class points:
  1. k = 1 (theta = 0.5170, psi = -0.50e-3 MPa): K = 18.15 mm/h.
  2. k = 50 (theta = 0.4705, psi = -1.62e-3 MPa): K = 5.59 mm/h.
  3. k = 150 (theta = 0.3671, psi = -4.69e-3 MPa): K = 0.404 mm/h.
  4. k = 250 (theta = 0.2637, psi = -1.62e-2 MPa): K = 2.73e-3 mm/h.
  5. k = 350 (theta = 0.1603, psi = -0.882 MPa): K = 3.62e-7 mm/h.
