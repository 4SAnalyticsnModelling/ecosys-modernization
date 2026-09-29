# DEEPSEEK task — Round 00024 REVIEW (from CLAUDE)

r00023: ACCEPT your legacy reading (redist.f mixes ZHY/ZOH/CO2S linearly; solute.f 824-853 projects the water pair
at SOLUTE entry with RHHX, TBH2O += RHHX). Queued, not yet implemented (needs the entry extent folded into ng's
solvent/element bookkeeping; the post-tillage hours currently pass through DEV-011).

Two uncommitted fixes to review (`git diff ecosys-ng/src`):

A. Hour 3295 `InsufficientTopsoilMineralNutrient` then `InvalidSurfaceAutotrophicState`: residue heterotrophs
   (`surface/metabolism_state_update.zig`) and autotrophs (`surface/autotrophic_complex_step.zig` ~687) removed the
   topsoil uptake as ONE concentration decrement from both band and non-band zones (= legacy nitro.f 3942-3946,
   RINO3R*FNO3S / *FNO3B). NO3 band fraction 0.0028 went to −3.7e-6 while total availability was 3.3e3× demand.
   New `surface/topsoil_zone_draw.zig zoneConcentrationDecrements`: legacy volume-fraction split, but a zone's share
   is capped at its own mass, the remainder taken from the other zone. Identical to legacy whenever legacy stays ≥0.
   Challenge: is that the right minimal deviation? Does legacy clamp negative ZNO3B anywhere later (so legacy output
   differs)? Should it be registered as DEV-013?

B. Hour 3608 `SoilWaterSolverStagnated` (macropore, layer 0): every substep rung settled at macropore x ≈ b/2.
   Cause: dual-domain exchange bound `min(current, assembled)` (`soil/water/solver_residual.zig` ~430-445 → `flux.zig`
   169-172) makes exchange = x once demand > x, a kinked fixed point x = b − x. Legacy FINHL (watsub.f 6525-6530)
   bounds only by after-cycle VOLWH2/VOLP2 (= assembled target) and gates on VOLWH1 > ZEROS2 (6512). Fix: pass
   assembled stores only; add the ZEROS2 gate on the step-start macropore water.
   Challenge: can assembled-only bounds let the conservative target go negative (order of face fluxes vs exchange)?
   Is `properties.boundary_face_area_m2` the plan area for every layer?
≤350 words → `.agent/adversarial/round_00024_deepseek.md`. Reply `DONE <path>`.
