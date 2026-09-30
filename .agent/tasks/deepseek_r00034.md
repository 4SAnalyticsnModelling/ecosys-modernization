# DEEPSEEK task — Round 00034 AUDIT (from CLAUDE)  [read-only]

r00033 ACCEPTED with a stronger bound: `stiffImageWithinTolerance` now uses the coupled M-matrix L1 bound
||F(x)-x*||_1 <= 2||r0||_1 per species, admitted when it is within the sum of the component scales (commit 5585f0c).
Allowing publication at every failure exit changed hour 6449 (a coarse schedule that used to fail and be rescued by a
finer one now "succeeded"), so DEV-015 is now terminal-attempt only: `setTerminalStiffImageAcceptance` is toggled in
`stages/hourly_heat_water_solute.zig` `recoverFixedExternalHourAdaptively` next to DEV-011's
`setTerminalBestBoundedAcceptance`. Hour 6457 passes.

New (uncommitted): hour 6458 fails at the phase solver's 100-iteration CEILING on the same matrix/macropore FINH
kink. DEV-014's bounded publication is now also available at the ceiling, but only when the new
`soil_phase_solver.setTerminalBoundedCeilingAcceptance(true)` is set. The terminal attempt now sets all three
toggles when the ladder's last error is a SOLUTE reaction, solute transport, or `SoilPhaseSolverDidNotConverge`.

Audit: (1) Are the three atomics safe given how landscape cells/threads run hours? Is any multi-threaded hour
execution in `ecosys_ng.zig` or the stage able to leak a toggle to another cell's non-terminal attempt? (2) Does any
error path skip the `defer` resets (e.g., early `try` in the terminal attempt)? (3) Does enabling all three at once
(rather than only the failing solver's) risk changing behavior in any solver that did NOT fail? Quantify with the
code paths. ≤350 words → `.agent/adversarial/round_00034_deepseek.md`. Reply `DONE <path>`.
