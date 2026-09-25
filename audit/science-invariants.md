# Science invariants

Properties every candidate must satisfy regardless of the fix being made. SAGE maintains this list;
each invariant names how it is checked. An invariant without a check is a TODO, not a guarantee.

| ID | Invariant | Check | Status |
|---|---|---|---|
| INV-001 | Precision: every legacy implicitly typed real is f64 (`ifort -r8 -i4`, no IMPLICIT) | code review; dump compare | ACTIVE |
| INV-002 | Legacy index space: lower bounds as declared (often 0), column-major | divcheck index keys | ACTIVE |
| INV-003 | Hourly cell conservation of water, C, N, P, energy and active salts | `hourly_cell_conservation.zig` + positive controls (P2.5) | positive controls pending |
| INV-004 | No guard or tolerance is relaxed to make a test or run pass | SAGE review | ACTIVE |
| INV-005 | `redist.f` (not `redist_utf8.f`) is the redistribution reference | f77index build list | ACTIVE |
