# DEEPSEEK task — Round 00026 ANALYSIS (from CLAUDE)

r00025 design accepted with one change: the entry RHHX reset is applied AFTER packing the rollback state (a failed
solve restores the unprojected entry and books no extent); success adds the extent to
`accepted_water_equilibrium_extent_mol_per_m3` (uncommitted, `reaction_solve.zig applyEntryWaterEquilibriumReset`).

New frontier (strict run r00014, commit 6f50e81): hour 2786 (1998 d117 h02) `NewtonPicardDidNotConverge` in the
SURFACE (litter/pond) temperature solve, all substep rungs: Newton-Anderson 100 iterations pinned at
T = 273.14999308 K (≈ 273.15 − 6.9e-6). Litter phase context: liquid 4.80e-3 m3, ice 2.35e-4, porous medium =
max(retention, water+ice) = 5.03e-3 (saturated pond — ponded water now stays on the surface since the NN=3 gate),
heat capacity 2.06e-2 MJ/K, dry 5.1e-6 MJ/K; sensible/latent conductance 0 (snow-covered?); conductive to soil ~1.19.
`nearestRepresentableRootCertificate` did not rescue it → the residual jumps across T_m.

Analyse (cite file:line; `surface/temperature_solver.zig` surfacePhaseEquilibrium ~1428, limitPhaseChangeToAvailableEnergy
~1479, `surface/litter_freeze_thaw_energy_limit.zig` / `freeze_thaw_energy_limit.apply`, `soil/water/phase_change.zig`
dallAmicoEquilibrium):
1. Where is the discontinuity? Hypothesis: the energy limit's TFREEZ (from water_potential_megapascal, 9.0959e4 /
   6.2913e-3 terms) is 273.15 − ~7e-6 while Dall'Amico with saturated head 0 melts at exactly 273.15, so between
   them requested and permitted phase change have opposite signs → a jump. Confirm or refute from the code.
2. Legacy watsub.f litter (layer 0) freeze-thaw (~3140-3160 TFREZ/TFREEZ, HFLF limit): which single freezing
   temperature does legacy use for both the equilibrium direction and the energy limit?
3. Minimal legacy-faithful fix so F(T) is continuous (e.g. use the same depressed melting temperature in both).
≤350 words → `.agent/adversarial/round_00026_deepseek.md`. Reply `DONE <path>`.
