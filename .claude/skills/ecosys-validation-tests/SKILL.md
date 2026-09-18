---
name: ecosys-validation-tests
description: "Create a layered test strategy and discriminating regressions for ecosys-ng. Use before integration runs, after fixes, for edge/failure/restart tests and for validating the comparison tooling itself."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Validate cheaply before validating broadly

Build a test inventory linked to the source/equation/binding map. Discover the actual Zig build/test entry points and pinned APIs; do not assume that an unimported test is executed. Record discovered and executed test counts, skips and filters. A zero-test success is not evidence.

## Validation ladder
Use static review and compile-time checks, matched-state kernel tests, process tests, two-process/interface tests, solver/constitutive edge cases, one-step replay, short staged integration, representative seasonal boundaries and finally the required full production deck. Targeted tests run during source auditing; full production acceptance waits for the production-entry gate.

Construct Fortran reference extraction/adapters from preserved source or separate instrumented copies, with source hashes and their own tests. Do not alter the golden reference to fit Zig. Identify unspecified legacy behavior and compiler effects. Compare discrete outputs exactly and numerical quantities with level-specific justified tolerance.

## Required hard cases
Exercise index boundaries, empty optional inputs, malformed/truncated forcing, leap day/year reset, tiny/zero pools, dry/saturated soil, frozen/thawing soil, zero vegetation, abrupt management events and extreme but permitted forcing. Test negative or impossible inputs are rejected clearly. Check allocator failure and cleanup, parser/writer I/O errors, nonlinear exhaustion, restart equivalence and repeated execution. Use available supported diagnostics instead of claiming sanitizers/allocators the pinned toolchain lacks.

Test production-critical validation in `ReleaseFast` as well as safety-enabled configurations. A Debug-only assert cannot prove optimized production rejects invalid state. Check checksums/metadata do not confuse run start/end and stale files. Verify thread determinism or a predeclared parallel reduction envelope.

## Test the tests
Ensure raw-format adapters preserve D exponents, columns, time keys, missing-value semantics, cumulative resets and all rows. Create synthetic missing/extra columns, duplicate keys, truncation, NaN/Inf, sign errors and off-by-one bindings so validation fails for the right reason. Use isolated mutants/fixtures and never leave deliberately wrong code in the candidate. Code coverage alone does not establish numerical correctness.

## Artifacts and done
Record exact command/environment, source/deck digest, expected outcomes, executed counts, status, failures and logs. Every fixed defect has a discriminating regression; required layers and branches have accounted-for evidence. Missing coverage is recorded as a gap, not assumed solved by a passing long run.
