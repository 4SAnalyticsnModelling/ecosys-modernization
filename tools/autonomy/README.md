# Autonomous worker launcher

`.agent/worker.json` supplies verified `dsh headless` argv for this host. The future agent
may replace it with another verified single-model harness; no human decision or guessed flags. The command must read `$ECOSYS_RECOVERY_PACKET`, reconcile current
jobs/edits and resume the open cycle. `recovery_command` is optional idempotent infrastructure
repair. Both run in the repo with local caches. Credentials/provider availability remain
external prerequisites; no project decision waits for a human.

```sh
./scripts/project.sh supervise --config .agent/worker.json --check
./scripts/project.sh supervise --config .agent/worker.json
```

A supervisor lock and inherited worker-lifetime lease prevent concurrent workers, including
a supervisor crash. Each launch receives a fresh pickup packet;
logs and atomic PID/start-identity records live in `.agent/runtime/`. Any worker exit, even
zero, triggers reconciliation/restart with capped backoff until `completion.py` validates
F1–F7. No elapsed run deadline or finite restart budget. A live orphan worker is observed
before restart. Signals deliberately stop supervision; they do not complete the mission.
Never launch science here during workflow maintenance.

For reboot recovery run this same command under the host's persistent service manager with
repository cwd and restart enabled. Validate a synthetic crash/resume before deploying; an
uninstalled service cannot recover machine reboot. The supervisor does not repair scientific
failure by rerunning it unchanged; the worker diagnoses, tests and decides the next experiment.
