# DEEPSEEK task — Round 00037 COMPARABILITY ROOT CAUSE (from CLAUDE)  [read-only]

r00036 ACCEPTED: 1998 ng/legacy gas-flux divergence (CO2 x30 winter, CH4 x10-28 spring/summer, O2 uptake x0.03-0.3)
begins at d1 h1. Per-layer dissolved gas at d1 (legacy `010101998f25ch1` CSV vs ng `...pop00_f25ch1.txt`, cols 12+):
- h1 CO2 (g C m-3 water) layers 1-4: legacy 1.65 1.17 1.02 0.75 | ng 0.60 1.83 1.96 1.93
- h24 CO2: legacy 4.0 6.6 5.1 3.6 | ng 8.8 8.8 8.5 7.9 ; h24 O2 layer 1: legacy 38.1 | ng 16.0
NOTE the headers differ: legacy labels its O2 columns "layer_5..layer_12" then litter O2; ng labels O2 layers 1-9.
Check legacy `outsh.f` (f25ch1 writer) which layers those O2 columns really are, so we compare like with like.

Task: find why the soil gas state differs already at hour 1.
(1) Legacy initialization of soil gas: starts.f / (wherever CCO2S, CO2S, OXYS, CH4S, CCH4S, COXYS, gas-phase CO2G/OXYG
are initialized) — formula (e.g. from atmospheric CO2 × solubility SCO2 × temperature, or read from the soil file).
Cite lines. (2) ng initialization of the same state (search `src/soil/gas`, `src/state`, init/startup code) —
cite lines and state whether it matches legacy exactly (inputs, solubility temperature, which water volume).
(3) Legacy hour-1 order: is the output at h1 written after one hour of TRNSFR/NITRO, and does ng write the same
post-hour state? (4) Name the single most likely cause of the h1 layer-1 CO2 0.60 vs 1.65 difference.
≤450 words → `.agent/adversarial/round_00037_deepseek.md`. Reply `DONE <path>`.
