---
name: ecosys-autonomous-orchestration
description: "Resume and execute autonomous Ottawa cycles with one model; use for pickup, decisions, recovery and cycle closure."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Run `./scripts/project.sh pickup`; reconcile jobs, dirty edits and the open cycle before sync.
Choose one falsifiable target from the execution plan/backlog. Record its falsifier and smallest
experiment. Use `cycle_runner.py open|gate|gates|close` through `scripts/project.sh`.
Run focused → coupling → event → full checks according to changed dependencies. Re-derive
separately for G7, preferably in fresh sequential context of the same model. Fix/revert a
reproduced FAIL. Record next action; stage owned paths, commit/push, continue.
Use `supervise --config .agent/worker.json` for unlimited crash recovery; never launch duplicate
science jobs or repeat an unchanged failed experiment. External outages trigger backoff and
other unblocked work. Finish only after `completion.py` validates F1–F7.

Batch source reads with `project.sh code`; use `tools/autonomy/code-reading.md` for code mode
and `project.sh codemod` for previewed, hash/count-checked mechanical edits.
