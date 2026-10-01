# Round 00054: Topsoil Wetness Root Cause (Retention & Conductivity Audit)

## 1. Legacy Formulation (`f77src/starts.f:526`, `hour1.f:2052-2283`)
- **Moisture Retention Curve**: Legacy builds a piecewise log-linear relation anchored to deck $\psi_s = -0.5	imes 10^{-3}	ext{ MPa}$, $\psi_{	ext{fc}} = -0.010	ext{ MPa}$, $\psi_{	ext{wp}} = -1.500	ext{ MPa}$:
  - For $	heta_{	ext{wp}} \le 	heta < 	heta_{	ext{fc}}$: $\ln(-\psi) = \ln(-\psi_{	ext{fc}}) + rac{\ln(	heta_{	ext{fc}}) - \ln(	heta)}{\ln(	heta_{	ext{fc}}) - \ln(	heta_{	ext{wp}})} (\ln(-\psi_{	ext{wp}}) - \ln(-\psi_{	ext{fc}}))$.
  - For $	heta_{	ext{fc}} \le 	heta < 	heta_s$: $\ln(-\psi) = \ln(-\psi_s) + \left[rac{\ln(	heta_s) - \ln(	heta)}{\ln(	heta_s) - \ln(	heta_{	ext{fc}})}ight]^{0.5} (\ln(-\psi_{	ext{fc}}) - \ln(-\psi_s))$.
- **Hydraulic Conductivity**: `hour1.f:2252-2283` integrates Campbell pore classes ($JK=500$):
  $K(	heta) = K_{	ext{sat}} (	heta/	heta_s)^{1.33} rac{\sum_{m=k}^{JK} (2m+1-2k)/\psi_m^2}{\sum_{m=1}^{JK} (2m-1)/\psi_m^2}$.

## 2. ecosys-ng Formulation (`ecosys-ng/src/soil/water/`)
In `solver_properties.zig:213-239`, when inflection head is 0 (deck line 4), ng classifies texture as `.clay_loam` and assigns generic **Carsel-Parrish defaults** (`retention.zig:425`):
$	heta_r = 0.095$, $	heta_s = 0.517$, $lpha = 1.9	ext{ m}^{-1}$, $n = 1.31$, $K_{	ext{sat}} = 20.4	ext{ mm/h}$.
**Divergence**: ng **ignores** the deck's explicit $	heta_{	ext{fc}} = 0.28$ and $	heta_{	ext{wp}} = 0.15$, substituting the unanchored Carsel-Parrish generic retention curve.

## 3. Quantitative Comparison for Layer 1

| Metric / Variable | Legacy (`f77src`) | `ecosys-ng` (r00019) | Ratio / Difference |
| :--- | :---: | :---: | :---: |
| $	heta$ at $\psi = -0.010	ext{ MPa}$ (FC) | **0.280** | **0.411** | **+0.131 (+47%)** |
| $	heta$ at $\psi = -0.033	ext{ MPa}$ | 0.241 | 0.328 | +0.086 (+36%) |
| $	heta$ at $\psi = -0.100	ext{ MPa}$ | 0.210 | 0.262 | +0.052 (+25%) |
| $	heta$ at $\psi = -1.500	ext{ MPa}$ (WP) | 0.150 | 0.168 | +0.018 (+12%) |
| $K$ at $	heta = 0.30$ (mm/h) | 0.0299 | 0.0019 | **Legacy $16.2	imes$ higher** |
| $K$ at $	heta = 0.35$ (mm/h) | 0.2411 | 0.0138 | **Legacy $17.4	imes$ higher** |
| $K$ at $	heta = 0.40$ (mm/h) | 1.0096 | 0.0776 | **Legacy $13.0	imes$ higher** |
| $K$ at $	heta = 0.45$ (mm/h) | 3.4263 | 0.3882 | **Legacy $8.8	imes$ higher** |

## 4. Surface Detention & Infiltration
- Legacy (`watsub.f:3739`): `FLQR = max(0, VOLW1(0) - 0.01/AREA) * XNPXX`.
- ng (`surface/water_flow.zig:136`): `@max(0, pond - 0.01*area) * time_fraction`.
Structure and 0.01 m threshold are identical; detention does not drive the gap.

## 5. Verdict: The Single Root Cause
The 0.16 m$^3$/m$^3$ topsoil wetness gap is caused by **ng's unanchored Carsel-Parrish retention curve**:
1. At field capacity, gravity drainage in ng stops at $	heta = \mathbf{0.411}$, whereas legacy drains to $	heta = \mathbf{0.280}$ (+0.131 m$^3$/m$^3$ offset!).
2. In the drying range ($	heta = 0.30	ext{--}0.45$), legacy's $K(	heta)$ is **$9	imes	ext{ to }17	imes$ higher**, clearing water rapidly downward. ng chokes drainage, trapping water in the topsoil.
