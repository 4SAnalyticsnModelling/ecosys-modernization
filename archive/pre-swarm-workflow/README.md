# Retired: Claude-lead / Pi-reviewer workflow (2026-09-23 .. 2026-09-25)

**Do not run, resume from, or follow anything in this directory.** It was retired on 2026-09-25
when the project moved to the 4-agent swarm (`.agent/README.md`,
`ecosys-ng_ottawa_qualification_execution_plan.md`). Files keep their original relative paths,
so `archive/pre-swarm-workflow/X` was `X`. Nothing was deleted. Git history holds the tracked
originals.

| Archived | Was |
|---|---|
| `ecosys-audit/WORKFLOW.md`, `ecosys-audit/START_PROMPT.md` | lead/reviewer protocol and start prompt |
| `ecosys-audit/scripts/herdr_cycle.py` | 2-pane Herdr controller (`ensure`, `peer`, `next`) |
| `ecosys-audit/tests/test_herdr_adapter.py`, `pi-workflow.test.mjs`, `test_workflow.py` (full original) | tests for the above; the live `test_workflow.py` keeps only the helper/checkpoint/log/hook tests |
| `.pi/` | Pi reviewer extension |
| `scripts/setup-layout-and-agents.sh`, `scripts/orchestrate-adversarial.sh` | editor/reviewer session setup for Herdr session `ecosys-modernization` |
| `audit/workflow/runtime/`, `spec-next.json`, `result-next.json`, `checkpoint-next.md` | controller state, including an unfinished old-cycle task draft |
| `audit/HANDOFF-SUMMARY-2026-09-20.md`, `audit/handoff-issue-triage.md` | historical summaries |

Still in place on purpose:
- `audit/handoff.md`: a superseded pointer. Its last content is byte-identical in
  `audit/history/handoff-131ce6d8....md`.
- `audit/history/`, `audit/tasks/`, `audit/reviews/`: immutable records of that workflow, cited by issues.
- `ecosys-audit/scripts/workflow.py`: its file helpers are used by the swarm tools. Its
  begin/seal/review CLI is marked RETIRED.
- `ecosys-audit-skill-pack/`: the vendored original skill pack (hash-manifested). It is not
  auto-loaded; the live skills are `.agents/skills/` and `.claude/skills/`.
- Scientific records (`audit/issues/`, `audit/runs/`, `audit/analysis/`): evidence to re-verify.
