---
name: ecosys-source-navigation
description: "Locate legacy statements, COMMON state and matched-state oracle inputs using f77index tools."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Use `./scripts/project.sh exec` for generated indexes/reports; ordinary narrow reads are read-only.
If the index is absent, run `f77index.py --root . --out audit/manifest/f77index.json`; verify
source hashes and zero unclosed loops. Reuse a valid index rather than rebuilding each cycle.
`f77query.py outline grosub.f --depth 1`; `show redist.f --lines 6870-6900`;
`grep 'ZNH4FA\(' --limit 40`; `common BLK13A --users`; `loops uptake.f`.
Use outline then relevant ranges including definitions/callers; never dump whole huge routines.
`tracecov.py` reports claimed line coverage, not semantic proof. `bindcheck.py` is a name/shape
worklist, not complete binding verification. Include out-of-build/dormant scope explicitly.
`kernelgen.py STOMATE --root . --scope referenced` emits a legacy driver/layout. Check snapshot
size; map Zig fields from verified bindings, never name guesses. Discover current-host compile
argv; use generated `.build.sh` on POSIX and `.build.ps1` on Windows. Implicit reals are f64; respect
zero lower bounds, column-major layout, COMMON/EQUIVALENCE, SAVE/DATA and fixed-form columns.

Batch source reads with `project.sh code`; use `tools/autonomy/code-reading.md` for code mode
and `project.sh codemod` for previewed, hash/count-checked mechanical edits.
