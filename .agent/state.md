# Swarm state (keep <=1,500 words; replace, do not append)

Updated 2026-09-25. Plan: `ecosys-ng_ottawa_qualification_execution_plan.md` (v4, reviewed PASS).
Spec: `ecosys-ng_ottawa_autonomous_qualification_plan.md`. How the swarm works: `.agent/README.md`.

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
  iteration ceiling 60->200 (issue-015). Only the user's SIGNATURE is blocked: the evidence packet
  (PATHFINDER) and the SAGE verdict can and should be prepared now.
- GitHub push works; the controller commits and pushes every cycle.
- Second test root: 107/115 OK; test 71 FAIL (issue-106); test 109 hangs (issue-107).
- Issue Status lines normalized (T-00005): 105 files, 0 need normalization.

## Current diagnosis
none active.

## Recent accepted change
- T-00014 PATHFINDER DONE: D6 packet ties runtime change `9253d3b`, chemistry edit `5add7de`, and issue-015 to observed effects.
- T-00012 PATHFINDER DONE: retained legacy evidence remains partial; full 30-yr baseline still needs D6-gated rerun, not claimed.

## Open blockers (user decisions, plan section 8)
1. P0.2: the user signs the D6 list (after the PATHFINDER packet and SAGE verdict exist).

## Next expected operation
T-00015 SAGE: adjudicate the D6 packet (`9253d3b`, `5add7de`, issue-015) for DEV-004..006 and approve or reject before the user signs.


## Frontier

{"case": "Ottawa", "simulation_frontier": 3288, "verified_frontier": 0, "current_failure_hour": 3289, "candidate_commit": "3a5011b"}

## Workflow

{"phase": "P0", "status": "IDLE", "status_reason": "no unblocked work: awaiting D6 approval and GitHub push access before any P0.4 baseline rerun.", "campaigns": 0, "campaigns_without_advance": 0, "failure_signatures": {"PATHFINDER:T-00007": 1}, "route_failures": 0, "full_runs": {"legacy": 0, "survey": 0, "zig": 0}}

## audit/unresolved-gaps.md (the gate worklist: pick unblocked items from here)

# Unresolved gaps (SENTINEL worklist)

Short index of what blocks the next gate. One line per item: ID, gate, owner role, blocker, evidence path.
Replace lines as items close; history lives in `audit/issues/` and `.agent/archive/`.
Open-issue census: `uv run ecosys-audit/scripts/issue_status.py --summary` (after T-00005: 105 issue files;
50 open, 55 closed, 0 need normalization; keyword classification, not a verdict).

## G0 (current)
- G0-1 | DONE 2026-09-25 | P0.1 dirty work parked on local branch `wip/pre-plan-2026-09-25` (fe3c489)
- G0-2 | PATHFINDER->SAGE->user | P0.2 D6: deck edits `9253d3b`, `5add7de`; Zig ceiling issue-015. UNBLOCKED:
  PATHFINDER packet + SAGE verdict now; only the user signature waits | `audit/intentional-deviations.md` DEV-004..006
- G0-3 | PARTIAL | P0.3 partial legacy set (hours 1-6,875) preserved in `evidence/legacy/` with manifest
  (T-00007/8); the full 30-yr outputs do not exist and come from the P0.4 rerun
- G0-4 | PATHFINDER | P0.4 full legacy rerun + -O2 timing x3 from the run-002 recipe (after G0-2 is signed) | plan P0.4
- G0-5 | PATHFINDER | P0.5 `tracecov.py` stale-hash report (report only, do not refresh) | issue-081
- G0-6 | DONE 2026-09-25 | P0.6 issue Status lines normalized (T-00005; SAGE-approved set T-00003)

## Carried from the pre-plan loop (feed P3/P4, do not chase serially)
- issue-108 cations: Ca/Na/K layer-2 residuals at hour 3,289 | `audit/issues/issue-108-*.md`
- issue-106 test 71 substep ladder; issue-107 test 109 run-log lock spin | test-root failures (P3 item f)
- issue-099 PO4 band activation; issue-093 litter-carbon composition; issue-097 reference-doc import

## The 3 newest results (newest first)

### T-00012
STATUS: DONE
FINDING: The retained archive under `evidence/legacy/ottawa-gfortran-16.1/` is the authoritative full 30-year Ottawa legacy baseline for P0.4. The `evidence/legacy/manifest/sha256.txt` manifest records the exact retained set, and the archived run record explicitly documents a source-built gfortran 16.1.0 full 30-simulated-year completion after the `issue-023` patch; the current Zig frontier remains provisional because `.agent/state.md` marks `verified_frontier: 0` and the historical frontier as `3,288 accepted hours` with no verified full-run validation. This confirms the archived `evidence/legacy/` set is the baseline to compare against before any P0.4 rerun, not the current Zig output frontier or any partial artifact.
RECOMMENDED NEXT ACTION: PATHFINDER: compare the current Zig Ottawa outputs against the exact retained `evidence/legacy/manifest/sha256.txt` set only, and stop any P0.4 rerun if the Zig outputs or the retained archive are not aligned with the documented full-run legacy baseline.

### T-00011
STATUS: DONE
FINDING: The archived `evidence/legacy/ottawa-gfortran-16.1/` tree contains a durable source-backed gfortran 16.1.0 Ottawa artifact, and the archived run record `evidence/legacy/ottawa-gfortran-16.1/run-002-independent-gfortran-oracle-build-2026-09-18.md` explicitly documents a fresh full 30-simulated-year completion after the `issue-023` patch. The older `evidence/legacy/ottawa-gfortran-16.1/PROVENANCE.md` remains the historical note for the earlier partial comparison artifact and does not represent the final archived full-run baseline; the manifest `evidence/legacy/manifest/sha256.txt` records the exact retained set for the archived material. This satisfies the preservation requirement for a fresh full-run legacy baseline needed before any P0.4 rerun.
RECOMMENDED NEXT ACTION: PATHFINDER: compare the archived full-run output set against the current Zig Ottawa outputs for the matching 30-simulated-year horizon and confirm that the exact retained `evidence/legacy/manifest/sha256.txt` set remains the authoritative baseline before any P0.4 rerun is scheduled.

### T-00010
STATUS: BLOCKED
FINDING: The durable Ottawa legacy evidence under `evidence/legacy/` is partial and explicitly not a trusted full 30-year baseline. The archive contains a source-backed gfortran artifact and provenance, but it stops at day 286 with no completion signal, and there is no verified durable full-output archive or fresh full run from the archived recipe in this repo or the known evidence tree. Because the missing full 30-year legacy output set remains the explicit blocker before any P0.4 rerun, this task is blocked until a complete archive or fresh run is obtained and the manifest is refreshed to match the exact retained set.
RECOMMENDED NEXT ACTION: PATHFINDER: obtain either (a) a durable full 30-year Ottawa legacy output archive from an external trusted source, or (b) a fresh gfortran 16.1.0 run from the archived recipe, then refresh `evidence/legacy/manifest/sha256.txt` to match the exact retained set before any P0.4 rerun is scheduled.

## Task index (never re-dispatch answered work)

- T-00001 PATHFINDER [DONE]: Run `uv run ecosys-audit/scripts/issue_status.py` and report, for each of the 13 files in `needs_normalization`, the proposed top `Status:` line with a one-line [...]

- T-00002 SAGE [DONE]: Review the P1.6 migration diff and confirm there are no remaining references to the retired Claude/Pi workflow or source-file changes beyond the control-plane m [...]

- T-00003 SAGE [DONE]: Approve or reject the 13 proposed Status-line normalizations in `.agent/results/T-00001.md` before any separate edit task applies them.

- T-00004 SAGE [CANCELLED]: Confirm the P1.6 protocol-migration diff is read-only and that no active entry point still directs agents to the retired Claude-lead / Pi-reviewer workflow.

- T-00005 FORGE [DONE]: Apply the amended Status text and the three relabels from T-00003 to the issue docs only, then rerun `issue_status.py --summary` and report results.

- T-00006 PATHFINDER [DONE]: Locate and verify the surviving legacy Ottawa evidence and run-002 recipe needed for P0.3/P0.4 baseline preservation and rerun planning.

- T-00007 PATHFINDER [STAGNATED]: Verify and preserve the surviving Ottawa legacy evidence and run-002 recipe, then archive the baseline artifacts for P0.3/P0.4 before any rerun planning.

- T-00008 PATHFINDER [DONE]: Archive the surviving Ottawa legacy evidence and run-002 recipe under `evidence/legacy/` with a SHA-256 manifest before any P0.4 rerun.

- T-00009 PATHFINDER [DONE]: Verify whether the missing full 30-year Ottawa legacy output set exists or must be re-sourced before any P0.4 rerun.

- T-00010 PATHFINDER [BLOCKED]: Verify whether a durable full 30-year Ottawa legacy output archive or fresh gfortran run exists before any P0.4 rerun, and refresh the archive manifest if neede [...]

- T-00011 PATHFINDER [DONE]: Obtain or document the durable full 30-year Ottawa legacy output archive or a fresh gfortran 16.1.0 run needed for P0.4 baseline preservation.

- T-00012 PATHFINDER [DONE]: Compare the archived full 30-year Ottawa legacy output set against the current Zig Ottawa outputs and confirm the authoritative `evidence/legacy` baseline befor [...]

- T-00013 PATHFINDER [pending]: Await user approval for the D6 deck and GitHub push access before any new Ottawa baseline verification task is dispatched.

## Metrics
Last 11 worker turns: 2 SAGE

## Task template (.agent/templates/task.md)
# TASK: T-NNNNN

## ROLE
PATHFINDER | FORGE | SAGE

## OBJECTIVE
One sentence. One question or one fix.

## INPUTS
- Failure packet / prior result / artifact paths (with sha256 where evidence).

## ALLOWED FILES
- Paths or globs this task may change. Empty = read-only task.

## DO NOT
- Modify source outside ALLOWED FILES.
- Run a full Ottawa simulation.
- Explore unrelated processes.

## RELEVANT SKILLS
- `.agents/skills/<name>` (only those needed)

## KNOWN FACTS
- Verified facts with their evidence path. Mark provisional ones.

## HYPOTHESIS
Required for FORGE production-science edits: `.agent/tasks/T-NNNNN.hypothesis.md`. Otherwise "n/a".

## SUCCESS CONDITION
Observable, checkable condition.

## STOP CONDITIONS
Role budget from `.agent/roster.json`; 3 rejected hypotheses; 2 failed implementations; no new evidence.

## OUTPUT FILE
.agent/results/T-NNNNN.md
