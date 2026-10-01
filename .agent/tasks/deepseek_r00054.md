# DEEPSEEK task — Round 00054 TOPSOIL WETNESS ROOT CAUSE: retention + conductivity, legacy vs ng  [read-only]

r53: ng topsoil θ1 0.47 vs legacy 0.31 (+50%), runoff +57%, and N2O/Reco gaps follow from it. r53's pointers
(grosub.f for microbes, water_flow.zig:62) are not evidence; this round must be quantitative.
For the Ottawa deck soil (layers 1-3; read the soil file in `ecosys-ng-prod-examples/` or the run deck
`C:\ecosys-build\runs\r00019-strict\deck\runottawa_input_files\landscape\`):
(1) Legacy: quote how hour1.f/starts.f build the water-retention relation (PSISM vs THETW: the log-linear
    FC/WP form, SRP/PSL/FCL/WPL, PSISE/PSISA, THETS) and the hydraulic conductivity (HCND, CNDH, FC/WP
    breakpoints, macropore). Give file:line.
(2) ng: the retention and conductivity actually used (`ecosys-ng/src/soil/water/` — mualem_van_genuchten
    parameters, retention_curve, solver_hydraulics). Give file:line and how its parameters are fitted from the
    same deck FC/WP/θs/Ks.
(3) Table for layer 1: θ at ψ = -0.01, -0.033, -0.1, -1.5 MPa and K(θ) at θ = 0.30, 0.35, 0.40, 0.45, legacy vs ng.
(4) Surface infiltration/runoff: legacy watsub.f infiltration capacity (FLQR/FLQM, VOLW1(0) detention, 0.01/AREA)
    vs ng. Is ng's surface detention or infiltration limit structurally different?
Verdict: which single difference most plausibly makes ng 0.16 m3/m3 wetter? ≤500 words →
`.agent/adversarial/round_00054_deepseek.md`. Reply `DONE <path>`.
