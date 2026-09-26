# Swarm state (keep <=1,500 words; replace, do not append)

Updated 2026-09-25. Plan: `ecosys-ng_ottawa_qualification_execution_plan.md` (v4, reviewed PASS).
Spec: `ecosys-ng_ottawa_autonomous_qualification_plan.md`. How the swarm works: `.agent/README.md`.
The controller writes "Recent accepted change" and "Next expected operation" from SENTINEL's dispatch.

## Current objective
Phase P0 (freeze, adjudicate inputs, baseline; exit gate G0).

## Current candidate commit
`main` (clean tree, pushed every cycle). `fe3c489` = pre-plan work parked (P0.1 DONE, user-approved
2026-09-25; branch `wip/pre-plan-2026-09-25`). The 3 Zig stage edits of the old issue-108 work are in
`fe3c489`, unreviewed.

## Verified frontier
0 under the plan's evidence binding. Historical simulation frontier: 3,288 accepted hours of 262,920
(run-038, required deck). Provisional until re-verified.

## Current failure
Historical: hour 3,289, HourlyCellConservationFailure, Ca/Na/K positive residuals in layer 2
(issue-108 cation half). Not being chased serially; feeds P3/P4.

## Confirmed facts
- Legacy baseline (P0.3), verified by file count 2026-09-25: `evidence/legacy/` holds the PARTIAL legacy
  Ottawa output set (hours 1-6,875 / day 286; 199 files, 110 MB; manifest `evidence/legacy/manifest/sha256.txt`)
  plus the rebuilt source and a copy of the run-002 write-up. The full 30-yr output (run-002: 1,138 files,
  1.33 GB) is NOT in the repo. The run-002 document describes a past run; it is not the outputs.
  CORRECTION: the T-00011/T-00012 findings calling this "the authoritative full 30-year baseline" are wrong.
  P0.4 needs a full legacy rerun from the run-002 recipe, which waits only on D6 (the deck).
- D6: deck edits `9253d3b` (runtime ceiling 100->200) and `5add7de` (starte.f:189) plus the Zig solute
  iteration ceiling 60->200 (issue-015). The PATHFINDER packet exists (T-00014). Next: the SAGE verdict.
  Only the user's SIGNATURE is blocked.
- GitHub push works; the controller commits and pushes every cycle.
- Second test root: 107/115 OK; test 71 FAIL (issue-106); test 109 hangs (issue-107).
- Issue Status lines normalized (T-00005): 105 files, 0 need normalization.

## Current diagnosis
none active.

## Recent accepted change
- T-00024 SAGE DONE: DEV-005 is legacy parity; only DEV-004 remains open.
- T-00023 FORGE DONE: bounded compare isolates chemistry from the water stall.
- T-00022 PATHFINDER DONE: matrix-water direct cause remains, not the ammonium multiplier.

## Open blockers (user decisions, plan section 8)
1. P0.2: the user signs the D6 list (after the SAGE verdict exists).

## Next expected operation
PATHFINDER: locate the legacy runtime ceiling and first divergence hour for DEV-004 in preserved outputs.
