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
  iteration ceiling 60->200 (issue-015). The PATHFINDER packet exists (T-00014). DEV-005 = legacy parity
  (T-00024). DEV-004+DEV-006 are one deviation (merge decided 2026-09-25) and SAGE rejected it as
  legacy-equivalent (T-00030). By decision D9, SAGE signs the D6 list; no user signature exists or is needed.
- D9 (user, 2026-09-25): SAGE makes every decision; the swarm never waits for a human (plan section 8).
- GitHub push works; the controller commits and pushes every cycle.
- Second test root: 107/115 OK; test 71 FAIL (issue-106); test 109 hangs (issue-107).
- Issue Status lines normalized (T-00005): 105 files, 0 need normalization.

## Current diagnosis
none active.

## Recent accepted change
- T-00031 FORGE DONE: DEV-004 row updated.
- T-00030 SAGE DONE: hour-9 divergence verified.

## Open blockers
None waiting on a person (D9). P0.2 closes when SAGE signs the D6 list under the D6 rule.

## Next expected operation
PATHFINDER to identify Ottawa deck NPH/NPG and the first divergent preserved n100e/n100f output hour.
