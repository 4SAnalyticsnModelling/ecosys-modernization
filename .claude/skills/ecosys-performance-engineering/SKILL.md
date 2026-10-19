---
name: ecosys-performance-engineering
description: "Measure build/runtime/memory and optimize equivalent accepted work; use for diagnosed expensive paths."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Profile accepted representative seasonal/management windows and slow hours before editing.
Separate cold/warm/incremental build, simulation CPU/wall, logging/checkpoint I/O and peak memory.
Record hardware/toolchain/target/threads/precision/output/binding. Use comparable resources and
at least three benchmark repeats when deciding speed; report median/spread and individual runs.
Prefer redundant copies/allocations/log formatting/I/O/build overhead first. Preserve required
outputs, validation and numerical semantics; no fast-math or relaxed convergence speed claims.
Check bit-identical fixed-window results for semantics-preserving changes; changed numbers
need scientific parity/feature review. Measure verified progress and repeated work.
