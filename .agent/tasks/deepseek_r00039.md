# DEEPSEEK task — Round 00039 CONSERVATION TRACE (from CLAUDE)  [read-only; you may stop r38 if not done — do r39 first]

Hour 6852 (1998 d286 h12) JCUT termination of the unemerged maize (plant 0). After fixes (uncommitted):
harvest root litter now booked in the plant ledger (new `root_harvest_litter_*_by_plant`), DEV-016 keeps the hour's
root `actual_respiration_g_c_per_h` unscaled. Plant ledger now closes. NEW failure: soil LAYER scope 2 (soil layer
index 2, where the roots are) in `validation/layer_local_conservation.zig` hourly gate:
- carbon before 886.44389027 after 886.43485328; inputs 1.12732e-2 outputs 2.02424e-2 → residual −6.7728e-5 g
- nitrogen residual −1.3406e-7 g; hydrogen residual −2.6859e-8 g; phosphorus and oxygen close.
- storage components (C): residue −8.6208e-3, organic −2.5618e-4, soil_gas −2.0974e-4, other_inorganic +9.567e-5,
  plant(root tissue) 4.5941e-5 → 0.
Measured in the harvest (`management/plant_harvest_runtime_apply.zig` applyRootSymbiontHarvest, layer 2):
root litter C 4.5939e-5 published to soil (P closes, so tissue litter is internal and fine); root gas released
(CO2+CH4) 2.0300e-4 g C, booked on the layer ledger as withdrawal (CO2 −1.9210e-4, CH4 −1.0899e-5, N2O-N −3.347e-7,
NH3-N −5.68e-9, H2 −5.85e-8) via `accumulateRootGasActivity` (ecosys_ng.zig ~5538) — booking == release.
The layer inventory counts root gas (landscape_mass_inventory_gas.zig:332-407, incl. pending actual_respiration).

Find the unbooked −6.77e-5 g C (−1.34e-7 N, −2.7e-8 H; C:N ≈ 505) in layer 2. Suspects: (a) producers gated on
`active_by_plant`/`uptake_phenology.active` in `uptake_coupled_transaction` / root_gas_content / root_soil_gas /
root_atmosphere state updates (ecosys_ng.zig 4413-4500, 5500-5560) that SKIP booking this hour's pre-harvest
root↔soil or root↔atmosphere exchange because the plant is inactive by then; (b) root gas content refresh
(`root_gas_content_state_update`) overwriting root gas with a stale/zero value; (c) root O2/CO2 soil exchange whose
root side is zeroed. Give file:line and the exact term + magnitude you expect. ≤400 words →
`.agent/adversarial/round_00039_deepseek.md`. Reply `DONE <path>`.
