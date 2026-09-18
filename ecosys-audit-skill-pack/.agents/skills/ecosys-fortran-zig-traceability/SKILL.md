---
name: ecosys-fortran-zig-traceability
description: "Audit every Fortran logical statement, equation, branch and call against Zig with bidirectional provenance. Use for translation completeness, missing routines, index/precision errors or whole-codebase source audit."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Account for every behavior

## Build a semantic map
Start from the actual compiler-visible fixed-form program. Respect line continuations, labels, statement functions, includes, conditionally enabled lines and compiler-specific extensions. Assign stable IDs to routines, executable logical statements, equations/constants, control-flow edges, shared definitions and call sites. A multi-line statement is one logical unit; one Zig function may represent several legacy units and vice versa.

Build a call/dependency graph and two-way map: Fortran unit to Zig implementation/disposition; Zig production behavior to Fortran origin or approved-feature ID. Read entire routines plus required definitions/callers. Do not conclude completeness from names, file counts, successful compilation or a regex match.

## For each mapped unit
Compare operands, units, signs, constants and their precision, conversions, index bounds/offsets, array shapes, strides, loop order, iteration endpoints, branch conditions, short-circuit assumptions, initialization, update timing and side effects. Distinguish old state, trial state and committed state. Trace every argument and return/state write through its consumers.

Audit integer division, truncation/rounding, signed remainders, exponentiation types, implicit integer/real declarations, literal kind conversion and possible f32-to-f64 changes. Verify the actual precision/evaluation policy; wider precision is not permission to skip provenance. Check one-based and non-one-based arrays, ghost layers, inclusive DO bounds and zero-length ranges. Do not reorder reductions or coupled in-place updates without a separate numerical-impact review.

Check COMMON/EQUIVALENCE/SAVE/DATA/BLOCK DATA behavior, storage association, argument aliasing, pass-by-reference side effects, ENTRY/multiple entry paths, GOTO/early exits and implicit external interfaces as present. Trace hidden state through common blocks into the corresponding explicit Zig owner. A preserved equation fed stale or wrong state is a failed translation.

## Intentional differences
Use only the dispositions defined in the contract. For a replacement, map the old interface and all inputs/outputs, identify exactly which equations differ and link an independently reviewed feature dossier. New numerical methods do not excuse missing branches, dropped source terms or changed output definitions. Dormant code remains audited and explicitly categorized. A legacy defect correction gets its own minimal reproducer and approval, not a retroactive feature label.

## Test and close
For unchanged kernels, use matched inputs/states and tightly justified tolerances, including branch boundaries. Tests should discriminate plausible wrong translations such as sign flips or off-by-one mapping; synthetic fault injection must be isolated and restored. Add a regression for each defect before closing it. Record reviewer and current source hashes.

Done requires a reconciled complete inventory, no unresolved disposition in release scope, all state/call/output links accounted for and separate source-review versus test-coverage reports. A routine-level index alone cannot pass this skill.
