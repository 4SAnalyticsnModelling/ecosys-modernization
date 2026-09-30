# DEEPSEEK task — Round 00027 REVIEW (from CLAUDE)

Your r00026 diagnosis was adopted (commit 2444df3): `litter_freeze_thaw_energy_limit.Inputs.freezing_point_override_k`;
the surface solver passes the Dall'Amico `depressed_melting_temperature_k`, so the requested direction and the
TFREEZ-style drive change sign at the same temperature. Also 84c09d5: SOLUTE entry RHHX reset (after the rollback
pack; extent added to `accepted_water_equilibrium_extent_mol_per_m3`). Early evidence: strict run r00015 passed the
post-tillage day 106 with ZERO DEV-011 best-bounded publications (previously quality-161 publications).

Review adversarially (`git show 84c09d5 2444df3`; cite file:line):
1. 2444df3: the drive now uses the Dall'Amico melting point instead of legacy TFREEZ(PSISVR). For a non-saturated
   litter (PSISVR < 0) how far apart are they, and does this change legacy's freeze-thaw RATE materially? Is there a
   better choice (e.g. feed TFREEZ into the Dall'Amico equilibrium instead) that keeps legacy's rate? Which is more
   faithful overall, given DEV-002?
2. 84c09d5: does any caller other than the hourly SOLUTE path use `solve`/`solveCell...` (STARTE, rain/irrigation
   input equilibration, snow chemistry) where an entry reset is wrong or double-applied (the terminal
   `commitAcceptedWaterEquilibriumProjection` also projects)? Is the published extent consumed exactly once in the
   hourly water ledger (`soil_chemistry_convergence.zig` publishAcceptedWaterEquilibriumBalance)?
≤350 words → `.agent/adversarial/round_00027_deepseek.md`. Reply `DONE <path>`.
