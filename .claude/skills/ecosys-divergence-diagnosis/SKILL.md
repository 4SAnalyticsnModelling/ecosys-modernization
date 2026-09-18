---
name: ecosys-divergence-diagnosis
description: "Find the earliest cause of an ecosys legacy/Zig mismatch or failed hour. Use for significant differences, persistent zeros, solver failures and repeated unsuccessful full-run cycles."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Diagnose the first cause, not the last symptom

Open an issue with candidate/input hashes, exact failure signature, first observable discrepancy, affected columns/processes and the current hypothesis. Preserve the failing logs and state. Do not immediately restart the full production deck.

## Establish a minimal reproducer
Check stale binaries, differing inputs/defaults, start states, output time support, units, cumulative semantics and row alignment. Locate the earliest differing timestamp and upstream process. Compare existing checkpoints/traces; bisect in simulation time only when restarting from a checkpoint is semantically equivalent and verified. Otherwise use a deterministic shortened replay from the true initialization. A checkpoint with incomplete solver/management/cumulative state is not a trustworthy time-bisection boundary.

Capture matched states around producer, exchange and consumer boundaries. Instrument a staged legacy copy when needed; avoid changing reference equations. Compare pool and flux deltas, signs, index coordinates and old/new state timing. Follow the backward provenance chain from output to first incorrect producer. A suspicious zero may be an unbound writer, not a missing process equation.

## Ranked causes
Test baseline/normalization errors; translation and bindings; precision/constants/indexing; process order and stale state; solver residual/Jacobian/rollback; conservation/phase partition; `ReleaseFast` safety and math-mode behavior; thread races/reduction ordering; finally approved scientific changes. Ranking is a search discipline, not a claim that every failure has the same cause.

Each experiment states what observation would refute the hypothesis. Prefer one-step/kernel tests to another long run. Isolate one causal change per patch. Add the minimal regression, then rerun dependent interfaces before the integrated example.

## Bound the loop
After three distinct unproductive experiments, hand the raw evidence to an independent reviewer and reframe the problem. Do not simply increase iteration counts, loosen tolerances, clamp values or change test expectations. If the same expensive failure recurs without new information, stop that run campaign and improve the reproducer/observability. Continue independent audits while blocked.

## Close
Provide a source-anchored cause, before/after reproducer, regression, affected evidence invalidation, independent review and downstream checks. Feature attribution is a separate evidence path. "Run now completes" alone does not close a scientific discrepancy.
