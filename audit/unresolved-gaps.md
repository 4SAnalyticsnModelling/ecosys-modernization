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
