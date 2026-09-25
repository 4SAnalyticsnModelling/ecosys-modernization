## Workflow: 4-agent swarm (since 2026-09-25) -- read first
Work runs through the swarm: SENTINEL routes, PATHFINDER investigates, FORGE implements,
SAGE adjudicates science and reviews every production-science change. If your prompt names a
role or `ECOSYS_SWARM_ROLE` is set, follow `.agent/roles/<role>.md` and your task file only;
do not load skills, memory or files your task does not name. Operation: `.agent/README.md`.
The Claude-lead / Pi-reviewer workflow is retired (`archive/pre-swarm-workflow/`); never resume it.
Old scientific records (`audit/issues/`, `audit/runs/`) are evidence to re-verify, not passes.

## Project rules (short; full version in `CLAUDE.md` and `ecosys-audit/PROJECT_CONTRACT.md`)
- Protected references: `f77src/` (read-only), `f77example/`, `ecosys-ng-prod-examples/`. Work on staged copies.
- Never read `f77src/*.f` directly: use `uv run ecosys-audit/scripts/f77query.py outline|show|grep|common|loops`.
  Verified argv: `audit/manifest/command_registry.json`. Always `uv run` (PATH `python` is MSYS2).
- Wrong-science traps: legacy is `-r8 -i4` with no IMPLICIT (every real is f64); array lower bounds are
  often 0 and Fortran is column-major; `f77src/redist_utf8.f` is NOT the reference (`redist.f` is).
- Builds/tests/verbose commands only via `run_logged.py`. Agents never commit or push (the controller does).
- A mapping or coverage number is not correctness; only `check_gate.py` decides a gate.
