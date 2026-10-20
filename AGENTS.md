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

For near-zero values, signed balance defects, negative pools or nonlinear stalls, follow
[the numerical recovery playbook](.agent/playbooks/convergence-and-balance.md). Resolve benign
edge cases with bounded work and no false errors; preserve accuracy, all acceptance gates and
cumulative accounting. Diagnose the cause before changing a scale, floor or solver path.
Reject NaN/Inf, impossible pools and unexplained spikes before commitment, also in ReleaseFast.
Use bounded private-trial recovery or an explicit fatal error; never silently propagate bad
numbers or excuse an invalid hour because the next hour compensates. Fix legacy hazards in Zig.
