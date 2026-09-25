# Swarm state (keep <=1,500 words; replace, do not append)

Updated 2026-09-25. Plan: `ecosys-ng_ottawa_qualification_execution_plan.md` (v4, reviewed PASS).
Spec: `ecosys-ng_ottawa_autonomous_qualification_plan.md`. How the swarm works: `.agent/README.md`.

## Current objective
Phase P0 (freeze, adjudicate inputs, baseline; exit gate G0).

## Current candidate commit
`3a5011b` on `main` (clean tree). `fe3c489` = pre-plan work parked (P0.1 DONE, user-approved 2026-09-25;
branch `wip/pre-plan-2026-09-25`, local only). The 3 Zig stage edits of the old issue-108 work are in
`fe3c489`, unreviewed.

## Verified frontier
0 under the plan's evidence binding. Historical simulation frontier: 3,288 accepted hours of 262,920
(run-038, required deck). Provisional until re-verified.

## Current failure
Historical: hour 3,289, HourlyCellConservationFailure, Ca/Na/K positive residuals in layer 2
(issue-108 cation half). Not being chased serially; feeds P3/P4.

## Confirmed facts
- The full 30-yr legacy output (run-002) lived only in an old session scratchpad and was not found on
  2026-09-25. A partial gfortran legacy output set (hours 1-6,875) survives in a temp directory:
  `C:\Users\symon.mezbahuddin\scoop\apps\msys2\2025-02-21\tmp\claude\agentJ-base\validation\legacy_ottawa_gfortran_16_1\`
  (with `PROVENANCE.md`; temp = at risk). P0.3 must preserve it into `evidence/legacy/` with a manifest;
  P0.4 must rebuild/rerun legacy from the run-002 recipe.
- Deck edits `9253d3b` (runtime ceiling 100->200) and `5add7de` (starte.f:189) plus the Zig solute
  iteration ceiling 60->200 (issue-015) await D6 adjudication (P0.2; user signs).
- Second test root: 107/115 OK; test 71 FAIL (issue-106); test 109 hangs (issue-107).
- Issue census 2026-09-25 (`issue_status.py --summary`): 105 files; 13 need Status normalization.

## Current diagnosis
none active.

## Recent accepted change
Control plane installed and the Claude-lead / Pi-reviewer workflow retired (`3a5011b`).
SAGE review of that migration diff is pending (`audit/workflow/p1.6-protocol-migration-inventory.md`).

## Open blockers (user decisions, plan section 8)
1. P0.2: sign the D6 list.
2. GP1: launch approval (`swarm_wrapper.py approve`), after the supervised trial turn.
3. D8 push policy (default: never push).

## Supervised trial (2026-09-25) -- PASSED
T-00001 (P0.6 proposal): SENTINEL routed it in 52 s with a valid dispatch. PATHFINDER finished in 64 s and wrote
only its result; 4/4 spot-checked quotes are verbatim. Reset verified. Live permission probes: PATHFINDER's
disallowed write was DENIED, and SENTINEL's bash was DENIED. Observed: SENTINEL used ~13 tool calls (budget 8;
only time is enforced); its dispatch listed a skill its task said "none".

## Next expected operation
SAGE reviews the P1.6 migration diff (`git show 3a5011b`, plus `audit/workflow/p1.6-protocol-migration-inventory.md`):
confirm no `ecosys-ng/src` or reference file changed, and that no active entry point still directs
agents to the retired workflow. Skill: `ecosys-process-science-parity`. Then T-00001's 13 proposed Status
lines need SAGE or user approval before a separate edit task applies them.
