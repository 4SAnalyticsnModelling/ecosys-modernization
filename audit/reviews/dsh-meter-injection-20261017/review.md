# Qwen27 Herdr turn error — 2026-10-17

Herdr session ecosys-work-qwen-3.8-27b, pane w1:p1, native session
1088e6c0-21dc-4ee6-9f37-dc091d3e05a2. Both recorded turns fail with
`cannot get property "tokenMeter" without inject` before any model request.
Exact terminal errors extracted in turn-errors.json; full session retained locally.

Cause: WatchdogCompaction replaced BasicCompactionEngine.static.inject with
llm/sessions/agents, dropping the inherited required tokenMeter service.
Cordis enforces service declarations for mounted sibling providers. Earlier tests
constructed providers at root, bypassing this boundary and missing the defect.
Fix: inherit [...Basic.inject, 'agents']. A sibling-provider regression reproduces
the exact error before the change (before.log) and passes after it. 25 Node tests
pass (after.log). Installed globally with the existing backed-up deployment helper.
Current harness process must reload/restart to import the corrected class; no user
prompt was sent and no active session or watchdog state was reset.

Also removed the discovered 8-hour no-progress termination branch from the global
supervisor, consistent with the user's prior no-timeout directive. Polling remains;
actual persistence/checkpoint errors still fail honestly. Python supervisor checks
are in supervisor-tests.log. Runtime .dsh-watchdog/ sessions and caches are now
ignored by Git and retained locally instead of being accidentally committed.

No model weights, model settings, science code or mission frontier changed.
