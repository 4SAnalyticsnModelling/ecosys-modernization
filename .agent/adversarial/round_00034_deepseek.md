# Round 00034 Audit: Terminal-Attempt Fallback Atomics & Coupling Scope

## 1. Thread Safety & Landscape Scope
- **Execution model**: In `ecosys_ng.zig:7879` and `hourly_process_driver.zig:248-807`, hourly science runs sequentially across the landscape. The outer `hourly_heat_water_solute.zig` ladder is single-threaded. Worker threads in `compute.zig` operate on internal tile kernels, not concurrent hours or separate cell ladders.
- **Leakage risk**: Zero cross-hour leakage. Because the driver executes sequentially, an active toggle during the terminal attempt of hour $H$ cannot be seen by any other concurrent hour.
- **Within-hour ladder scope**: Across all cells, the terminal attempt runs on the finest schedule ($N=64$) for the entire profile simultaneously. Non-terminal attempts are already exhausted; thus, no cell in that hour runs a non-terminal attempt.

## 2. Defer Integrity on Error Paths
- In `stages/hourly_heat_water_solute.zig:12253-12258`:
  ```zig
  ecosys.solute_reaction_solver.setTerminalBestBoundedAcceptance(true);
  defer ecosys.solute_reaction_solver.setTerminalBestBoundedAcceptance(false);
  ecosys.solute_transport_solver.setTerminalStiffImageAcceptance(true);
  defer ecosys.solute_transport_solver.setTerminalStiffImageAcceptance(false);
  ecosys.soil_phase_solver.setTerminalBoundedCeilingAcceptance(true);
  defer ecosys.soil_phase_solver.setTerminalBoundedCeilingAcceptance(false);
  ```
- **Error paths**: In Zig, `defer` blocks execute in reverse LIFO order upon *any* function exit: early returns, errors from `try runBoundedRecoveryAttempt(...)`, panics, or success. No error path can bypass resetting the atomics to `false`.

## 3. Risk of Enabling All Three Fallbacks Simultaneously
Enabling all three toggles unconditionally on the terminal attempt carries **no risk of cross-contamination**:
1. **SOLUTE Reaction (`reaction_solve.zig:1520-1525`)**: Gated behind `catch |err| switch (err) { error.SoluteReactionSolverStagnated, error.SoluteReactionSolverDidNotConverge => ... }`. A converging chemistry solve never reaches this branch. `acceptBestBoundedIterate` enforces element conservation and charge balance ($Q < 10^{-2}$).
2. **Solute Transport (`transport_solver.zig:381-392`)**: Requires `final_norm <= 1` (a converged iterate), `publication_norm > 1`, and passes the coupled $M$-matrix $L_1$ bound $\|F(x) - x^*\|_1 \le 2\|r_0\|_1 \le \sum \text{scale}$. A normally converging transport solve publishes cleanly at line 384 without invoking DEV-015.
3. **Soil Phase Solver (`phase_solver.zig:1125-1128, 1193-1199`)**: Only accessed if iterations reach `max_iterations = 100`, `final_norm > 1`, and `boundedPhaseStagnationPublishable` verifies total water defect $\le 10^{-8} \times V_{\text{pore}}$, partition split $\le 10^{-6}$, $|\Delta T| \le 10^{-6}\text{ K}$, plus `committableState` and energy conservation.

**Conclusion**: Each fallback is shielded behind strict multi-layer activation guards (solver failure + norm failure + domain-specific conservation limits). Enabling all three simultaneously on terminal retry is robust and eliminates solver-specific dispatch brittleness.
