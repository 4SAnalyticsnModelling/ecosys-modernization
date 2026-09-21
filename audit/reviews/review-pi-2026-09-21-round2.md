# Review Round 2: Attempt to Falsify Unconstrained Dall'Amico Equilibrium Commit in ecosys-ng

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Author/Editor: Claude (claude-opus-5)  
Subject: Audit of claim that no post-solve or solver-ladder rate limiter constrains the top soil layer phase split.

---

## Verdict

**NOT FALSIFIED**: Searched solver commit pipelines, retry ladders, pore occupancy post-passes, and stage boundary handoffs. No code path in `ecosys-ng` constrains the rate or amount of liquid-to-ice phase conversion for the top soil layer once a temperature is evaluated by the enthalpy solver.

---

## Key Findings & Provenance

1. **Direct Commit via `publishValidatedMatrixPhaseUpdate`**:
   - `ecosys-ng/src/soil/heat/solver_solve.zig:676` calls `group_residual.publishValidatedMatrixPhaseUpdate(grid, phase_buffers)`.
   - `ecosys-ng/src/soil/heat/solver_residual.zig:642-700` copies `phase_buffers.matrix_liquid_m3` and `phase_buffers.matrix_ice_m3` directly into `grid.matrix_liquid_water_m3` and `grid.matrix_ice_water_m3` via raw `@memcpy`.
   - No rate-limiting, relaxation factor, or substep attenuation is applied during commit.

2. **Phase Buffers Origin**:
   - `ecosys-ng/src/soil/heat/solver_residual.zig:145-168` updates `phase_buffers` directly from `trialState(...)`, which calls `enthalpy.stateAtTemperature(parameters, trial[cell])`.
   - `ecosys-ng/src/soil/water/enthalpy_balance.zig:107-150` evaluates `phase_change.dallAmicoEquilibrium` without any kinetic rate cap or time-fraction limiting.

3. **Substep Retry Ladder Does Not Cap Equilibrium**:
   - `ecosys-ng/src/soil/water/heat_step.zig:805-820` contains `HeatInducedPhaseChangeRequiresQuarterHourSubsteps`.
   - This only forces schedule subdivision (`substep_count >= 4`) when ice changes at `substep_count < 4`.
   - Within each 15-minute substep, the solve still computes and commits full unconstrained thermodynamic equilibrium.

4. **Post-Commit Displacement Only Moves Excess Volume**:
   - The only post-phase adjustment is mechanical pore-overfill displacement (`addPhaseDisplacement` / pore expansion), which manages geometric space (`matrix_air`), not phase partitioning.

---

## Conclusion

The claim holds: `ecosys-ng` unconditionally commits unconstrained Dall'Amico equilibrium for the top soil layer without the legacy `watsub.f:2802-2823` kinetic limits (`XNPR=1/30`, `XNPSRX=1/(NPH*200)`).
