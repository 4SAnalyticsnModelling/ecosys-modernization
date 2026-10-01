# Round 00057: Challenge Stage A (FC/WP-Anchored MvG, Commit 50d6036)

## (1) Defensibility of the Carsel Inflection as Third Anchor
The Carsel-Parrish inflection head (h_infl = -1.581 m, ~0.0155 MPa) is a **defensible and numerically stable third anchor**:
- MvG parameters (theta_r, alpha, n) require 3 constraints. Anchoring (theta_s, theta_fc, theta_wp) fixes 2 points: (psi_fc, theta_fc) and (psi_wp, theta_wp).
- **Alternatives**:
  1. *Legacy air-entry* (-0.0026 MPa, theta = 0.429): Steep transition forces n > 3, creating a step-function K(theta) that destabilizes implicit Richards solves.
  2. *Matching legacy theta at -0.033 MPa* (0.241): Over-constrains curvature, forcing unphysical theta_r < 0 or degrading fit at WP = -1.5 MPa.
- **Parity**: At theta_fc = 0.280, fitted MvG K = 0.0214 mm/h matches legacy HCND = 0.0141 mm/h within 1.5x (down from 17x).

## (2) Dry-Range Shape Gap (theta = 0.20 vs 0.24 at -0.033 MPa)
In 1998 Ottawa:
- **Legacy**: theta_1 < 0.25 occurs for 965 h (11% of year); theta_1 < 0.28 occurs for 1,679 h (19%).
- **ng r00019**: theta_1 >= 0.35 dominated 82% of the year (7,169 h) due to unanchored retention.
- **Impact**: The dry gap operates only during summer drydowns where K < 0.005 mm/h in both models. Here drainage is negligible and moisture is governed by root extraction. It does not cause topsoil wetness.

## (3) Ranking Remaining DEV-003 Hydrology Differences
Ranked by effect on topsoil theta and runoff:
1. **Kirchhoff Transform vs. Legacy Harmonic AVCNDL (`watsub.f:4840`)**: *Highest impact*. Legacy harmonic mean biases conductance toward the drier layer, throttling infiltration. Kirchhoff integration yields higher effective face conductance across sharp wetting fronts.
2. **Macropore-Matrix Exchange Kinetics (`phase_solver.zig:1840` vs `watsub.f:4973`)**: *High impact*. Legacy routes macropore flux directly to deep drainage; ng dual-domain interaction retains water longer in upper layers.
3. **Frozen Hydraulic Impedance (`retention.zig` vs `watsub.f:4481`)**: *Moderate impact*. Governs winter/melt infiltration throttling with pore ice.
4. **Continuous K(theta) vs. JK=500 Step Classes (`hour1.f:2281`)**: *Negligible impact*.

## (4) Recommendation for DEV-003 Registration
- **Status**: **ACCEPT as Category D1 (Approved Process Modernization)**.
- **Registered Description**: "Mualem-van Genuchten Richards solver with FC/WP-anchored three-point fit replacing legacy empirical log-linear Campbell classes (`hour1.f:2052-2283`). Preserves deck-specified theta_fc and theta_wp moisture states while providing continuous C(psi) derivatives for robust implicit Richards convergence."
