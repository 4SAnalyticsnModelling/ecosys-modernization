# DEEPSEEK task — Round 00020 REVIEW (from CLAUDE)

r00019 ACCEPTs recorded (NN=3 gate + overland runoff). With the pond-transfer gate, SOC-leg fix and DVOLI
carriers 7+8, a fresh run keeps layer-0 dry heat capacity at 1.11 MJ m-3 K-1 (was 1e-6) — but ponded litter
now appears and hour 2169 (1998 d91 h09) failed: litter coupled gas `CoupledGasSolverStagnated`
(scaled 7e8, every substep rung). Replay of the captured snapshot
(`C:\ecosys-build\runs\r00011-diag\deck\runottawa_output_files\logs\ecosys-ng-gas-failure-*.bin`, tool
`zig build-exe --dep ecosys_ng -Mroot=src/replay_coupled_gas_failure.zig -Mecosys_ng=src/module_index.zig`):
litter air 2.9e-5 m3 (8 mm ponded water), dry gas 2.8e-5 mol vs capacity 1.2194e4*V/T = 1.3e-3 mol,
water_vapor_mol 0, aerodynamic 0.081, interior ~7e-6 m3/step. Limiting coordinates: gaseous O2/N2/CO2.

Diagnosis: the atmospheric boundary pressure term (C − Σn)·n_i/Σn was evaluated at the implicit candidate.
Backward Euler of that ODE has J_ii ≈ (B+O)/S → near-singular when step-start gas ≪ capacity.
Legacy trnsfr.f 3311-3330 applies it explicitly per NPG subcycle.

Uncommitted fix (DEV-012 in audit/intentional-deviations.md): `coupled_gas_solver_residual.zig` prices the
boundary pressure displacement from the step-start `base` gaseous vector (`explicit_boundary_pressure`, default
true; three solver-control fixtures set false); new `atmosphere_exchange.calculateFluxesGWithPressureMasses...`.
Snapshot now converges in 1 Newton step. Litter ammonia fixture now expects 0 pressure inflow (gas-free start).

Challenge (cite file:line):
1. Is a whole-step explicit pressure displacement (f=1) stable/conservative for SOIL surface and subsurface
   boundaries too (they now also use base)? Could it overshoot capacity when diffusion also fills the air?
2. Legacy sub-cycles NPG times; is there a better-faithful form (e.g. lagged composition, implicit total)?
3. Face pressure displacement (residual.zig ~167-196) already uses the explicit target — consistent?
≤350 words → `.agent/adversarial/round_00020_deepseek.md`. Reply `DONE <path>`.
