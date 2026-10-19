# ecosys-ng Ottawa: one autonomous model

Read `.agent/protocol.md`, then run `./scripts/project.sh pickup`.
The agent makes all project/science/architecture decisions from evidence and continues
without human approval until F1–F7 pass. No elapsed-time limits or mandatory sub-agents.
Use `.agent/backlog.md` and `ecosys-ng_ottawa_qualification_execution_plan.md` for priorities.

Use `scripts/project.sh exec` for logged heavy commands and `supervise` for automatic
worker restart. Reconcile existing jobs/edits before retrying. Never relaunch an unchanged
scientific failure. Preserve unrelated work; stage explicit paths; commit/push each verified
cycle to main. Keep all caches, scratch, evidence and runs inside this repository.

Zig 0.17.x only. `f77src/`, `f77example/`, `ecosys-ng-prod-examples/` are read-only.
Use `f77query.py` for Fortran. Never loosen scientific gates, invent evidence, publish an
unclosed ledger or silently change physics. Keep instructions and handoffs brief; receipts
and source locations hold details. Skills are canonical in `.agents/skills/`.
