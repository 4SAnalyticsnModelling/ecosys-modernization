# Continuous autonomy instruction/tooling revision — 2026-10-17

User requested no autonomous-work timeouts and commit/push of all pending work.
The pre-existing cycle 00003 PLANNING ledger, state and cycle record are preserved;
this tooling change does not close that science cycle or claim scientific progress.

Updated protocol, mission, entry points, both plans, all local skill copies and
exported skill pack, briefs, templates, tool runbooks and migration examples.
Older historical timeout instructions are explicitly superseded; receipts are preserved.
run_logged records deprecated requested timeouts but enforces none; Ottawa, legacy
campaign/warmup, gate, evidence, preflight and optional swarm work do not expire.
Live legacy locks cannot be reclaimed on heartbeat age alone. Poll/health observations
and explicit shutdown cleanup are distinct from execution deadlines.

Validation: workflow 39/39 PASS; legacy driver 31 PASS / 1 platform skip;
new swarm turn regression PASS beyond historical budget without an interrupt.
Old swarm integration tests depend on retired PATHFINDER roster entries and fail
before exercising turns (KeyError); no full retired-controller suite claimed.
Changed Python AST validation and git diff --check PASS. Logs: .tmp/continuous-autonomy-*.log.
No Zig/science source changes or simulations; science gates not exercised.
Containment: caches, scratch and test artifacts inside repository. Installed skill
instructions read under developer skill requirements; no external writes in this change.
Existing dirty work included by explicit user request. Commit/push proof: Git history
and git rev-parse HEAD origin/main after push. External harness/platform limits cannot
be abolished by repository policy; durable continuation is required when they interrupt.
