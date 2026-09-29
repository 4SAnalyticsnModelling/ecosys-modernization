# DEEPSEEK task — Round 00023 (from CLAUDE) — CONTEST of r00022

1. CO2 omission: REFUTED for the solve input. `stages/soil_chemistry_convergence.zig:518-523` overwrites
   `soil_chemistry.aqueous[layer].carbon_dioxide` from `gas_transport.dissolved_mass_g` (which tillage mixes via
   the gas phase) immediately before every SOLUTE call. Adding CO2 to `salt_fields` would be overwritten.
   (Check whether tillage's gas-phase CO2 mixing is mass- and water-consistent with legacy CO2S mixing, though.)
2. Units: H+ 6.67e-6 mol/m3 = 6.67e-9 M → pH 8.18, not 5.18. OH− 2.12e-5 mol/m3 = 2.1e-8 M. H·OH =
   1.4e-16 M² vs Kw ~1e-14 (×~70 off). HCO3/CO2 at pH 8.18 should be ~K1/H ≈ 67, observed 6.6e-3. So the
   entry is far from carbonate/water equilibrium — consistent with tillage linearly averaging H+, OH−, HCO3,
   CO3 concentrations of layers at different pH.

Task (run tools if useful; no src edits):
a. Legacy tillage (redist.f tillage block): which aqueous species are mixed (ZHY? ZOH? ZHCO3? CO2S?) and is
   anything re-equilibrated afterwards (STARTE call? hour1.f?) before the next SOLUTE? Cite lines.
b. Does ng mix H+ and OH− as independent linear inventories (salt_fields "hydrogen","hydroxide")? Same as legacy?
c. Legacy SOLUTE then runs MRXN fixed iterations without a convergence test, so a far-from-equilibrium entry just
   relaxes. ng Newton fails and DEV-011 publishes quality 161. Propose the minimal legacy-faithful remedy:
   e.g. after tillage, project each mixed layer's water ion pair to Kw and carbonate to CO2 equilibrium
   (charge-neutral), or run the solute solve with the STARTE (initial-equilibration) budget for the first hour
   after tillage. Judge each against legacy and conservation.
≤400 words → `.agent/adversarial/round_00023_deepseek.md`. Reply `DONE <path>`.
