# Workflow-002: listing audit/handoff.md as sealed evidence makes `workflow.py close` unsatisfiable

Date: 2026-09-23. Scope: orchestration infrastructure only. No science, gate or source impact.
Status: **FIXED with offline regressions (2026-09-23, user-authorised)**; see "Fix" below. Earlier status, retained: OPEN / BLOCKING closure of task `20260923-184059-9b086122` (issue-101 regression; Pi review PASS, no findings).

## Observed

`uv run ecosys-audit/scripts/workflow.py close` -> exit 2:
`{"error": "Stale artifact: {'path': 'audit/handoff.md', 'sha256': '20b474e26df9cc4f2f512b8dfcd2a60f1e8096a1979d5a54f89625dd7e75035e'}", "status": "BLOCKED"}`

## Cause (read from `ecosys-audit/scripts/workflow.py`)

- The editor result for this task listed `audit/handoff.md` in `evidence`; `seal` hashed it into `packet-1.json` `artifacts` (sha 20b474e2..., bytes preserved at `audit/history/handoff-20b474e2...md`).
- `close()` (`:412-433`) calls `verify_artifacts(root, p["artifacts"])` (`:421`), requiring every packet artifact, including the handoff, to be byte-identical to seal time.
- `close()` also requires the live handoff to contain the review path (`:427`), which does not exist until after review, so the handoff must change after seal.
- No transition returns `finalizing` to `editing` (`seal` requires `editing`, `:301`), so the packet cannot be resealed without the handoff.

The two conditions cannot both hold. This was an editor mistake (the handoff is mutable by design and is already recorded separately by `seal` at `:324`), exposed by a missing guard.

## State preserved

Phase `finalizing`; packet `audit/tasks/20260923-184059-9b086122/packet-1.json` (1638515d...); review `audit/reviews/20260923-184059-9b086122-r1.json` PASS; live handoff 52128c22... names the task and review path. No reviewed source edited; no closure receipt fabricated; `workflow.py` not modified.

## Needed decision (user / infrastructure task)

Proposed fix, not applied: (1) `seal` rejects `audit/handoff.md` (and `audit/workflow/`) as evidence; (2) `close` exempts `audit/handoff.md` from the packet-artifact freshness check, since it validates the handoff independently at `:425-428`. Both need an offline regression in `ecosys-audit/tests/test_workflow.py`. Changing the checker from inside the blocked task would let the editor waive its own guard, so it is left for an explicitly authorised change.

Editor rule until fixed: never list `audit/handoff.md` in a result's `evidence`.

## Fix (applied after explicit user authorisation: "yes, fix workflow.py with a regression test, then close")

- `seal`: rejects evidence paths equal to `audit/handoff.md` or under `audit/workflow/` ("mutable workflow state, not sealable evidence"); the handoff is still recorded separately in the packet's `handoff` field.
- `close`: skips `audit/handoff.md` when re-verifying packet and review artifacts; every other artifact stays byte-frozen, and the live handoff is still size-checked and must name the task and review path.
- New constant `HANDOFF = "audit/handoff.md"`.

Offline regressions in `ecosys-audit/tests/test_workflow.py` (`ProtocolTests`):
`test_handoff_and_workflow_state_cannot_be_sealed_as_evidence`; `test_packet_already_holding_handoff_can_still_close` (reproduces the live packet by sealing with the guard patched out, then closes); `test_other_evidence_still_frozen_at_close` (the exemption is handoff-only).

Evidence (`run_logged.py`, cwd outer root):
- `audit/runs/workflow-002-selftest-20260923-after/`: `test_workflow.py -v` -> **Ran 48 tests, OK**, exit 0, 109.2 s; stderr SHA-256 `c39fd7328fe85b47bdf118d4c810a2bac1cd942370f67aefd43dec9ea01fdffe`. (45 before + 3 new.)
- `audit/runs/workflow-002-selftest-20260923-adapter/`: `test_herdr_adapter.py -v` -> **Ran 15 tests, OK**, exit 0; stderr SHA-256 `cc56474099c37c9f0c99412a6e81d65aa490855ff249e55b9fd340020e9930ac`.
- Tested hashes: `workflow.py` `824c3e14ade62c4b32279cc7f32c72e6e351bdec9fa6e00a1660961d26b6a488`; `test_workflow.py` `8d098bcbed14a6a6cfb315cb075dd9586907474ea3cebb7fba1ea23bfa194904`.

Limitations: no pre-fix run of the new tests was recorded, so their discrimination rests on the live failure they reproduce, not a logged before/after. The fix itself has not been independently reviewed by Pi. Infrastructure only; no science, gate or model source changed.
