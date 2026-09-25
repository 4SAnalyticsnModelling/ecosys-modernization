# Workflow-001: controller never dispatches because it reads the wrong Herdr field

Date: 2026-09-23. Scope: orchestration infrastructure only.
Status: source fix and focused regressions PASS; restarting the old controller and live
end-to-end dispatch/rotation NOT_ASSESSED by this outside-Herdr debugging session.

## Observed failure

The user reported both agents became idle seconds after kickoff. Local diagnostic files
showed editor and reviewer startup registrations both `activity: idle`, no task state or
dispatch file, and an empty controller.log. The Python controller was still running.
This is an orchestration readiness failure, not a model refusal or scientific failure.

Saved CLI outputs in Claude session `762683e5-9b4a-4466-a510-604e590a11ca` contained Herdr
0.9.1 `agent_info` records with `agent_status` (and `agent_session`, `pane_id`, `cwd`, etc.).
The saved commands included `herdr agent list` and the two agent renames; no fresh Herdr
server/pane query was made from the debugging process outside Herdr. Relevant shape:

```json
{"result":{"type":"agent_info","agent":{"name":"reviewer","agent":"pi","pane_id":"w3:p4","agent_status":"idle"}}}
```

The old `Herdr.idle()` recursively searched for `state`, a field absent from those
records. Its state set stayed empty, so even two idle agents could never pass the first
`wait_idle`. The helper kept polling for its default hour before reporting a timeout.
No task was ever dispatched. The earlier offline tests mocked the adapter methods and
therefore did not exercise the installed Herdr response shape. That test gap is now
covered explicitly; this was an implementation defect, not incorrect kickoff prompts.

## Change

`ecosys-audit/scripts/herdr_cycle.py` now:

- Parses the explicit `result.agent.agent_status` field; unsupported envelopes/fields
  raise a clear error rather than masquerading as a busy agent.
- Validates name, pane, expected harness, project cwd and native session identity. Pi's
  session-path reference is checked against the registered session ID.
- Requires both native `activity: idle` and Herdr `idle`/`done`; real working/blocked states
  are not treated as idle. Unknown classification has a short bounded grace.
- Writes READY/WAITING diagnostics to controller-status.json and flushes transitions to
  controller.log. Steady waits update a heartbeat at most every 30 seconds, not a model loop.

No gates, science, models, permissions or reference data were changed. No active model
process or Herdr server was stopped or controlled by this debugging session.

## Focused evidence

All commands ran from `D:/ecosys-modernization`, using the existing uv-managed Python.
Tests use temporary files and fake CLI responses, with no model or live Herdr calls.

Before the fix:

```
uv run ecosys-audit/scripts/run_logged.py --cwd . --out audit/runs/workflow-selftest-20260923-agent-status-before --timeout 30 -- uv run ecosys-audit/tests/test_herdr_adapter.py -v
```

One discriminating test FAILED, exit 1: `agent_status: idle` incorrectly returned False.
Raw stderr SHA-256: `9c27dad5ff01a87e8eba4f901ae8fe3b3f08e69d7cf4208ea77721426025850b`.

After the fix:

```
uv run ecosys-audit/scripts/run_logged.py --cwd . --out audit/runs/workflow-selftest-20260923-agent-status-after --timeout 60 -- uv run ecosys-audit/tests/test_herdr_adapter.py -v
uv run ecosys-audit/scripts/run_logged.py --cwd . --out audit/runs/workflow-selftest-20260923-controller-regression --timeout 90 -- uv run ecosys-audit/tests/test_workflow.py ControllerTests -v
```

- Actual-shape adapter tests: **15 passed**, exit 0, wrapper elapsed 0.931 s.
  Raw stderr SHA-256: `b742c8f47bc50df56d76a8bea284999d73227e06cf00b8566f3868c40948d2b4`.
- Existing controller/rotation safeguards: **8 passed**, exit 0, wrapper elapsed 31.208 s.
  Raw stderr SHA-256: `db74b1aa34483608735d6f2b2e6ecfedcf7152561865e6762b6cc9f88498440b`.

Each raw log and receipt is under its command's `--out` directory. The adapter suite includes
first-dispatch progression using the observed response structure, unsupported/missing status,
wrong/stale identity, Pi path identities, real busy/blocked states, unknown grace and bounded
logging. These tests are not proof of live end-to-end Herdr behavior.

Tested source hashes:
- `ecosys-audit/scripts/herdr_cycle.py`: `027f6b943bd21e0243b37bceace009ab6b9a9f3b711040955b538a2ed5db1205`
- `ecosys-audit/tests/test_herdr_adapter.py`: `a5dc461d204ad2d105484b35b2d66c6d040405efd949829c7f0fd17001a81a6d`

The earlier cost-controls manifest remains the historical pre-fix snapshot; its controller
hash is superseded for readiness behavior by this record. No full scientific tests were run.

## Recovery from the existing stuck process (lead executes INSIDE Herdr)

1. Verify `HERDR_ENV=1`, the project root, and current workflow state. At diagnosis there
   was no state.json or dispatch.json. If work/dispatch has appeared since, reconcile it
   before stopping anything; do not blindly repeat a task.
2. Inspect current Python process command lines. Stop ONLY the old `herdr_cycle.py`
   controller for root `D:/ecosys-modernization`, session `ecosys-modernization`, action
   `run`. The observed processes were launcher PID 9044 and child PID 10680, both created
   at 2026-09-23 12:16:32 local. These PIDs are observations, not permanent identifiers:
   reverify command line and creation time before termination. Do not kill Herdr,
   Claude, Pi, other Python processes or scientific builds/runs.
3. Run `uv run ecosys-audit/scripts/herdr_cycle.py ensure`, then finish the lead's turn
   and yield. The controller waits for the lead to become idle; do not wait inside
   that same turn for the next assignment.
4. Confirm the fresh process records READY/WAITING diagnostics and then a planning/
   dispatch/task artifact. A STARTED PID by itself is not proof of successful dispatch.

`ensure` alone cannot load changed Python into an existing lock-owning controller, and
there is no reason to recreate the two agents or clear their conversations for this fix.
