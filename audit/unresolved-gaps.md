# Unresolved gaps (SENTINEL worklist)

Short index of what blocks the next gate. One line per item: ID, gate, owner role, blocker, evidence path.
Replace lines as items close; history lives in `audit/issues/` and `.agent/archive/`.
Open-issue census: `uv run ecosys-audit/scripts/issue_status.py --summary` (2026-09-25: 105 issue files;
43 open, 51 closed, 11 missing/unclear status, 13 need normalization; keyword classification, not a verdict).

## G0 (current)
- G0-1 | user | P0.1 park dirty work on local branch `wip/pre-plan-2026-09-25` | needs user approval
- G0-2 | PATHFINDER->SAGE->user | P0.2 D6: deck edits `9253d3b`, `5add7de`; Zig ceiling issue-015 | `audit/intentional-deviations.md` DEV-004..006
- G0-3 | PATHFINDER | P0.3 move legacy oracle binary + 30-yr outputs into `evidence/legacy/` with manifest | run-002:47 (scratchpad only, unhashed)
- G0-4 | PATHFINDER | P0.4 legacy -O2 timing x3 (after G0-2) | protocol in plan P0.4
- G0-5 | PATHFINDER | P0.5 `tracecov.py` stale-hash report (report, do not refresh) | issue-081
- G0-6 | PATHFINDER | P0.6 normalize issue Status lines | `issue_status.py` needs_normalization list

## Carried from the pre-plan loop (feed P3/P4, do not chase serially)
- issue-108 cations: Ca/Na/K layer-2 residuals at hour 3,289 | `audit/issues/issue-108-*.md`
- issue-106 test 71 substep ladder; issue-107 test 109 run-log lock spin | test-root failures (P3 item f)
- issue-099 PO4 band activation; issue-093 litter-carbon composition; issue-097 reference-doc import
