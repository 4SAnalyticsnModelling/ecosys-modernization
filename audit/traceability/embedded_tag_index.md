# Embedded source-comment tag index (ecosys-ng/src)

Generated 2026-09-18 by one `Grep` sweep over `ecosys-ng/src` for the pattern `` `[A-Z][A-Z0-9-]{5,45}-[0-9]{3}` `` (backtick-quoted, all-caps-with-hyphens, ending in a 3-digit number). This is a discovery index, not a completed audit: "READ" means this session read the surrounding comment and recorded a finding elsewhere; "NOT YET READ" means only the citation site (file:line) is known -- do not assume severity, status, or content from the tag name alone. 32 distinct tags, 66 citation occurrences, found in one pass; a second pass with a looser pattern (e.g. allowing lowercase, `docs/`-prefixed IDs, or IDs not ending in a 3-digit suffix like `BIND-GROSUB-506`-style four-digit ones) might find more.

Several tags cite `docs/discrepancy_register.md` as their authoritative record; that file does not exist in this checkout (see `audit/issues/issue-005-missing-validation-index-dirs-CRITICAL.md`, fifth data point) -- so for those, this index and any linked `audit/issues/` entry is currently the *only* available record, not a duplicate of a fuller one.

| Tag | Citation sites (file:line) | Status this session |
|---|---|---|
| `DALLAMICO-BELOW-RESIDUAL-WATER-HOUR-2726-001` | `soil/water/phase_change.zig:92` | READ -- see `audit/features/feature-001-dallamico-freeze-thaw.md` |
| `SOIL-HCOND-AXIS-ISOTROPY-001` | `soil/water/solver_hydraulics.zig:34,60,189`; `soil/water/solver_properties.zig:47,240,591`; `soil/water/solver_types.zig:65,72`; `soil/water/solver_tests.zig:774` | READ -- see `audit/features/feature-002-mualem-van-genuchten.md` |
| `PR-COND-TABLE-001` | `soil/water/solver_properties.zig:107,261` | READ -- see `audit/features/feature-002-mualem-van-genuchten.md` |
| `GAS-STATE-UPDATE-DEAD-001` | `soil/biogeochemistry/transformation_aggregation.zig:185` | READ -- see `audit/issues/issue-006-embedded-tag-findings-batch1.md`; dead code, zero production callers |
| `MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001` | `soil/microbial/state.zig:98`; `soil/nutrients/nitrogen_state_update.zig:583` | READ + independently verified against `f77src/nitro.f` lines 2094/2532/3824/3832 -- see issue-006 |
| `SURFACE-HEAT-BRACKET-RUNAWAY-001` | `soil/heat/solver_types.zig:128`; `soil/heat/solver_tests.zig:719,840`; `soil/heat/solver_solve.zig:4889` | READ (partial, the `solver_types.zig` framing comment only) -- see issue-006 |
| `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001` | `soil/heat/flux.zig:60`; `soil/heat/solver_residual.zig:251,799`; `soil/water/heat_step.zig:3278`; `surface/temperature_solver.zig:744`; `stages/hourly_heat_water_solute.zig:12139` | READ (the fullest citation, `hourly_heat_water_solute.zig:12139-12160`) -- see issue-006; **live, unresolved, in-progress diagnostic**, not closed |
| `NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001` | not yet located (named only as a sibling of `GAS-STATE-UPDATE-DEAD-001`) | NOT YET FOUND -- search did not match this session's tag regex (likely a longer ID); worth a dedicated `Grep` for `NITRIFICATION-DENITRIFICATION` |
| `PLANT-ACCLIM-MODE2-001` | `io/input/climate_change.zig:84` | NOT YET READ |
| `DISC-NITRO-001` | `stages/biogeochemistry_batches.zig:38` | NOT YET READ |
| `BIND-GROSUB-506` | `io/checkpoint/plant_root_checkpoint.zig:18,499` | NOT YET READ (note: no leading category before the number here -- may belong to a different, GROSUB.f-referencing binding-tag family) |
| `EXEC-O2-BALANCE-007` | `plant/root/plant_root_gas_transport.zig:498` | NOT YET READ |
| `UPTAKE-003` | `canopy/photosynthesis/carboxylation.zig:212` | NOT YET READ |
| `CANOPY-STOMATE-RSMN-WATER-STRESS-001` | `canopy/photosynthesis/carboxylation.zig:213` | NOT YET READ |
| `PR-GRID-INV-001` | `soil/water/boundary_dimension_tests.zig:128` | NOT YET READ |
| `GRID-INV-001` | `soil/water/boundary.zig:55,95,129`; `soil/water/solver_residual.zig:448` | NOT YET READ |
| `GRID-INV-002` | `soil/water/boundary.zig:72` | NOT YET READ |
| `GRID-INV-003` | `soil/runtime/hourly_workspace.zig:202` | NOT YET READ |
| `MASS-BALANCE-HEAT-FLOOR-DECK-EDIT-001` | `stages/hourly_heat_water_solute.zig:56` | NOT YET READ |
| `SURFACE-HEAT-PONDED-LITTER-BOOKING-001` | `stages/hourly_heat_water_solute.zig:5643,5679`; `stages/diagnostics.zig:15`; `soil/water/snowpack_litter_heat_water_transfer.zig:50,184` | NOT YET READ |
| `LITTER-ICE-PORE-DOMAIN-001` | `surface/litter_geometry.zig:116` | NOT YET READ |
| `SURFACE-HEAT-CAPACITY-STALE-WITHIN-HOUR-001` | `surface/litter_geometry.zig:126` | NOT YET READ |
| `LITTER-RETENTION-THETWR-001` | `surface/litter_geometry.zig:216`; `redistribution/tillage/runtime_adapter.zig:897` | NOT YET READ |
| `SOLUTE-013` | `surface/litter_reaction_rates.zig:1439` | NOT YET READ |
| `CANOPY-TKC-001` | `canopy/energy/stomatal_call_boundary.zig:11`; `canopy/energy/temperature_stress.zig:20` | NOT YET READ |
| `TRNSFRS-DLYRM-001` | `soil/solute/face_parameters.zig:145` | NOT YET READ |
| `PERF-REACTION-SPAN-CLOSED-FORM-001` | `soil/solute/conservative_reaction_span.zig:60`; `soil/solute/reaction_solver_reaction_span.zig:339,402,432,536,768` | NOT YET READ -- name suggests a performance/refactor note (closed-form vs. iterative), not necessarily a correctness defect |
| `SOIL-PORE-GUARD-TESTSCALE-001` | `soil/water/phase_solver.zig:1913` | NOT YET READ |
| `SOIL-THETY-001` | `soil/gas/air_porosity_dry_end_water.zig:23` | NOT YET READ |
| `SOIL-HUMPART-001` | `soil/organic/initialization.zig:333,585` | NOT YET READ |
| `TILLAGE-ORGANIC-MIRROR-OWNER-001` | `redistribution/tillage/runtime_adapter.zig:322` | NOT YET READ |
| `SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001` | `soil/solute/reaction_solver_evaluate.zig:239` | NOT YET READ |
| `SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001` | `soil/water/solver_tests.zig:994` | READ -- **not** a live dead-code case despite the name pattern. Comment reads "(removed: `SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001`)": a precomputed macropore face-conductance mechanism was already removed and replaced by runtime Mualem-van-Genuchten parameters + CNDH-derived Ksat controlling the (donor-bounded) macropore flux branch. This tag documents a completed past removal, not an open issue -- correcting this session's own prior guess that `DEAD`-named tags are necessarily still-open dead code. |

## Suggested reading order for whoever continues this sweep
Names containing `DEAD`, `RUNAWAY`, `OVERDRAW`, `STALE`, or `UNPHYSICAL` read as likely correctness/safety issues (`SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001` first, given the pattern match to the already-confirmed `GAS-STATE-UPDATE-DEAD-001`). Names containing `PERF` read as performance/refactor notes, lower priority for the correctness audit. Everything else is unclassified until read.
