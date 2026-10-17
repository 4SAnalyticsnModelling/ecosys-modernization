# Continuous autonomy policy

## Continuous autonomous work — 2026-10-17 directive

Autonomous work has **no elapsed-time timeout** at any stage: planning, investigation,
agent/sub-agent turns, builds, tests, diagnostics, verification, simulations, commits or sync.
Continue until the assigned objective is verified or an actual error or human-only blocker
requires action; time elapsed, silence, token usage, tool-call counts and session age are
never reasons to terminate work. Do not wrap work in `timeout`, set finite execution
deadlines, or interrupt a healthy process because a budget expires.

Keep long commands detached with repo-local logs, receipts, process identity and checkpoints.
A tool wait/poll limit yields control only: reattach and continue observing the same process.
Context compaction or unavoidable harness interruption requires durable notes and automatic
pickup of unfinished work; it does not complete or cancel the task. Watchdogs preserve and
recover work. Health probes may time out individual observations and retry without killing
work; explicit shutdown cleanup may be bounded after a genuine stop decision. Scientific
iteration bounds, conservation gates, memory/concurrency limits and finite simulated test
windows remain in force. Diagnose repeated failures and change approach without halting the
mission. Never infer process death from heartbeat age alone; check process identity/liveness.

This directive supersedes older time/session/tool budgets and timeout examples throughout
the repository, including retired role cards, plans and archived workflows. Historical
receipts remain unchanged and do not authorize new timeouts. Authority: `.agent/protocol.md`.
