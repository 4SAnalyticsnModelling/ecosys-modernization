# evidence/ — in-repository evidence store (git-ignored except this file, manifest/ and schema/)

The execution plan names `D:\ecosys-evidence\...`. By user decision (2026-09-25) the project is standalone,
so every such path maps here:

| Plan path | Here | Content |
|---|---|---|
| `D:\ecosys-evidence\legacy\` | `evidence/legacy/` | legacy oracle binary, 30-yr reference outputs, legacy dumps (P0.3, P2.1) |
| `D:\ecosys-evidence\oracle-src\` | `evidence/oracle-src/` | instrumented copy of the in-build Fortran (P2.1). `f77src/` stays untouched |
| `D:\ecosys-evidence\checkpoints\<binding>\` | `evidence/checkpoints/<binding_id>/` | strict daily checkpoints (P2.9) |
| — | `evidence/runs/<run-id>/deck/` | staged deck copies used by `run_ottawa.py` |
| — | `evidence/dumps/<run-id>/` | Zig state dumps (latest 2 campaigns + any cited) |
| — | `evidence/gcov/` | `-O0 --coverage` build and gcov output (P2.4) |
| — | `evidence/timing/` | timing-run records (P0.4, P7) |

## Rules (plan section 6)
- Every stored artifact gets a committed manifest entry in `evidence/manifest/` (sha256, size, producer
  argv, compiler/flags, deck hash, binding_id). An artifact without a manifest entry is not citable.
- Anything cited in `audit/` must never be deleted. Survey checkpoints are deleted after ranking.
- `run_ottawa.py` refuses to start below the free-space floor or after a slow D: read probe.
- Schemas for dumps live in `evidence/schema/` (committed).
