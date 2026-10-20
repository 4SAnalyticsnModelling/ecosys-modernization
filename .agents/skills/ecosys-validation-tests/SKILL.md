---
name: ecosys-validation-tests
description: "Choose discriminating regression, coupling and event checks; use after fixes and before integration."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Choose the smallest test that would fail the plausible wrong implementation. Run matched-state
kernel → affected coupling/conservation → simulated event window → full required suites.
Account for both Zig roots (`module_index.zig`, `ecosys_ng.zig`), filters, counts and skips.
Use `zig build test -Dtest-filter=<text> --cache-dir .zig-cache` to filter both roots.
For full-suite acceptance use the named `suite_check.py` cases; filtered/zero-test runs cannot qualify.
Use approved parent snapshots; cross-revision replay cannot certify earlier trajectory.
Include freeze/thaw, dry/tiny pools, management, no vegetation, leap/year reset, malformed I/O,
allocation failure, solver exhaustion and complete restart where affected. Production-critical
checks must survive ReleaseFast. Test adapters against missing/duplicate keys, truncation,
nonfinite/D-exponent/unit/cumulative errors. Record exact receipts; zero-test exit is not proof.

For [numerical edge cases](../../../.agent/playbooks/convergence-and-balance.md), select affected
fixtures: zero/no source and zero/incoming source, trace pools, both sides of floors, cancellation,
both defect signs, locally offsetting errors, shared supply and cumulative bias. Vary units,
area/population and restart/substep grouping where relevant. Assert benign success without false
errors and justified finite evaluation counts; real defects still fail with complete rollback.
Do not turn a failing fixture into a pass by changing its allowance or expected physics.
For affected finite-state paths inject runtime NaN/both infinities, invalid domains and
finite-operand overflow in input/restart/arithmetic/solver components, including reduction-hidden
faults. Verify bounded private recovery or fatal nonzero exit, atomic rollback and preserved
last-valid checkpoint in ReleaseFast too. Test a finite impossible pool and invalid spike/reversal
despite net closure, alongside a legitimate large event that must pass its physical checks.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
