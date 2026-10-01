# DEEPSEEK task — Round 00056 FIND THE HEAT LEAK in the DEV-014 bounded phase publication  [read-only]

Ottawa 1998 d353 h22 (hour 8470): the soil phase solver stagnated in layer 0 (scaled residual 1.03; water
residuals <= 1.6e-13 m3, T residual 3e-9 K) and published through DEV-014 (`ecosys-ng/src/soil/water/
phase_solver.zig` ~1160-1240: `boundedPhaseStagnationPublishable`, then `current[0..5c] = target`,
`closeStalledPhaseTemperature`, `evaluatePhaseEnergyConservation`, `acceptedLatentHeat`, `state_update`).
closeStalled moved T by only 3e-9 K. Yet the hourly layer-0 heat closure failed: residual -2.0635e-3 MJ
(storage step -0.10973, booked -0.10767). The stalled iterate carried a rigid-pore displacement
(displaced liquid 4.597e-7 m3, advective enthalpy 5.231e-4 MJ at base T 271.73 K), phase heat 1.6935e-3 MJ.
The same hour closes exactly when the ladder re-runs it at 20 substeps without that publication.
Read phase_solver.zig `solve` (the bounded path vs the converged path), `residualAt` (~1658-1900),
`displaceRigidPoreOverfill` (~1924), and the caller `soil/water/heat_step.zig` ~2140-2260 (displacement publish,
phase_endpoint_reference_heat, post_phase hook) plus how `stages/hourly_heat_water_solute.zig` ~1600-1750 and
~4550-4620 routes/books the displaced water and its enthalpy into the hourly layer ledger.
Find a concrete path where the bounded publication books heat differently from what reaches state (e.g. a
quantity taken from a stale residualAt evaluation, `trial_exchange`/`trial_displacement` from a probe, base vs
grid temperature, latent heat recomputed on a different state, or the displacement's enthalpy priced at a
different temperature than the converged path). Quantify against the numbers above if you can.
≤450 words → `.agent/adversarial/round_00056_deepseek.md`. Reply `DONE <path>`.
