# DEEPSEEK task — Round 00015 INDEPENDENT ANALYSIS (from CLAUDE)

r00014 ACCEPTs recorded, thanks. New frontier: Ottawa hour 4037 (1998 d169 h05, after ~8 mm rain) fails.

Evidence (checkpoint-3840 replay, 4-substep attempt, dt=0.25 h):
`TEMP_DIAGNOSTIC renormalized temperature out of domain: layer=0 temperature_k=127.2 prior_k=298.59
target_mj=2.4126 fusion_offset_mj=0 coefficient_mj_per_k=1.8963e-2 dry_mj_per_k=1.0334e-8
matrix_liquid_m3=4.5165e-3 macro_liquid_m3=7.7e-11 vapor_m3=9.3e-6 ice_m3=0`
(an earlier replay showed dry_mj_per_k=2.05e-6 in the same layer). Layer-0 matrix pore capacity 7.75e-3 m3, cell 1 m2.
Error = `SoilHeatRenormalizedTemperatureOutsidePhysicalDomain` from `temperatureForCellEnthalpy`
(`ecosys-ng/src/soil/water/heat_step.zig` ~2607), reached from the post-Richards rebase
`renormalizeTemperatureToConservedEnthalpy` (~2750). Afterwards finer substeps fail with
`AcceptedTopsoilVaporPoreOverfill` (hourly_heat_water_solute.zig ~6929) and phase freezing.

Two anomalies, analyse both (cite file:line; legacy refs in f77src/ welcome):
1. Dry solid heat capacity of layer 0 is ~1e-8..2e-6 MJ/K although the layer has 7.75e-3 m3 pores (a real
   1.5 cm mineral layer would be ~2e-2 MJ/K). Trace every writer of `soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k`
   and `soil_thermal.layer_volume_m3` (relayering.zig ~1099, heat_layer_remap.zig ~365, pond_water_heat_transfer.zig ~82,
   tillage runtime_adapter.zig ~1044, runtime_material_refresh.zig). Which can drive layer 0 solids to ~0?
   What does legacy do (VHCM / VOLT of layer NU)?
2. Richards moves water at fixed temperature; the rebase restores pre-move enthalpy and only the later spatial
   heat solve adds donor-upwind heat. With near-zero solids, internal inflow ≥ resident water makes the
   intermediate temperature < 173 K. Is this intermediate state a design bug independent of (1)? Propose the
   minimal legacy-faithful fix (WATSUB applies FLWL and HFLWL together).
Verdict + proposal ≤350 words → `.agent/adversarial/round_00015_deepseek.md`. Reply `DONE <path>`.
