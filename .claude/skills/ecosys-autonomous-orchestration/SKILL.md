---
name: ecosys-autonomous-orchestration
description: "Resume and execute autonomous Ottawa cycles with one accountable leader; use for pickup, decisions, recovery and cycle closure."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One leader decides and verifies;
optional safe sub-agents follow the protocol. No adversarial reviewers or reviewer approval gates.

Run `./scripts/project.sh pickup`; reconcile jobs, dirty edits and the open cycle before sync.
The leader may use scoped swarms for independent supporting tasks. Preserve shared-state/run
ownership; only the leader integrates results, records gates and publishes. Take over unavailable
helper work; never wait for reviewer sign-off or treat helper agreement as scientific evidence.
Choose one falsifiable target from the execution plan/backlog. Record its falsifier and smallest
experiment. Use `cycle_runner.py open|gate|gates|close` through `scripts/project.sh`.
For near-zero, signed-balance, negative-pool or solver failures route immediately to
[numerical recovery](../../../.agent/playbooks/convergence-and-balance.md). Resolve benign cases
promptly on a captured kernel; keep failed scientific trials private and diagnose their cause.
Do not restart a bounded nonconvergence as a worker crash or reset its budget unchanged.
Nonfinite or impossible-state exits require the same causal repair. Preserve the last valid
checkpoint; never resume from contaminated state or repeat an unchanged scientific crash.
The simulator's fatal exit returns control to worker diagnosis; it does not terminate the
autonomous task. Use a captured state or changed diagnostic fixture/instrumentation for parent
reproduction; a renamed run or prose-only hypothesis cannot bypass the experiment guard.
Run focused → coupling → event → full checks according to changed dependencies. Re-derive
separately for G7 in the leader's current session; fresh context is optional. Fix/revert a
reproduced FAIL. Record next action; stage owned paths, commit/push, continue.
Use `supervise --config .agent/worker.json` after live runtime qualification; never launch duplicate
science jobs or repeat an unchanged failed experiment. Three unchanged exits force REPLAN; a fourth waits for changed prerequisites.
Use `tools/autonomy/README.md` for automatic rechecks; take other unblocked work first. Finish only after `completion.py` validates F1–F7.

Batch source reads with `project.sh code`; use `tools/autonomy/code-reading.md` for code mode
and `project.sh codemod` for previewed, hash/count-checked mechanical edits.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.

Retry interrupted closure with `close`; it reuses the existing commit after a push outage.
Include all cycle-owned source/tests/decisions and evidence or retention manifests in publication.
