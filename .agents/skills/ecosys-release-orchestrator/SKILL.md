---
name: ecosys-release-orchestrator
description: "Coordinate the complete ecosys Fortran-to-Zig audit and v1.0.0 release candidate. Use for project startup, resumption, audit planning, stage gates and integration; delegate detailed checks to the focused ecosys skills."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Coordinate the migration, not an endless run/fix loop

## Start or resume
Read the shared project contract and evidence guide if not already present in this context.
Autonomous work runs through the 4-agent swarm (SENTINEL, PATHFINDER, FORGE, SAGE): state in
`.agent/state.md`, operation in `.agent/README.md`, plan in
`ecosys-ng_ottawa_qualification_execution_plan.md`, controller `swarm_wrapper.py`. In a swarm
role session, follow `.agent/roles/<role>.md` and the task file instead of this section. The
former Claude-lead / Pi-reviewer workflow and `audit/handoff.md` are retired
(`archive/pre-swarm-workflow/`); do not resume from them. Inspect actual Git state and relevant
failing evidence, preserving pre-existing work. Reuse the issue board and command registry
rather than recreating them. Use `ecosys-repository-baseline` when provenance is missing/stale.
No autonomy for questions/plan-only requests or outside Herdr.

Token discipline (every task): read the task + one packet/issue + the `f77query`/`rg` hits you
need, never whole `.f`/Zig files or logs; `run_logged.py` for any verbose command; one-line
progress notes; evidence written once and cited by path. Stop and report instead of looping
when every remaining task is blocked by the same external fault (e.g. D: I/O).

Divide the legacy inventory into auditable process/interface units, not arbitrary equal line counts. Assign each unit a source owner and separate reviewer. Use `ecosys-multi-agent-coordination` when concurrency is available; sequentially perform the same roles otherwise. Limit expensive compiles/runs to one coordinator-owned lane unless independent resources are demonstrated.

## Execute the gates
- G0: baseline and complete scope. Discover real build/run commands instead of inventing target names or flags.
- G1: complete bidirectional source traceability, state/binding audit, process-science review and feature-boundary review. Read the complete relevant source, not just search hits. Targeted tests and compilations are encouraged. Defer repetitive whole-deck `ReleaseFast` runs.
- G2: focused regressions, solver edge cases, physical acceptance, critical `ReleaseFast` safety checks and a short integration replay. Prepare `production-entry.json` with current evidence.
- G3: full specified production deck, final-time proof and complete all-column comparison. Use `ecosys-divergence-diagnosis` for the earliest discrepancy. Do not debug six years of output by repeatedly waiting for the same failed hour.
- G4: benchmark accepted physics, independently verify the one integrated candidate and prepare the release dossier. Use `ecosys-release-verification`.

Every approved patch triggers the smallest affected tests immediately, followed by the appropriate coupling tests. A shared state, time integration or I/O change invalidates every dependent process/output check. Final full-deck evidence must be for the final integrated candidate, not a mixture of earlier passing branches.

## Bound attempts
Before a build/run, state its hypothesis, expected diagnostic value, stop condition, resource budget and source/configuration digest. After three distinct unsuccessful experiments on one issue, request a fresh diagnosis within the agent team and reduce the problem. Do not repeat an expensive failure with the same signature unless intentionally measuring repeatability. Preserve partial traces, not just the last log line.

Make source fixes within the agreed migration scope autonomously; stop only dependent work when a genuine permission, scientific-policy or environment blocker cannot be resolved from local evidence. Continue unrelated safe work. Never convert `BLOCKED` to `PASS` to maintain momentum.

## Required handoff
`.agent/state.md` (<=1,500 words, replaced not appended) names the candidate commit, verified
frontier, current failure, confirmed facts, blockers and next expected operation. Detailed
history belongs in issue/evidence files, task results and `.agent/archive/`. Every worker writes
only its task's result file; production-science changes need a SAGE verdict bound to the diff
hash (`swarm_wrapper.py precommit`). Distinguish actual results from proposed tests; short
terminal summaries link evidence rather than restating it. A task DONE is not a gate.

## Done
All required release checks pass for one source/input/toolchain snapshot; the coordinator has an independently reviewed dossier. Otherwise deliver the exact blockers and the preserved work without claiming production readiness.
