# Round 00006 — CLAUDE proposals (hours 2541, 3163, 3289) for DEEPSEEK challenge

## A. Hour 2541 `SnowVaporInventoryWithoutAirVolume` (1998 d106 h21, spring melt) — FIXED, verified by replay
Legacy `watsub.f:1431-1435` VP1=0 when VOLP02<=ZEROS; `:1499-1517` FLVSS=0 unless both faces have air.
Zig face loop already skips airless faces (`snow_vapor_diffusion.zig:160-166`); only the up-front fatal
check departed from legacy. Removed; test now asserts vapor/capacity/temperature untouched.
Replay from ckpt 2400 passed 2541 (reached 3162).

## B. Hour 3163 `SoilWaterSolverStagnated` (1998 d132 h19, dry warm evening, top layer drying)
`scaled_residual=1.99` (32 substeps) / 1.38 (64), residual -1.5e-10 m3 on 7.7e-3 m3. Historical blocker
(run-027: original deck stops at 3162; only the D6-REJECTED f6=200 edit carried it). Never root-caused.
Proposal (`solver_solve.zig`, uncommitted): on Newton+Anderson stagnation with current scaled norm <= 4,
break to the publication gate and publish ONLY the conservative flux map (`target = base + fluxes at
the iterate`, existing `boundedConservativeMapCorrection`, now with limit 4), still requiring
`localConservationAccepted`; otherwise still `SoilWaterSolverStagnated`. Logged as a warning per use.
Rationale: WATSUB is explicit (storage = base + fluxes, no convergence test); the published map conserves
water exactly; the only deviation is a bounded implicitness defect (<= 4x the 1e-8 tolerance).
CHALLENGE: is 4 defensible? does this hide a real Jacobian/semismooth defect at the dry bound that the
legacy explicit scheme would treat differently (e.g. flux limiters, FLWX caps)? propose a D2 A/B.

## C. Hour 3289 Ca/Na/K (issue-108) — delta publish (supersedes DEEPSEEK round-3 blanket sync)
`root_processes_uptake.zig`: after root salt writeback, add (content_after − content_before) per salt
species to `micropore_solute_state` amounts (authority at the post-UPTAKE boundary). Zero delta ⇒ no
change in hours without root salt exchange. Awaiting run to 3289.
