---
name: ecosys-zig-safety-design
description: "Audit Zig ownership, NaN/Inf/domain guards, fatal error propagation and ReleaseFast safety; use for numerical hazards and production hardening."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Trace callers/callees and state ownership before editing. Prefer explicit state/parameters,
owned scratch and narrow APIs. Audit undefined/unreachable, unchecked indices/casts, aliasing,
whole-array copies, blanket catches and debug-only physical assertions. Encode static shapes;
validate dynamic dimensions/domains before hot paths. Propagate contextual failures.
Prove rejected trials and failed allocations/I/O clean up without partial publication. Reuse
scratch and measure memory/copies. Keep unrelated formatting out of scientific diffs.
Check affected safety-enabled and ReleaseFast behavior; changed floating-point order requires
parity evidence. Separate re-derivation is required for architecture and acceptance changes.

Apply [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md): explicit finite
and domain checks before hazardous operations, reductions/comparisons and state/I/O commitment.
Audit finite-input overflow, unchecked float modes and catches that replace failures with numbers.
Invalid private probes may recover transactionally within budget; invalid input/committed state
or unrecoverable failure must exit the simulation nonzero with context and preserve the last valid checkpoint.
No debug-only guards or reliance on floating-point traps. Prove production detection using
runtime-supplied NaN, both infinities and invalid-domain/overflow cases; check no contaminated
history, state, output or checkpoint survives. Finite values also require physical admissibility.

Batch source reads with `project.sh code`; use `tools/autonomy/code-reading.md` for code mode
and `project.sh codemod` for previewed, hash/count-checked mechanical edits.
