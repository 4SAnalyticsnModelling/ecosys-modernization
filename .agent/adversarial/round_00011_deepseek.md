# Adversarial Review: Round 00011 — DEV-011 Challenge & Solver Performance

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: DEV-011 (`reaction_solve.zig` `acceptBestBoundedIterate`, `hourly_heat_water_solute.zig` ladder terminal fallback) & Performance of SOLUTE recovery ladder.  
**Reference Legacy Sources**: `f77src/solute.f:111,822,2334-2740,2770-2920`  
**Reference Code Sites**: `reaction_solve.zig:685-718,1501-1553`, `hourly_heat_water_solute.zig:12040-12160`, `stages/soil_chemistry_convergence.zig:630-711`

---

## 1. Challenge DEV-011: Best Bounded Iterate vs Legacy MRXN

### Scientific Validity & Risks
1. **Can best bounded iterate be worse than legacy MRXN?**  
   **No**, DEV-011 is strictly superior and safer than legacy Fortran's blind MRXN publication. Legacy `solute.f` runs a fixed `MRXN=60` iterations (line 111, 822) with ad-hoc damping/clamping (`AMAX1(ZEROC, ...)`) and publishes the raw 60th state unconditionally—without verifying convergence, element inventory, or charge neutrality. DEV-011 selects the iterate minimizing the physical residual norm ($\min \|\mathbf{r}\|_{\text{phys}}$) and subjects it to strict invariants (`requireConservedInventories`, `reaction_charge.requireConservedStates`, and `commitAcceptedWaterEquilibriumProjection`).

2. **Legacy-Faithful Alternative**:  
   Rather than falling back to an unverified Picard cycle, porting the MRXN damped-relaxation loop directly would reintroduce unclosed charge and mass drifts into modern Zig. DEV-011's formulation—accepting the best bounded state while enforcing atomic conservation—is the canonical modernization equivalent of legacy's heuristic termination.

3. **Required Attribution Evidence**:
   - Trace log showing the maximum physical residual norm of the accepted best iterate (e.g., $\|\mathbf{r}\|_{\text{phys}} < 10^{-2}$).
   - Verification that elemental mass drift remains within machine epsilon ($< 10^{-12}\text{ mol/m}^3$) across all species.
   - Proof that subsequent time hours (e.g., 3670+) do not cascade into immediate solver failure from state divergence.

---

## 2. Performance: Mitigating the Whole-Hour Recovery Ladder

### Bottleneck Diagnosis
In `hourly_heat_water_solute.zig:12090-12159`, when a single SOLUTE layer stagnates (e.g. hour 3649–3668, layer 0), `recoverFixedExternalHourAdaptively` retries across 4, 8, 16, 20, 32, and 64 substeps. Each ladder escalation re-executes the entire coupled hour (surface energy balance, canopy snow, Richards flow, heat transport, gas transport) for all grid cells and all layers, wasting minutes on non-failing physics.

### Proposed Neutral Optimization
1. **Layer-Scoped Subcycling within `stages/soil_chemistry_convergence.zig:630-662`**:  
   Instead of escalating the entire external coupled hour schedule, isolate the failing layer in `solveHourlyReactionCells`. When `solveHourlyReactionLayer` fails on `SoluteReactionSolverStagnated`/`DidNotConverge`, retry *only that layer* with an internal subcycling of solute boundary fluxes or reduced virtual step within the hourly chemistry window before triggering the full-hour ladder.
2. **Persistent Schedule Caching**:  
   Cache `preferred_substep_count` per cell or advance `preferred_substep_count.*` across consecutive stiff hours (e.g., keep 4 or 8 instead of decaying immediately via `coarsening_probe_cooldown`), avoiding 5 failed attempts per hour during seasonal drying/freezing transitions.
3. **Early Escalation on Solute Stagnation**:  
   If Richards flow converged cleanly at 4 substeps and failure was purely a phosphate boundary singularity in `reaction_solve.zig`, skip intermediate 8/16/20 ladder steps and jump directly to 32 or terminal best-bounded acceptance.
