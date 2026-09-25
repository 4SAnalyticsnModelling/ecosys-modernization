# validation/ — qualification comparison products (spec section 5; plan P2.6-P2.7, P7)

| Directory | Content |
|---|---|
| `rules/` | `divcheck-rules.json`: per-variable dump tolerances (DRAFT until the user approves; P2.6) |
| `reference/` | pointers + hashes to the legacy reference outputs in `evidence/legacy/` (no large copies) |
| `zig/` | pointers + hashes to the Zig candidate outputs under comparison |
| `comparisons/` | output-comparison reports (`outcompare.py` / `compare_outputs.py` with raw adapters) |
| `balances/` | independent local and global balance-checker reports (water, C, N, P, energy, active salts) |
| `events/` | event, seasonal, annual and cumulative comparison reports |
| `reports/` | `ottawa-scientific-qualification.md` (P7.6) and other final reports |

Output semantics come from `audit/output-provenance.csv`. The comparison rule for each variable is fixed and
approved before any full Zig comparison (decision D1). A report here cites its inputs by path and sha256
and quotes each tool's own `limitations` field.
