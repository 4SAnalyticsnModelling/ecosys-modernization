# Autonomous cost controls: stages 2-4 implementation and verification

Date: 2026-09-23. Author: current Pi implementation session (outside Herdr).
Baseline: `6944efe15be5e149158166e1e279f0e3c55e813f` plus pre-existing untracked
`scripts/`. Source hashes and exact final test artifacts are in
`audit/tests/workflow-cost-controls-2026-09-23-manifest.json`.

## Installed behavior

- Project Claude SessionStart/UserPromptSubmit/Stop/PreToolUse command hooks and a
  project Pi extension load on subsequent trusted sessions. Existing global settings,
  authentication, models, effort, and Herdr-managed integrations are untouched.
- AGENTS.md/CLAUDE.md and both copies of the orchestration/coordination skills route
  autonomous audit continuation to `ecosys-audit/WORKFLOW.md`. The lead starts one
  detached controller and yields; it handles peer dispatch and conversation rotation.
  Questions and plan-only requests do not automatically start an audit campaign.
- Task/revision/candidate-bound packets replace terminal transcript forwarding.
  Two failed review rounds finalize FAIL rather than looping until agreement.
  Identical candidate/evidence, including renamed copies of logs, cannot trigger
  another equivalent review. Unrelated findings are queued, not expanded into
  another full-release audit per patch. No approval strings or automatic pushes.
- Handoff is current state only, limited to 6,500 UTF-8 bytes. The original 279,795-byte
  file was archived byte-for-byte with SHA-256
  `8b3fc0d1fcf27b3b6e36902da984071f11680bfb4ed29f9dda6bac9eb5cabebc`.
  `audit/history/INDEX.md` maps historical line references. Every future replacement
  uses archive + expected-hash check + atomic replacement. Untracked original workflow
  scripts were separately archived before modification.
- A closed task must have a fresh review and current checkpoint. The controller verifies
  idle state, pane/native-session identity, candidate freshness and reset acknowledgement
  before dispatching another task. Reset intents survive crashes. Missing receipts,
  ambiguous delivery, changed sources and unrelated sessions cannot authorize clearing.
- Explicit recovery adoption records preserve all prior author identities, which remain
  ineligible to independently review that task. Pi carries old unresolved assignments
  forward before its first automatic reset. Genuine blockers pause, without a token-burning
  model polling loop or automatic approval-dialog answers.
- Commands write complete raw stdout/stderr and metadata through `run_logged.py`; small
  previews return to the model. Nonzero exits and timeouts propagate. Test acceptance/counts
  are not inferred from exit 0. Pi preserves oversized shell-tool results in separate files;
  these captures may already be truncated upstream and are labelled accordingly.

## Checks actually executed

Working directory for commands: `D:/ecosys-modernization`.
Environment: Windows; uv 0.12.13; managed CPython 3.12.13 (MSC v.1944 AMD64);
Node v24.16.0; installed Pi 0.87.0; installed Claude Code 2.1.280.

### Python: 45 tests, 0 failures, exit 0

```
uv run ecosys-audit/scripts/run_logged.py --cwd . --out audit/runs/workflow-selftest-20260923-r5-python --timeout 180 -- uv run ecosys-audit/tests/test_workflow.py -v
```

Actual wrapper elapsed: 127.518 seconds. Test runner: 127.155 seconds.
Raw results: `audit/runs/workflow-selftest-20260923-r5-python/stderr.log`.
Covers archival, concurrent/stale writes, immutable evidence, identity/freshness binding,
self-review rejection, source additions/deletions, pending processes, repeated questions,
renamed duplicate evidence, bounded correction, recovery adoption, raw log preservation,
launch failures, timeouts, hook continuation bounds, fake full-cycle dispatch, reset
acknowledgement and unrelated-session protection.

### Pi extension: 9 tests, 0 failures, exit 0

```
uv run ecosys-audit/scripts/run_logged.py --cwd . --out audit/runs/workflow-selftest-20260923-r3-pi --timeout 30 -- node --test ecosys-audit/tests/pi-workflow.test.mjs
```

Actual wrapper elapsed: 0.220 seconds. Node runner: 143.2413 ms.
Raw results: `audit/runs/workflow-selftest-20260923-r3-pi/stdout.log`.
Fake Pi API only: stable bootstrap, native session metadata, direct reviewer write lane,
checkpoint routing, raw-log wrapper routing, saved/bounded shell results, unchanged source
reads, one-shot receipt reminders and no extra turn after a receipt.

### Other actual checks

- `pi --offline --no-extensions -e .pi/extensions/ecosys-workflow.ts --list-models gemini-3.8-flash`
  exited 0 without a provider/model inference request. This is an offline loading smoke
  command, not a live task/session rotation test.
- `bash -n scripts/orchestrate-adversarial.sh scripts/setup-layout-and-agents.sh`: exit 0.
- `git diff --check`: exit 0 (host core.autocrlf warnings only).
- All 17 installed canonical/Claude skill bodies compared by SHA-256; no mismatches.
- Git status under all four authoritative directories was empty. No Fortran/Zig source,
  reference outputs or production inputs were changed, and no model build/run was launched.
- The historical handoff archive hash was rechecked after migration and matched.

### Defect caught during infrastructure testing

The second Node test invocation passed its child tests, but the new log wrapper failed
while printing Unicode checkmarks to a Windows cp1252 stdout writer. This was a wrapper
failure, not a passing wrapper invocation. It was fixed by emitting ASCII-safe JSON and
covered with a subprocess regression using `PYTHONIOENCODING=cp1252`. The failed invocation's
child logs/receipt remain in `audit/runs/workflow-selftest-20260923-r2-pi/`; later r3 is the
successful replacement. Earlier Python test runs remain preserved, not substituted for r5.

A final real-D: checkpoint smoke test also caught that this filesystem rejects hard links
with WinError 1. Temporary C: repositories had supported them, so the earlier tests did not
expose it. Publication now uses a cooperating-writer sidecar lock plus same-directory atomic
replacement (no hard links); the sidecar locks are ignored by Git. A dedicated regression
simulates unavailable hard links. Real-D: `workflow.py archive audit/handoff.md` then succeeded,
preserving SHA-256 `d978b41a37be77732fe26450df438d84f6ffdc59e923d75796a5c8c36d65a789`.
The failed publication had left the live handoff unchanged. r5 is the full suite after this fix.

## Subsequent live-startup defect

The first user kickoff exposed a readiness-parser bug: Herdr reports `agent_status`, but the
original adapter searched for `state`, so the controller waited without dispatching. The
initial fake-agent tests did not cover the installed response shape. See
`audit/issues/workflow-001-herdr-readiness-field.md` for the failing reproducer, source fix,
23 focused passing tests and required in-Herdr controller restart. This report/manifest
remains the historical initial implementation snapshot, not verification of the newer adapter.

## Limits / pending verification

No live Herdr session was inspected or controlled from this outside-Herdr process. No paid
model runs were launched. Live end-to-end controller behavior and independent review of
this workflow are NOT_ASSESSED. Unexpected Herdr JSON/state, missing startup integrations,
permission dialogs, transport ambiguity and real environmental blockers fail closed; the
implementation does not promise to bypass them or guarantee indefinite unattended progress.
The next normal autonomous audit sessions discover the integration without manual setup,
and the controller itself checks native IDs before any context reset.

This is not an OS sandbox: Pi's built-in write/edit lane is guarded, while shell commands
remain governed by project permissions and post-review hash checks. Hashes cannot establish
scientific truth, completeness of a declared scope, or genuine independent reasoning.
The operational candidate hash excludes ignored/generated files; release provenance still
requires the contract's full source/input/toolchain evidence.

No percentage or dollar cost saving has been measured. The handoff reduction is a file-size
change, not a bill reduction. Scientific gates, tests, tolerances and release status remain
unchanged. No commits, tags or pushes were made by this implementation session.
