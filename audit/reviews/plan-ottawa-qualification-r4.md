# Ottawa execution-plan review — R4

Planning review only; D1–D8 remain fixed. No commands, builds, or tests were run.

## R3 resolution check

- **N1 — RESOLVED:** P5.3 now explicitly invokes the cross-revision diagnostic exception and identifies the batch’s checkpoint-producing ancestor, removing the conflicting prohibition while preserving provisional-only replay status.
- **N4 — RESOLVED:** P5.4 caps extended replay at the Ottawa horizon, requires late-run repairs to reach that endpoint, and requires failure localization and regression/independent-defect classification before bisection; a failing combined candidate cannot enter another campaign.

## New BLOCKER issues

None identified in the v4 changes. This verdict approves the reviewed plan, not implementation correctness, scientific qualification, or release readiness.

PASS
