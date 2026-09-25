# Swarm state (keep <=1,500 words; replace, do not append)

Updated 2026-09-25 when the control plane was installed. Plan: `ecosys-ng_ottawa_qualification_execution_plan.md`
(v4, reviewed PASS). Spec: `ecosys-ng_ottawa_autonomous_qualification_plan.md`.

## Current objective
Phase P0 (freeze, adjudicate inputs, baseline; exit gate G0). First the user decisions below.

## Current candidate commit
`fd07795` on `main`, with a large dirty working tree (tracked edits to 3 Zig stage files,
skills and docs; many untracked audit records). Not yet parked (P0.1).

## Verified frontier
0 under the plan's evidence binding. Historical simulation frontier: 3,288 accepted hours of 262,920
(run-038, required deck). Provisional until P0 re-verifies.

## Current failure
Historical: hour 3,289, HourlyCellConservationFailure, Ca/Na/K positive residuals in layer 2
(issue-108 cation half). Carbon half fixed (`fd07795`).

## Confirmed facts
- Legacy oracle binary and 30-yr output exist only in a session scratchpad and are not hashed (run-002).
  P0.3 moves them into `evidence/legacy/` with a manifest.
- Deck edits `9253d3b` (runtime ceiling 100->200) and `5add7de` (starte.f:189) plus the Zig solute
  iteration ceiling 60->200 (issue-015) await D6 adjudication (P0.2).
- Second test root: 107/115 OK; test 71 FAIL (issue-106); test 109 hangs (issue-107).

## Current diagnosis
none active in the swarm.

## Recent accepted change
Control plane installed: `.agent/`, `evidence/`, `validation/`, `ecosys-audit/scripts/swarm_wrapper.py`,
`divcheck.py`, `make_failure_packet.py`, `update_frontier.py`, `evidence_binding.py`, `issue_status.py`.
Evidence lives in `evidence/` inside this repository (git-ignored; manifests committed).
The plan's `D:\ecosys-evidence\` paths map to `evidence/` (user: the repository must be standalone).

The former Claude-lead / Pi-reviewer workflow was retired and archived on 2026-09-25
(`archive/pre-swarm-workflow/`; `audit/workflow/p1.6-protocol-migration-inventory.md`). SAGE review of that
migration diff is pending.

## Open blockers (user decisions, plan section 8)
1. P0.1: park dirty work on local branch `wip/pre-plan-2026-09-25` (no push).
2. P0.2: sign the D6 list.
3. GP1: launch approval (`.agent/workflow.json` `autonomy_approved`), after the P1.5 wrapper suite passes.
4. D8 push policy (default: never push).

## Next expected operation
After the user approves P0.1: SENTINEL routes P0.2 (PATHFINDER packet on the D6 deck edits -> SAGE verdict).
