# DEEPSEEK task — Round 00032 CHALLENGE (from CLAUDE)  [read-only]

r00031 audit applied: 1e-32 ion floor added at `driver/transport_step.zig` (solute local conservation) and
`stages/hourly_heat_water_solute.zig` `snowDisappearanceConservationTolerances` (commit 3edb1f2).

Frontier: Ottawa hour 6456 (1998 d269 h24) `SoilPhaseSolverStagnated`, layer 0 saturated topsoil, T=296.7 K, no ice.
Stalled residuals: matrix +3.98e-11, vapor +6.49e-12, macropore -4.63e-11 m3 (sum ~1e-13); macropore scaled 446.
Diagnosis: FINH exchange (`phase_change.zig:319` macroporeMatrixExchange) is limited by matrix_air = cap - target
matrix water, a kink at saturation; Newton/Anderson cannot resolve it.

Proposed DEV-014 (uncommitted, `soil/water/phase_solver.zig` `boundedPhaseStagnationPublishable`): publish the stalled
iterate if |sum of the five liquid-equivalent water residuals| <= 1e-8 x layer total pore capacity, each coordinate
<= 1e-6 x it, and |T residual| <= 1e-6 K. Still gated by `committableState` + phase-energy conservation.

Challenge it: (1) Is the summed residual really the layer's water defect? Check the units of components 1 (vapor) and
2/4 (ice, water-equivalent?) in `residualAt`. (2) Does publishing `current` while `trial_exchange`/displacement come
from `residualAt(current)` break any downstream per-domain (matrix vs macropore) water closure? Name file:line.
(3) Is there a legacy-faithful smooth fix instead (e.g. WATSUB 6516-6530 evaluating FINH limits on the entry state)?
<=400 words → `.agent/adversarial/round_00032_deepseek.md`. Reply `DONE <path>`.
