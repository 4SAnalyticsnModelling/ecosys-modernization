# Unresolved gaps (SENTINEL worklist)

Short index of what blocks the next gate. One line per item: ID, gate, owner role, blocker, evidence path.
Replace lines as items close; history lives in `audit/issues/` and `.agent/archive/`.
Open-issue census: `uv run ecosys-audit/scripts/issue_status.py --summary` (after T-00005: 105 issue files;
50 open, 55 closed, 0 need normalization; keyword classification, not a verdict).

## G0 (current)
- G0-1 | DONE 2026-09-25 | P0.1 dirty work parked on local branch `wip/pre-plan-2026-09-25` (fe3c489)
- G0-2 | DECIDED 2026-09-26 T-00078 | P0.2 D6 list SIGNED-SAGE (D9): DEV-005 KEEP (legacy parity), DEV-004/006
  REVERT (confirmed T-00036), DEV-007 REVERT-decouple (done T-00046/49), DEV-008 ACCEPTED (T-00076). Only the
  deck-half revert of `9253d3b` (G0-2a) remains to implement | `audit/intentional-deviations.md` DEV-004..008
- G0-2a | FORGE (deck-half open) | Zig half reverted T-00037/T-00038; deck `runottawa` still f6=200, restore blob
  `ecf5e61a…` with SAGE diff-bound review. Earlier: T-00035 D6 decision on DEV-004: REJECTED-REVERT (revert deck f6 200->100 and
  `iteration_control.zig:150` 200->100 of `9253d3b`; hour-2,589 SOLUTE exhaustion becomes a defect to root-cause).
  The STARTE clamp is now listed as DEV-007 and decided in T-00045: decouple SOLUTE/STARTE ceilings from f6 (FORGE) | `.agent/results/T-00035.md`, `.agent/results/T-00045.md`
- G0-2b | PATHFINDER->SAGE | Legacy MRXN semantics not reproduced by any Zig ceiling: per-sub-cycle kinetic rates /MRXN
  (`solute.f:112-118,368-402`) vs Zig single closure with relaxation caps unbounded (`reaction_solve.zig:73-129`), and
  hourly rain/irrigation input equilibration using the STARTE ceiling (`hourly_process_driver.zig:634,670`) needs its
  legacy counterpart identified. Unlisted; not a D6 approval | `.agent/results/T-00044.md`, `.agent/results/T-00045.md`
  T-00078: moved OUT of the G0 gate to P3 (Ottawa-path science audit) together with the hour-2,589 SOLUTE exhaustion
  root-cause; D6 requires the revert for G0, the root-cause is P3 science work. Wet-hour input path superseded by DEV-008.
- G0-2c | DONE 2026-09-26 (DEV-008 ACCEPTED T-00075/T-00076) | DEV-008 fixed-pH STARTE dynamic-input revision (T-00060) exists as uncommitted working-tree
  diff (diff-hash 53175e5b...2618) but its FORGE result was lost; T-00063 decided: no re-implementation (T-00061/62
  superseded), SAGE reviews the diff directly with the quarantined claims copy | `.agent/results/T-00063.md`
- G0-3 | PARTIAL | P0.3 partial legacy set (hours 1-6,875) preserved in `evidence/legacy/` with manifest
  (T-00007/8); the full 30-yr outputs do not exist and come from the P0.4 rerun
- G0-4 | PATHFINDER | P0.4 full legacy rerun + -O2 timing x3 from the run-002 recipe (after G0-2 is signed) | plan P0.4
  T-00078: UNBLOCKED. G0-2 is signed, and no D6 item changes legacy inputs (legacy reads no runtime f6, `reads.f:126`
  per T-00045; legacy hardcodes `CN4X=0.1*CNH4` at `starte.f:189`), so the legacy rerun need not wait for G0-2a
- G0-5 | PATHFINDER | P0.5 `tracecov.py` stale-hash report (report only, do not refresh) | issue-081
- G0-6 | DONE 2026-09-25 | P0.6 issue Status lines normalized (T-00005; SAGE-approved set T-00003)

## Carried from the pre-plan loop (feed P3/P4, do not chase serially)
- issue-108 cations: Ca/Na/K layer-2 residuals at hour 3,289 | `audit/issues/issue-108-*.md`
- issue-106 test 71 substep ladder; issue-107 test 109 run-log lock spin | test-root failures (P3 item f)
- issue-099 PO4 band activation; issue-093 litter-carbon composition; issue-097 reference-doc import
