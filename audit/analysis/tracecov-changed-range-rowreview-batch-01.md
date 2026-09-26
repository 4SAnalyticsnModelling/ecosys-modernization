# Tracecov CHANGED-RANGE row review, batch 01 (2026-09-26)

This batch covers the heat_step + solver_residual rows called out in T-00096 as the first required re-check before any ledger refresh.

## Batch scope
- `TRC-088` — `ecosys-ng/src/soil/water/heat_step.zig`
- `TRC-220` — `ecosys-ng/src/soil/water/solver_residual.zig`
- `TRC-293` — `ecosys-ng/src/soil/water/solver_residual.zig`

## Current mapping review

| unit_id | current zig_lines | mapping status | moved/broken | one-line note |
| --- | --- | --- | --- | --- |
| TRC-088 | `ecosys-ng/src/soil/water/heat_step.zig:513;808;1014` | MOVED | range moved | The live code is now anchored at the recovery schedule constant and sibling downstream heat/phase control code; the older cited region does not match the current implementation location. |
| TRC-220 | `ecosys-ng/src/soil/water/solver_residual.zig:486-535` | MOVED | range moved | The matrix/macropore discharge-eligibility block has shifted down from the old `422-471` range; this is a real line movement, not a no-op stale hash. |
| TRC-293 | `ecosys-ng/src/soil/water/solver_residual.zig:486-535` | MOVED | range moved | Same current source block as TRC-220, so the stale ledger citation would still describe the wrong lines even if the hash were refreshed. |

## Evidence basis
- `ecosys-ng/src/soil/water/heat_step.zig:513` contains `pub const recovery_substep_counts = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64 };`.
- `ecosys-ng/src/soil/water/solver_residual.zig:486-535` contains the active `matrix_discharge_enabled` / `IFLGU/IFLGD` logic for natural/artificial water-table discharge eligibility.
- `audit/analysis/tracecov-stale-revalidation-2026-09-26.md` records the same stale-row set and keeps the 62 CHANGED-RANGE rows distinct from the 7 UNCHANGED-RANGE and 64 NO-MATCHING-BLOB rows.

## Conclusion
The review pattern is consistent: the current CHANGED-RANGE rows are still live code, but the cited `zig_lines` are stale because the function blocks moved. A hash-only refresh would make stale citations appear current; the ledger must not be rewritten without a paired `zig_lines` + `zig_sha256` update.
