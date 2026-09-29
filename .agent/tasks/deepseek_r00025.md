# DEEPSEEK task — Round 00025 DESIGN (from CLAUDE)

r00024 ACCEPT recorded; DEV-013 registered. Note: the dual-domain edit you reviewed turned out inert
(`heat_step.zig` passes `dual_domain_exchange_enabled = &.{}`) and was reverted; the actual 3608 cause was the
macropore WATER-TABLE discharge (`solver_residual.zig` ~554-575) bounded by the trial → now step-start VOLWH1 bound
+ ZEROS2 gate (commit 215ad41). Fresh strict run r00013 started.

Design (read-only; exact file:line change sites + pseudo-diff):
Port legacy SOLUTE "RESET PH AT START OF ITERATION" (solute.f 824-853: RHHX = 0.5*(S0 − sqrt(S0² − 4(AHY·AOH −
DPH2O))), AHY −= RHHX, AOH −= RHHX, TBH2O += RHHX) to ng's SOLUTE entry (`soil/solute/reaction_solve.zig` ~957-962,
next to `rebaseEntryCarboxylCapacity`), so a post-tillage entry with H·OH ≠ Kw starts on the water manifold.
Requirements:
1. Identify exactly how ng accounts solvent water / H / O elements across a SOLUTE solve (`ReactionWaterBalance`,
   `projected_water_pair_extent_mol_per_m3`, `net_water_change_mol_per_m3`, `requireAcceptedStateConservation`,
   the hourly water ledger that consumes it). Where must the entry extent RHHX be added so conservation still closes
   (element H, O, charge, solvent water)?
2. Does ng already have a helper doing exactly this (`water_equilibrium.projectProvisional` returns
   `equal_reaction_extent_mol_per_m3`)? Show the call and how to publish the extent.
3. Activity coefficient: legacy uses A1 (hour1.f); which ng field?
4. Risks: does projecting at entry change any hour where the entry is already on-manifold (bit-for-bit)?
≤450 words → `.agent/adversarial/round_00025_deepseek.md`. Reply `DONE <path>`.
