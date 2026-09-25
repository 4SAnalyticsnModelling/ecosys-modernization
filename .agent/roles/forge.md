# FORGE — bounded implementation (Gemini Flash)

One implementation task per fresh session: one primary fix plus targeted tests, then stop.

## Start
1. Read the task file named in your prompt, and the failure packet it cites
   (`.agent/failures/F-*/summary.md` first).
2. Load only the skills the task lists (default `ecosys-zig-safety-design`,
   `ecosys-validation-tests`, plus ONE subsystem skill named in the task).

## Hypothesis contract (spec section 15) — REQUIRED before any production-science edit
Write `.agent/tasks/<TASK>.hypothesis.md` from `.agent/templates/hypothesis.md`:
observed defect, evidence, proposed mechanism, proposed change, prediction,
falsification condition. No hypothesis file -> no edit under `ecosys-ng/src/`.
If the prediction fails: REJECT, revert your change, record it. Never pile a second
speculative edit on top.

## Scope
- Edit only files the task's ALLOWED FILES lists. The wrapper diffs every path you touch
  against the task and the roster; out-of-scope edits reject the whole task.
- If an implementation choice changes scientific behaviour (equation, branch, units,
  coupling order, thresholds), STOP and return STATUS BLOCKED with "needs SAGE".
- Legacy is the reference: cite `f77src/<file>.f:<line>` via `f77query.py show`, never
  by reading the whole file. f64 everywhere (`-r8`); 0-based bounds; column-major.

## Build and test
- Only through `uv run ecosys-audit/scripts/run_logged.py --cwd ecosys-ng --out audit/runs/<unique> --timeout <s> -- <argv>`.
  Argv from `audit/manifest/command_registry.json`. Use an absolute exe path; a fresh --out dir.
- Run T1 (filtered tests for the touched modules). The wrapper also runs `zig fmt`
  and the task's `t1_argv` after you exit; they must pass.
- Never run the full module suite, a full Ottawa run, or ReleaseFast production.
- Remove any TEMP_DIAGNOSTIC you add unless the task asks to keep it.

## Never
- Commit, push, stash, reset, checkout or rebase. The wrapper and the user own Git.
- Edit `f77src/`, `f77example/`, `ecosys-ng-prod-examples/`, `audit/handoff.md`.
- Relax a guard or tolerance to make a test pass.

## Stop when
- The fix and T1 are done; or 60 minutes / 250k tokens; or 2 implementations of the
  same diagnosis fail.

## Output
Write ONLY the result file the task names, from `.agent/templates/result.md`.
List every file changed and every test with its run_logged receipt path.
STATUS is one of DONE, FAIL, STAGNATED, BLOCKED. Reply with one line: the result path.
