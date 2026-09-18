# Issue 013 -- stage_execution_census.zig mischaracterizes root_uptake_geometry as inside a parallel kernel (it is not)

Status: **OPEN, but trivial/non-blocking** -- this is an audit-instrumentation metadata bug, not a science gap. No output/physics impact.

Owner: found and independently verified by this session's audit forks, 2026-09-18 (two separate passes: one flagged it as a candidate, a follow-up pass confirmed the census's own stated reason is factually wrong).

## What's wrong

`ecosys-ng/src/validation/stage_execution_census.zig` lists the `root_uptake_geometry` stage under `uninstrumented_reason.inside_a_parallel_tile_kernel`, with commentary arguing it "cannot be recorded without either an atomic counter or a per-worker census reduced after the join" because it allegedly runs "per cell/layer/plant inside the parallel water-balance kernel."

**This premise is false.** `rootUptakeGeometry` (`ecosys-ng/src/plant/root/water_balance.zig:459`) is called at `water_balance.zig:317`, inside `refreshRootWorkspace` (`:220-349`) -- an ordinary serial nested loop, not passed to any executor, not given a cell/tile-range argument. `refreshRootWorkspace` has exactly one production caller in the entire tree: `ecosys-ng/src/stages/hourly_snow_energy.zig:615`, inside `advanceLivingCanopyAfterWatsub`, called directly and sequentially **before** the actual parallel dispatch at `:649-653` (`runIndexedKernelAcrossSerialTiles(..., solveLivingCanopyCells)`). The per-cell kernel that IS dispatched in parallel only reads the already-populated conductance values; it never calls `rootUptakeGeometry`.

`context.stage_census` is already in scope at the exact call site (`hourly_snow_energy.zig:615-616`, used two lines later at `:274` inside the same function for a different stage). Adding `context.stage_census.*.recordCurrent(.root_uptake_geometry);` right after line 615/616 requires zero atomics and zero per-worker reduction -- the obstacle the comment cites does not exist for this call site.

## Secondary finding

`refreshRootWorkspace`'s own gate (`:296-298`: `root_length_density>0`, `primary/secondary_axis_count>0`, `rooted_fraction>0`, `matrix_liquid_water>0`, `matrix_volume>0`, `conductivity>0`) already excludes the inputs that `rootUptakeGeometry`'s internal fallback branch (`:472-476`) handles -- so that fallback is unreachable from the one production call site and is currently exercised only by unit tests (`:1065-1070`). Not itself a defect (a defensive branch for an input combination the caller happens to always avoid), but worth knowing if anyone later refactors the caller's gate.

## Why this matters (a little) and why it's not urgent (mostly)

This is exactly the kind of "declaration vs. measurement" staleness this project's own history warns about (see `issue-010`'s correction and the `docs/GOAL.md` reference project's own note about the discrepancy register's self-declared-open rate). A future audit pass or a human reading the census output could be misled into thinking `root_uptake_geometry`'s execution status is genuinely unknown/unprovable, when it is both provable (see `feature-004`'s updated writeup) and trivially instrumentable. It does not affect any output, physics, or conservation -- purely a metadata/documentation accuracy issue in the audit tooling itself.

## Recommended fix (not applied this session -- flagged, not executed, since it touches validation/census code rather than a pure comment)

1. Add `context.stage_census.*.recordCurrent(.root_uptake_geometry);` at `hourly_snow_energy.zig` right after the `refreshRootWorkspace`/`refreshActive` calls (`:615-616`).
2. Move `root_uptake_geometry` out of `uninstrumented_reason.inside_a_parallel_tile_kernel` in `stage_execution_census.zig` once the recording call is live and verified by a fresh census run.
3. Correct the surrounding comment text to stop claiming a parallel-kernel obstacle that doesn't exist for this stage.

## Evidence

`D:\ecosys-modernization\ecosys-ng\src\validation\stage_execution_census.zig` (claim); `D:\ecosys-modernization\ecosys-ng\src\plant\root\water_balance.zig:220-349,459,472-476,1065-1070`; `D:\ecosys-modernization\ecosys-ng\src\stages\hourly_snow_energy.zig:615-616,649-653,108,273-274`.
