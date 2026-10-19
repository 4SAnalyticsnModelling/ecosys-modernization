---
name: ecosys-zig-safety-design
description: "Review Zig ownership, error handling and ReleaseFast safety; use for refactors and production hardening."
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

Batch source reads with `project.sh code`; use `tools/autonomy/code-reading.md` for code mode
and `project.sh codemod` for previewed, hash/count-checked mechanical edits.
