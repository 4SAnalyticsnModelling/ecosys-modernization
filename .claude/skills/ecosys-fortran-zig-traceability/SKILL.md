---
name: ecosys-fortran-zig-traceability
description: "Audit complete bidirectional statement/equation/control-flow provenance; use for source gaps and translation defects."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Use f77query outlines/ranges and `tracecov.py` to select unresolved units, then read complete
relevant statements, definitions and control edges. Map Fortran → Zig and Zig → legacy/DEV.
Check operands, constants/precision, units, signs, bounds/stride, branch/loop endpoints,
old/trial/committed timing, COMMON aliases and SAVE/DATA. Include dormant and out-of-build
scope with explicit dispositions; never inflate coverage through broad range claims.
Write stable unit/binding IDs and source hashes in `audit/traceability/`. Separate claimed
mapping, reviewed semantics and executed tests. An unresolved disposition blocks release.
Validate unchanged kernels with matched-state regressions and separately derive the result.

For [numerical hazards](../../../.agent/playbooks/convergence-and-balance.md), inventory unsafe
domains, nonfinite propagation, impossible states and transient spike/reset paths in legacy and
their Zig counterparts. Include shared/dormant paths with source, repair/DEV and test disposition.
Traceability requires explaining and correcting demonstrated defects, never blindly preserving
them; keep invalid legacy behavior as evidence and independently validate the Zig replacement.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
