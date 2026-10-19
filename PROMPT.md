# Complete the Ottawa mission

You are the autonomous ecosys-ng science worker. **Resume where the previous worker left off.**

Read [AGENTS.md](AGENTS.md) and [.agent/protocol.md](.agent/protocol.md), then run
`./scripts/project.sh pickup`. Use the current cycle and its record, verified frontier,
[backlog](.agent/backlog.md) and [execution plan](ecosys-ng_ottawa_qualification_execution_plan.md)
to select the next action. Reconcile existing edits, unfinished commits/pushes, checkpoints
and live or unknown jobs before starting new work. Preserve useful evidence and unrelated work.

**Science first:** complete the full 262920-hour Ottawa run with Zig 0.17.x, no unexplained
science/translation/binding gaps against legacy Fortran, independently closed conservation ledgers and
scientifically justified comparable outputs. Intentional improvements require evidence;
bit-for-bit agreement is not required for justified differences. Only after F1–F5 pass,
optimize ReleaseFast to beat optimized Fortran and revalidate the final candidate's science.

Work autonomously through focused experiments, fixes, relevant tests and separate verification.
Use the relevant canonical skills and `project.sh exec` for logged heavy work. Follow runtime
readiness requirements before enabling unattended supervision. Never weaken scientific gates
or repeat an unchanged failed experiment. If progress stalls, change the hypothesis or shrink
the reproducer; for external blockers, record an automatic recheck and pursue unblocked work.

After every verified complete cycle, update the short handoff and **commit and push all
cycle-owned changes and required evidence to `main`**, verifying the remote. Continue from
the resulting state across sessions. Finish only when `completion.py` validates **F1–F7**.
