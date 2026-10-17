# Shared native code mode — 2026-10-17

User explicitly asked for code mode or equivalent to be made available to the
DeepSeek harness and all local models. Installed dsh 0.2.0-rc.2 already contains
native PTC (`run_code`) and a managed TypeScript runtime; no duplicate evaluator
was needed. All three installed profiles now select tools mode `both`, and any
nested preset presentation is also `both`. This applies independently of which
of the four catalog models is selected and is reapplied by the config generator.

`code-mode.mjs` subclasses only native resolve to select timeoutMs:null. Native
process isolation, sandbox/approval resolution, explicit cancellation, memory,
output and parallel-call bounds remain inherited. Code-mode instructions are
injected for all models through existing shared watchdog instructions. Existing
sessions need restart to mount new plugins. No model-generation request was run.

Validation: 24/24 Node watchdog tests PASS, including actual managed subprocess
execution of two concurrent host bindings beyond a requested 1 ms deadline and
both native-tool/run_code schema visibility; three composed-profile checks verify
one code runtime, disabled original runtime and both presentation. See tests.log.
The isolated runtime test uses explicit danger-full-access authority; it does not
establish confined OS sandbox behavior or live model tool-selection quality.

G7 fresh-context read-only verifier independently found an initial root presentation
mount error: tools.presentAs requires an agent scope. Fixed by tools.config.mode=both
and removing that root presentation plugin. Reverification verdict: PASS; independent
profile checks and runtime smoke passed. No science or solver code changed.

Deployment: user-requested global availability required updating installed dsh
profile patches and copying the repo-owned runtime adapter/instructions outside the
repository. This is scoped to the latest user request; original deployment backups
and install receipt remain under ignored watchdog/. Model weights and serving
settings were not changed. Existing external serving/request/idle timeouts remain;
repository instruction policy cannot by itself remove limits in those services.

Historical Qwen27 measurements and active setup were extracted without rerunning
benchmarks: ../qwen27-historical-speed-20261017/report.md, records.json and source copies.
