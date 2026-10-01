---
name: ecosys-multi-agent-coordination
description: "Coordinate the worker/judge adversarial workflow (DEEPSEEK: local Qwen3.5-35B-A3B does all the work; CLAUDE: Claude Opus 5.5 handles deep diagnosis, cross-language reasoning, architecture and the final scientific review, with the final say) without conflicting edits or duplicate full runs. Use for round planning, escalations, reviews, rulings, and cross-harness verification."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Shared evidence, isolated work

Use this pack's canonical skills and contract across all harnesses. Select one integration coordinator; the brand/model of agent does not determine authority or scientific correctness. Verify the capabilities of the installed harness before invoking multi-agent, worktree or messaging functions. Pi may need an extension/external orchestration; if unavailable, use sequential roles and never claim a swarm ran.

## Assign bounded work
Partition by process/interface dependency: hydrology/thermal; plant/canopy; biogeochemistry/gases; state/I/O; test/comparison; safety/performance as the actual inventory warrants. Each assignment names scope IDs, input candidate, permitted files, forbidden shared files, required evidence and done condition. A subsystem worker cannot approve its own changes as the independent reviewer.

Read-only review may run in parallel. For edits, use separate branches/worktrees of the correct Git repository; preserve access to the authoritative reference data. The outer workspace can contain several repositories. Do not launch `git worktree` blindly at the outer root. Assign unique scratch/output/cache paths and resource budgets. Large compiles/full runs are coordinator-owned and normally serialized.

## Review/integration protocol
Workers return patch/commit identity, exact source mappings, minimal reproducer, tests actually executed, unresolved concerns and invalidated dependencies. A reviewer reads the relevant original code and raw evidence independently, challenges assumptions and records disagreements. Do not count the same agent under a new name as independent approval or equate consensus with correctness.

The coordinator integrates one coherent change set at a time, checks for shared state/interface conflicts, resolves imports/build definitions, reruns affected tests and updates the candidate manifest. Merge order matters for numerical/state changes; do not reuse branch-level success as final integrated success. The final production, output and performance evidence must concern the same integrated candidate.

## Communication and resource control
The installed team is two models on one Herdr tab (`ADVERSARIAL`, `.agent/README.md`): DEEPSEEK
(local Qwen3.5-35B-A3B via llama.cpp) does all the work; CLAUDE (Claude Opus 5.5) handles only deep
scientific diagnosis, cross-language reasoning, architecture decisions and the final scientific review,
guides Qwen when needed, and its ruling is final. Roles, models,
authority rules and write lanes are defined once in `.agent/roster.json`. Each round file
(`.agent/templates/adversarial-round.md`) carries DEEPSEEK's plan, work, evidence and self-check, any escalation
with CLAUDE's guidance (or one DEEPSEEK objection), and CLAUDE's `**Final Ruling (CLAUDE)**: APPROVED | REVISE | REJECTED`.
`adversarial_runner.py` commits and pushes only APPROVED rounds. One bounded question per round;
further work needs a new falsifiable target, not a renamed repeat. The worker never approves its
own work. Report FAIL/STAGNATED/BLOCKED honestly.
`.agent/state.md` is the single current-state file; each worker writes only its task's result
file; task-scoped DONE never approves a release. This project's durable artifact-first protocol
intentionally overrides the generic Herdr skill's terminal-first response preference. Use
`run_logged.py` for full command logs and pass paths/hashes plus
short findings, not full reports or terminal transcripts. No concurrent ledger edits. Record actual available RAM and limit concurrent model builds/runs accordingly; a shared local inference model and code-build processes still compete for resources. Never assume a local model can truly evaluate all worker prompts concurrently.

## Done
All owned work is merged or explicitly deferred, independent review concerns are resolved and the coordinator has reproducible integrated evidence. No overlapping untracked edits, orphan runs or unverified "all agents passed" claims remain.
