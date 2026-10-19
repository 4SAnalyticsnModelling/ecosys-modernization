# Workflow maintenance

Scope: single-model protocol/planning/skills, recovery, navigation, evidence tools and test plumbing.
The Ottawa worker was not launched. Its existing nitrogen-state patch is byte-identical to the
pre-maintenance diff; cycle 3 remains open. Protected scientific references were untouched.

Removed obsolete role/controller/plan/pack artifacts and accounting reports; retained scientific
receipts. Instructions load progressively. Failure packets use one JSON plus a patch when needed.

Verification:
- 69 active Python tests: `audit/runs/workflow-revision-final/receipt.json` and stdout.
- 33 native context/code-mode/isolation tests: `audit/runs/workflow-revision-context-final/receipt.json`.
- 17 skills validated: `audit/runs/workflow-revision-skills/receipt.json`; aliases/index show no drift.
- Zig 0.17 build-option evaluation: `audit/runs/workflow-revision-build-api-final/receipt.json`.
- Build formatter and shell syntax checked; no full science suite or production build claimed.

Separate edge-case review covered failed/stale verdicts, full-cycle diff scope, post-push dirt,
worker crashes/early exits/corrupt records, inherited lifetime leases, stale binaries, truncated
comparison intervals, protected codemods and bounded source reads. Regressions cover these cases.
The dsh worker argv is configured and structurally checked, not activated. Installed external
harness files and OS services were not changed; reboot recovery requires tested service deployment.
