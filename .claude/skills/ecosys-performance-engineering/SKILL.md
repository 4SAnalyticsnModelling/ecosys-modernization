---
name: ecosys-performance-engineering
description: "Measure build/runtime/memory and optimize equivalent accepted work; use for diagnosed expensive paths."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Begin runtime optimization only after complete strict Ottawa and F1–F5 scientific acceptance.
Before that, use timing only to diagnose a blocked correctness run. Then profile accepted
representative seasonal/management windows and slow hours before editing.
Separate cold/warm/incremental build, simulation CPU/wall, logging/checkpoint I/O and peak memory.
Record hardware/toolchain/target/threads/precision/output/binding. Use comparable resources and
at least three benchmark repeats when deciding speed; report median/spread and individual runs.
Prefer redundant copies/allocations/log formatting/I/O/build overhead first. Preserve required
outputs, validation and numerical semantics; no fast-math or relaxed convergence speed claims.
Check bit-identical fixed-window results for semantics-preserving changes; changed numbers
need scientific parity/feature review. Measure verified progress and repeated work.

Final F6 requires `performance_check.py` with current passing F1–F5 evidence: at least three paired complete 262920-hour runs,
strict ReleaseFast versus optimized precision-preserving Fortran, identical effective workload
and resources, median runtime ratio < 1 and nonoverlapping observed runtime ranges. Bind raw
receipts, full-output summaries and preserved executables; do not infer speed from partial runs.
See [qualification evidence](../../../ecosys-audit/qualification-evidence.md) for the benchmark schema.
