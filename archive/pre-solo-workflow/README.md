# Retired multi-agent launchers (pre-solo workflow)

Moved here on 2026-10-09. The project runs as **one autonomous agent in cycles** (`.agent/protocol.md`);
these scripts started the retired pane/role machinery — a worker pane (DEEPSEEK, local Qwen), a judge pane
(CLAUDE), a `herdr` layout, and a round-based adversarial runner with pokes and rulings. Nothing in the live
protocol calls them, and no cycle may be driven from them.

| File | What it used to do |
| --- | --- |
| `start-adversarial.sh` / `.ps1` | start the worker + judge panes and the round loop |
| `start-deepseek.sh` | start the local Qwen worker pane only |
| `start-swarm.sh` | start the 4-agent swarm controller (`ecosys-audit/scripts/swarm_wrapper.py`) |
| `setup-adversarial-layout.sh` / `.ps1` | create the `herdr` pane layout for the two-model workflow |
| `herdr-deepseek-status.ps1` | poll the worker pane status (Windows host) |
| `adversarial_runner.py` | round-based runner: pokes, verdict files, judge escalation |

Kept for the record, not for use: cite these for workflow history (`.agent/adversarial/`, `audit/rounds/`)
and never as authority. The live entry points are `./sync-main.sh`, `ecosys-audit/scripts/preflight.py`,
`ecosys-audit/scripts/run_logged.py`, `ecosys-audit/scripts/f77query.py` and the ledgers under `.agent/`.

Related-but-still-present tooling (imported by `ecosys-audit/tests`, so it stays):
`ecosys-audit/scripts/swarm_wrapper.py`, `ecosys-audit/scripts/workflow.py`. Neither is part of the protocol;
`.agent/roster.json` survives only as their retired configuration.
