# DEEPSEEK task — Round 00057 CHALLENGE STAGE A (FC/WP-anchored MvG, commit 50d6036)  [read-only]

Change: `ecosys-ng/src/soil/water/solver_properties.zig` — a deck inflection head of 0 now uses the
Carsel-Parrish texture inflection as the third anchor of `fitOriginalMualemVanGenuchten` through deck θs/FC/WP
(was: unanchored Carsel-Parrish curve). CLAUDE's probe for Ottawa layer 1 (θs 0.517, FC 0.28, WP 0.15, Ks 20.4):
fitted θr 0.147, α 3.548 m-1, n 1.762.
  ψ (MPa):      -0.001  -0.005  -0.01  -0.033  -0.1   -0.5   -1.5
  θ legacy:      0.500   0.360  0.280  0.241  0.210  0.172  0.150
  θ fitted:      0.493   0.354  0.280  0.203  0.171  0.154  0.150
  K (mm/h) at θ: 0.25 / 0.28 / 0.30 / 0.35 / 0.40 / 0.45
    legacy HCND: 1.55e-3 / 1.41e-2 / 4.56e-2 / 0.280 / 1.21 / 4.28
    fitted MvG:  5.62e-3 / 2.14e-2 / 4.48e-2 / 0.206 / 0.724 / 2.26
(1) Attack: is the Carsel inflection a defensible third anchor, or would another (e.g. matching legacy θ at
    -0.033 MPa, or legacy PSISA/THETS air entry -0.0026 MPa / 0.429) give a closer legacy curve? Quantify.
(2) The dry-range shape gap (θ 0.20 vs 0.24 at -0.033 MPa) — does it matter for Ottawa (θ1 rarely < 0.25?)
    using the r00019 1998 outputs (`C:\ecosys-build\runs\r00019-strict\deck\runottawa_output_files\`)?
(3) Remaining DEV-003 items that still separate ng from legacy hydrology: Kirchhoff face averaging vs legacy
    harmonic AVCNDL, continuous K vs JK class steps, frozen impedance, macropores. Rank by expected effect on
    topsoil θ and runoff.
(4) Recommend DEV-003's registered wording/status.
≤450 words → `.agent/adversarial/round_00057_deepseek.md`. Reply `DONE <path>`.
