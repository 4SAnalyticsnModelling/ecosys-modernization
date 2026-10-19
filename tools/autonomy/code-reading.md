# Fast code reading and mechanical edits

Use one batch of exact requests instead of serial broad reads:

```sh
./scripts/project.sh code --json '[{"op":"outline","path":"ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig"},{"op":"search","path":"ecosys-ng/src/soil/nutrients/nitrogen_state_update.zig","pattern":"InsufficientSoilMineralNitrogen"},{"op":"outline","path":"f77src/nitro.f","depth":1}]'
```

Then request `show` with `start`/`end` around the relevant declarations/branches. Every result
includes source hash, line numbers and explicit truncation. Fortran uses the checked f77index;
rebuild it through logged exec if absent/stale. Fortran `f77query` remains the richer source
for loop bodies, COMMON users and prose sections. Use `rg -n`/`rg --files` for cross-file search.
Zig outlines are lexical, Python outlines use AST; neither proves dependencies or semantics.
Read definitions/callers and complete relevant logical statements before editing.

Native code mode: batch independent tool calls using awaited `Promise.allSettled`; inspect
all results. Sequence dependent reads, edits and tests. Keep full logs on disk and return
only decisive ranges/findings. Do not evaluate retrieved code as trusted orchestration.

`./scripts/project.sh codemod --spec .tmp/edits.json` previews a unified diff. The JSON array
contains `{path,sha256,old,new,count}` per file. Apply with `--apply` only after reviewing the
preview. All hashes/counts are checked before any write; protected reference trees are refused.
Each file writes atomically; interrupted multi-file changes require reconciliation, not blind
reapplication. Codemods never replace semantic review, compiler checks or regressions.
