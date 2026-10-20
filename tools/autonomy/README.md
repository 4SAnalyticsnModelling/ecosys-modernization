# Autonomous worker launcher

`.agent/protocol.md` governs. `.agent/worker.json` records historical harness argv; its deployment
is UNQUALIFIED. Reverify the actual executable and arguments in the deployment environment.
The worker reads `$ECOSYS_RECOVERY_PACKET`, reconciles jobs/edits and resumes the open cycle.
The same model chooses scientific and architectural decisions. No human approval is required.

Before unattended launch, establish live runtime evidence with benign isolated fixtures; this
maintenance does not deploy an OS service, activate a worker or certify runtime readiness.
Use `autonomy_readiness.py --identity` to capture current host/root/harness/config/runtime-file
identity. List harness plugins, service definitions and relevant configuration files in
`runtime_dependencies`; changes invalidate the certificate. Measure retained evidence/log growth,
record the storage/backup plan and set `storage_reserve_bytes` in the worker config accordingly.

`.agent/autonomy-readiness.json` requires `mode=LIVE,status=PASS,identity` and `cases`, a map
from every `autonomy_readiness.CASES` name to a hashed JSON artifact. Each case contains
`case,mode=LIVE,identity,status=PASS,assertions,evidence` (nonempty hashed artifacts).
Rehearse actual worker/supervisor crashes, early exit, context continuation, network outage and
recovery, service reboot, storage pressure, backup/restore, no-progress replan, blocked resume
and interrupted publication. Assert preserved edits, process ownership, restored evidence
hashes and the correct next action. Synthetic tests verify code paths; they cannot establish
provider credentials, live service installation or reboot recovery. The validator checks
identity/coverage/hashes; the agent must inspect the actual live assertions and outcomes.

```sh
./scripts/project.sh autonomy_readiness.py --config .agent/worker.json
./scripts/project.sh supervise --config .agent/worker.json --check
./scripts/project.sh supervise --config .agent/worker.json
```

The CLI refuses unattended launch without current live evidence. Bootstrap tests use benign
one-shot commands through `project.sh exec` and isolated service fixtures; they do not depend
on a finished Ottawa campaign. The supervisor itself installs no services. Reboot recovery
requires the host service manager to invoke this command with repo cwd and restart enabled.

One kernel lock and an inherited worker lease prevent duplicate workers after supervisor
crashes. Logs and atomic PID/start records are in `.agent/runtime/`. Healthy live processes
survive silence; age is never proof of death. A live harness must support cooperative context
handoff/recovery and expose diagnostic state. Diagnose a stuck session from process/tool state;
terminate only an identified failed owner after preserving its state, never a quiet healthy job.
There is no universal safe timeout that distinguishes a long scientific solve from a deadlock.

The durable restart guard uses source content, valid gate evidence and qualified frontier:
three exits without a previously unseen state cause one `REPLAN` launch; a fourth enters
`WAITING_FOR_CHANGE`. Revisit counts survive supervisor restart, including A → B → A cycles.
Logs, timestamps, commit IDs and worker exits are not progress. A new source/gate state is a
signal to resume, not proof of scientific advancement; review the falsifier and result each cycle.
A worker must diagnose an unchanged scientific failure on its first occurrence. Do other
unblocked work before waiting. Planning prose and new filenames do not clear the guard.

Route near-zero, positive/negative balance, negative-pool and Newton failures through
[numerical recovery](../../.agent/playbooks/convergence-and-balance.md). Solver attempt/recovery
budgets bound numerical work inside the worker; supervisor restart must not reset them into an
unchanged experiment. Capture a minimal diagnostic state, fix the cause and verify prompt benign
success with physical closure. An iteration cap is not an infrastructure outage. Numerical-work
limits do not authorize killing a healthy process for elapsed time or accepting its last iterate.
Nonfinite/domain or physically invalid-state exits are scientific failures too. Preserve their
first-cause evidence and last valid checkpoint; repair the Zig cause before rerun. Explicit
simulation failure is required when valid recovery is impossible, and must not be swallowed by
the worker/supervisor or converted into successful publication by a later compensating hour.

`recovery_command` is an optional **read-only** external-prerequisite probe, run only while
waiting. It must complete promptly and emit JSON `{ready: true, identity: "stable-resource-id"}`
when a real prerequisite becomes available. The identity describes that resource/configuration,
not a timestamp/random nonce. Exit zero alone and repeated identities never unlock another
worker. Probe errors preserve the wait and retry with capped backoff. Empty probe means wait
for changed source/evidence; configure a real availability probe before unattended operation.
Below the measured disk reserve, the supervisor waits without launching more work. The live
storage test must also verify that active workers checkpoint safely before exhausting space.
Retain cited evidence and rotate/archive logs according to the measured retention plan.

Completion is only `completion.py` validating F1–F7. Signals deliberately stop supervision;
a blocked prerequisite or exhausted diagnostic approach is not completion. Persistent failures
may require new infrastructure or knowledge; documentation cannot guarantee eventual scientific
success. They must remain explicit conditions with automatic rechecks rather than model loops.
