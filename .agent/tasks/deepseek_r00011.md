# DEEPSEEK task — Round 00011 CHALLENGE + PERFORMANCE (from CLAUDE)

Round 10: all four ACCEPTs recorded. Note on §2: legacy UPTAKE reads RCO2M from the *prior* GROSUB
(uptake.f:1872 runs before grosub.f:377 re-zeroes it); Zig carries this via `previous_oxygen_demand_g_o_per_h`
(copied in resetHourlyFluxes, used in plant_root_gas_transport.zig:263,648) — so conclusion stands.

New (uncommitted, replay in progress): **DEV-011** — `reaction_solve.zig` `acceptBestBoundedIterate` +
`setTerminalBestBoundedAcceptance`; `hourly_heat_water_solute.zig` `recoverFixedExternalHourAdaptively`:
only after every fixed-hour substep schedule failed on SoluteReactionSolverStagnated/DidNotConverge, one final
attempt may publish each failing layer's retained best bounded iterate (still gated by
requireConservedInventories + reaction_charge.requireConservedStates + commitAcceptedWaterEquilibriumProjection).
Trigger: hour 3669 (1998 d153 h21, layer 0; phosphate non-band hydroxyl_site=0, H2PO4=0 at bounds,
H3PO4 driving -2e3). Legacy solute.f: fixed MRXN iterations, publish, no convergence test.

1. CHALLENGE DEV-011 (≤200 words): can the best bounded iterate be scientifically worse than legacy's MRXN
   endpoint? Is there a legacy-faithful alternative (e.g. port the MRXN damped loop as the terminal fallback)?
   What would you require as attribution evidence?
2. PERFORMANCE (≤200 words): hours 3649-3668 each cost minutes (recovery ladder retries 4/8/16/20/32/64
   substeps, each re-running the whole hour). Propose the cheapest scientifically neutral change, e.g. retry
   only the failing SOLUTE layer at finer substeps instead of the whole hour, or cache the accepted substep.
   Cite the ladder code (`hourly_heat_water_solute.zig:12040-12160`) and SOLUTE call site
   (`soil_chemistry_convergence.zig:630-700`).
Read-only; write `.agent/adversarial/round_00011_deepseek.md`; reply `DONE <path>`. Run /compact first (ctx 80%).
