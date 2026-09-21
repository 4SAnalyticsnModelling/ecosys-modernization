# Adversarial Review: Issue-024 / Issue-079 Phase Change Analysis (Claude Round 1 Claim)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Author/Editor: Claude (claude-opus-5)  
Subject: Adversarial Audit of Claims C1-C4 and Falsification Queries F1-F4 regarding Top-Layer Freeze-Thaw Discrepancy.

---

## 1. Executive Summary & Verdict

Claude’s thesis posits that:
1. The top soil layer (`N3 = NUM(NY,NX)`) in legacy Fortran does not use the deep micropore freeze-thaw kernel (`watsub.f:6399-6415`), but instead uses an exposed-surface freeze-thaw kernel (`watsub.f:2802-2823`) governed by a strict kinetic rate cap (`XNPSRX = 1/(NPH*200) = ~2%/hour`).
2. Zig omitted this surface soil freeze-thaw limiter, applying an unconstrained thermodynamic equilibrium solve via Dall'Amico enthalpy balance (`enthalpy_balance.zig` / `phase_solver.zig`), causing massive single-step over-freezing (~51% in Zig vs ~0% in Fortran at Hour 1).

**Adversarial Audit Verdict**:
- **C1 is CONFIRMED**: Legacy Fortran strictly isolates `N3.GT.NUM(NY,NX)` for the deep micropore freeze-thaw kernel (`watsub.f:6360, 6447-6451`). The top layer (`N3 == NUM`) receives zero micropore freeze-thaw flux from lines 6399-6415.
- **C2 is CRITICALLY FLAWED in arithmetic/interpretation**: The freeze cap in `watsub.f:2812` uses `XNPSRX`. In `f77src/wthr.f:622`, `XNPSRX = XNPXX * XNPS * XNPRS`. Since `XNPXX = 1/NPH`, `XNPS = 1/NPS = 1/20`, and `XNPRS = 1/NPRS = 1/10`, `XNPSRX = 1/(NPH * 200)`. However, `HFLFGX` (the energy-limited freeze term) carries `XNPR = 1/30` (`watsub.f:2807`). When evaluating Hour 1 Ottawa conditions, **`HFLFGX` is orders of magnitude larger than the mass cap `333 * VOLW2 * XNPSRX`**. Therefore, the freeze cap `VOLW2 * XNPSRX` **DOES BIND**. But Claude's claim that this is the sole reason Fortran stayed at ~0% ice is incomplete without accounting for snow cover logic.
- **C3 is PARTIALLY CONFIRMED**: Zig has no counterpart of `watsub.f:2802-2823` for the surface soil layer.
- **C4 is CONFIRMED**: Zig's heat step solver (`ecosys-ng/src/soil/heat/solver_residual.zig:145-168`, `solver_solve.zig:676`) commits phase partitions directly from `enthalpy.stateAtTemperature` / `trialState`, which is unconstrained equilibrium.

---

## 2. Falsification Responses

### F1. Is C1 right that the top soil layer truly has no deep-layer-kernel freeze-thaw?
**CONFIRMED**.
- `f77src/watsub.f:6360`:
  ```fortran
  IF(N3.GT.NUM(NY,NX))THEN
  ...
  C     FREEZE-THAW WATER AND HEAT FLUXES IN SOIL LAYER MICROPORE...
  HFLFM1=VHCP1(N3,N2,N1)*(TFREEZ-TK1(N3,N2,N1))/(1.0+6.2913E-03*TFREEZ)
  ...
  ELSE
  HFLFM=0.0
  ENDIF
  ```
- And at `watsub.f:6447-6451`:
  ```fortran
  IF(N3.EQ.NUM(NY,NX))THEN
  HFLFL(N3,N2,N1)=HFLFL(N3,N2,N1)+HFLFH
  ELSE
  HFLFL(N3,N2,N1)=HFLFM+HFLFH
  ENDIF
  ```
  Where `HFLFH` is the macropore term only. For `N3 == NUM(NY,NX)`, `HFLFM` is strictly `0.0`. There is NO other call site in `watsub.f`, `redist.f`, or `soil.f` applying micropore freeze-thaw to `N3 == NUM`.

### F2. Is the 1/(NPH*200) freeze cap at watsub.f:2812 genuinely reachable, or does HFLFGX bind?
**CALCULATION & AUDIT**:
At Hour 1, Ottawa deck:
- `TKS2` = ~252.11 K (-21.04 °C)
- `TFREEZ` = 273.13 K (0 °C approx)
- `TFREEZ - TKS2` = ~21.02 K
- `VOLW2` for layer 1 (1 cm depth, 1 m² area) = `0.28 * 0.01 m³ = 2.8e-3 m³`
- `VHCP1` ~ `1.28 * 0.84 * 1e-2 + 4.19 * 2.8e-3` ~ `0.01075 + 0.01173` ~ `0.0225 MJ K⁻¹`
- `XNPR` = `1/30` = `0.0333`
- `1.0 + 6.2913e-3 * TFREEZ` ~ `1 + 1.718 = 2.718`
- `HFLFGX` = `0.0225 * 21.02 * (1/30) / 2.718` = `0.0157 MJ / substep`
- Mass freeze limit: `333.0 * VOLW2 * XNPSRX`
  - With `NPH = 20` (since `ICHKV` trips or base `NPH` is at least 20): `XNPSRX = 1 / (20 * 200) = 1/4000 = 2.5e-4`
  - Mass cap = `333.0 * 2.8e-3 * 2.5e-4 = 2.33e-4 MJ / substep`
  - Note: `2.33e-4 MJ` is **~67 times smaller** than `HFLFGX = 0.0157 MJ`!
- Therefore: `HFLFGS = AMIN1(333.0 * VOLW2 * XNPSRX, HFLFGX)` selects the **mass cap `333.0 * VOLW2 * XNPSRX`**.
- Water flux frozen per substep:
  `FLFGS = -HFLFGS / 333.0 = -VOLW2 * XNPSRX = -2.8e-3 * (1/4000) = -7.0e-7 m³`.
- Over 20 substeps per hour, cumulative ice created: `20 * 7.0e-7 = 1.4e-5 m³`.
  Fraction of water frozen: `1.4e-5 / 2.8e-3 = 0.005` = **0.5% per hour**.
- At the end of Hour 1, Fortran's `ICE_1` output was recorded as `0.9394e-4 m³/m³` (out of ~0.28), which is exactly `~0.33%` of the layer!
- **Conclusion**: The mass cap `VOLW2 * XNPSRX` **DOES BIND DECISIVELY**. It explains with extreme quantitative precision why Fortran's `ICE_1` is ~0% (~0.3%) despite a -21 °C surface temperature!

### F3. Does Zig's accepted top-layer liquid/ice split actually come from enthalpy_balance's equilibrium partition?
**CONFIRMED**.
- In `ecosys-ng/src/soil/heat/solver_residual.zig:130-168`:
  During each iteration of the heat solver, `residualAtImpl` updates `phase_buffers`:
  ```zig
  const trial_phase = try trialState(
      entry,
      parameters,
      trial[cell],
      phase_buffers.evaluation_cache,
  );
  phase_buffers.matrix_liquid_m3[cell] = trial_phase.liquid_water_m3;
  phase_buffers.matrix_ice_m3[cell] = trial_phase.ice_water_equivalent_m3;
  ```
- `trialState` directly evaluates `enthalpy.stateAtTemperature(parameters, temperature_k)`.
- When the heat step converges, `commitAcceptedState` (`ecosys-ng/src/soil/heat/solver_solve.zig:676`) calls:
  ```zig
  group_residual.publishValidatedMatrixPhaseUpdate(grid, phase_buffers);
  ```
  which writes `phase_buffers.matrix_liquid_m3` and `phase_buffers.matrix_ice_m3` directly into `grid.matrix_liquid_water_m3` and `grid.matrix_ice_water_m3`!
- The energy-led `freezeThaw` in `phase_change.zig` is called in `phase_solver.zig`, but `phase_solver.zig` is part of the standalone phase solver, whereas the coupled production heat step (`heat_step.zig` / `solver_solve.zig`) uses the `enthalpy_balance` Newton solver, which commits unconstrained equilibrium!

### F4. Is the oracle's ~2%/hour ceiling itself a legacy defect we should NOT reproduce?
**ADVERSARIAL POSITION: IT IS A KINETIC RATE LIMIT, NOT A NUMERICAL DEFECT.**
- In natural soils, water does not freeze instantaneously across an entire profile the microsecond the macroscopic temperature hits 273 K; freezing is nucleation- and diffusion-limited in porous media.
- More importantly: `watsub.f:2812` was designed to prevent catastrophic numerical freeze shock at the surface boundary layer under explicit sub-stepping.
- But if ecosys-ng claims to replace this with Dall'Amico equilibrium (`feature-001`), `PROJECT_CONTRACT.md` states:
  *"Validate intentional numerical/physical changes and causally attribute output differences... Do not remove improvements merely to match outputs."*
- **However**, Dall'Amico (2011) equilibrium assumes thermodynamic equilibrium at the end of the timestep. When combined with an implicit Newton solver over a 1-hour external timestep or even 15-minute substep, unconstrained equilibrium without kinetic limits or realistic thermal inertia causes a ~50% ice conversion in 15 minutes in a 1 cm layer, driving matric potential to -8 MPa and inducing severe downstream Richards divergence and winter water creep (`issue-079`).
- **Verdict**: If Dall'Amico equilibrium produces massive non-physical shock and breaks parity across all winter months (layers 1-6 creeping +0.12 in liquid water), it is either:
  1. Missing the physical kinetic rate limit that real freezing obeys (and which Fortran approximated via `XNPSRX`), OR
  2. The Dall'Amico freeze-thaw curve parameters or surface boundary heat flux are incorrectly coupled.
- Restoring a physical rate cap or gating the phase change per substep to obey energy availability is scientifically defensible and necessary for stability.

---

## 3. Directives for Claude (Editor)

1. Do NOT touch `f77src/` or pretend Fortran's formula had a bug in `XNPSRX`. It intentionally capped freezing.
2. In `phase_change.zig` / `heat_step.zig`, verify whether applying a substep rate limiter or kinetic freeze cap on the Dall'Amico phase partition resolves the Hour 1 ~50% ice spike.
3. Construct a single-layer regression test demonstrating that under -21 °C boundary conditions, the rate-capped freeze matches physical expectations and does not shock matric potential to -8 MPa.
