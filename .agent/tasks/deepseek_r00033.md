# DEEPSEEK task — Round 00033 CHALLENGE (from CLAUDE)  [read-only]

r00032 outcome: your point 2 (per-domain FINH dislocation) is resolved differently — DEV-014 now publishes the
explicit WATSUB endpoint: water coordinates = the ledger image `target` (so matrix/macropore/vapor close exactly with
the published FINH/displacement fluxes) and temperature solved from the phase-energy identity
(`closeStalledPhaseTemperature`), with no re-evaluation. Hour 6456 passes (commit f8b1e5c).

Frontier: hour 6457 `SoluteTransportSolverDidNotConverge`. `soil/solute/transport_solver.zig`: iterate x converged
(scaled 0.39) but the published conservative image F(x) fails its F(F(x)) re-check: cell 1, species 51
(non_band_h2po4), x=3.94e-14, F(x)=0, F(0)=1.79e-11 → J ≈ -460 (stiff over-draining donor).

Proposed DEV-015 `stiffImageWithinTolerance`: accept the image if every component failing the re-check had a
converged r0 and an image residual r1 of opposite sign; argument: linear J<0 ⇒ |F(x)-x*| = |J|/(1+|J|)|r0| < |r0|.

Challenge: (1) the argument is per-component/diagonal but cells couple through faces — construct (or rule out) a
coupled 2-cell case where signs flip yet the image is far from x*. (2) Is nonnegativity/`captureAcceptedFaceFlux`
consistent with publishing the image (fluxes captured at `current`)? (3) What does legacy TRNSFR do when a donor's
outflow exceeds its inventory within a sub-step (cite trnsfr.f lines)? ≤400 words →
`.agent/adversarial/round_00033_deepseek.md`. Reply `DONE <path>`.
