## Workflow: 4-agent swarm (since 2026-09-25) -- read first
Work runs through the swarm: SENTINEL routes, PATHFINDER investigates, FORGE implements,
SAGE adjudicates science and reviews every production-science change. Current state:
`.agent/state.md`. Frontier: `.agent/frontier.json` (only `update_frontier.py` writes it).
How it operates: `.agent/README.md`. Plan: `ecosys-ng_ottawa_qualification_execution_plan.md`.
If your prompt names a role or `ECOSYS_SWARM_ROLE` is set, follow `.agent/roles/<role>.md`
and your task file only; do not load skills, memory or files your task does not name.

The previous Claude-lead / Pi-reviewer workflow (`WORKFLOW.md`, `herdr_cycle.py`,
`audit/handoff.md` checkpoints, `.pi/`) is retired and archived in
`archive/pre-swarm-workflow/`. Do not resume from it or act on its "next action".
Its scientific records (`audit/issues/`, `audit/runs/`, `audit/analysis/`) remain
evidence to re-verify, not fresh passes.

Use `run_logged.py` for builds/tests/verbose commands. Agents never commit or push.
No gate or frontier claim without `check_gate.py` / `update_frontier.py`. User decisions
are listed in plan section 8; never presume them.

<!-- ecosys-audit-skill-pack:begin -->
## ecosys Fortran-to-Zig audit
For this project, read `ecosys-audit/PROJECT_CONTRACT.md` and
`ecosys-audit/EVIDENCE_GUIDE.md` before source changes or scientific claims.
Start or resume from `.agent/README.md` and `.agent/state.md`.
Canonical portable skills are in `.agents/skills/`; shared resources are in
`ecosys-audit/`. Preserve the four authoritative directories in the contract.
Run focused tests during source audit; do not enter repetitive full production
ReleaseFast runs before the evidence gates pass. Preserve references and user
changes. Skills are instructions, not proof that this model has been audited.
<!-- ecosys-audit-skill-pack:end -->

## Source navigation tooling (added 2026-09-21)
Do not read `f77src/*.f` directly. Each file is one program unit of up to 13,179 lines
and the call graph is nearly empty, so paging a routine wastes context and teaches you
nothing. Use the `ecosys-source-navigation` skill; the tools are in
`ecosys-audit/scripts/` and verified commands are in
`audit/manifest/command_registry.json` under `analysis`.

- `f77query.py outline <file>` -- loop nest plus prose comments; turns 13,179 lines into ~109.
- `f77query.py show <file> --loop <label> | --lines N-M`, `common <BLK> --users`,
  `grep <re>` (reports enclosing unit and innermost loop), `units`, `loops`, `stats`.
- `tracecov.py` -- computed statement coverage, stale-hash and broken-path problems.
- `bindcheck.py` -- COMMON state inventory vs the Zig port; a worklist, not coverage.
- `kernelgen.py <ROUTINE>` -- matched-state gfortran oracle plus a byte-layout manifest.

Run all of them as `uv run ecosys-audit/scripts/<tool>.py` from the project root; PATH
`python` here is MSYS2 and is not what they are validated against. Rebuild the index with
`f77index.py` after any `f77src/` change.

Three dialect facts that silently produce wrong science if assumed wrong: the legacy build
is `ifort -r8 -i4` and **no `IMPLICIT` statement exists anywhere**, so every
implicitly-typed real is **f64**; array lower bounds are often 0, not 1, and Fortran is
column-major; `f77src/redist_utf8.f` is an out-of-build duplicate of `redist.f` and is not
the reference. `ifort` is not installed on this host -- gfortran 16.1 reproduces the
precision contract only, and its Fortran 2023 `SPLIT` intrinsic shadows this project's
`split.f`, so `soil.f` needs `EXTERNAL split` or `-std=f95`.

These tools parse text. They do not compile the model, prove equivalence, or decide a
gate; `check_gate.py` owns gate status and a coverage percentage is not a pass. Quote each
tool's own `limitations` field alongside any number you report.

