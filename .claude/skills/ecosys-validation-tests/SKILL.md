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
Use approved parent snapshots; cross-revision replay cannot certify earlier trajectory.
Include freeze/thaw, dry/tiny pools, management, no vegetation, leap/year reset, malformed I/O,
allocation failure, solver exhaustion and complete restart where affected. Production-critical
checks must survive ReleaseFast. Test adapters against missing/duplicate keys, truncation,
nonfinite/D-exponent/unit/cumulative errors. Record exact receipts; zero-test exit is not proof.
