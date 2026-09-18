---
name: ecosys-performance-engineering
description: "Measure and improve ecosys-ng compile time, ReleaseFast runtime and memory without sacrificing scientific parity. Use after correctness evidence or for a focused diagnosed build/runtime bottleneck."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Optimize accepted work, not less work

Read the current correctness gates, performance policy and exact baseline. Performance changes are provisional until their affected correctness tests pass. A faster run that drops science, changes output frequency, loosens convergence or changes precision is not an equivalent-work speedup.

## Establish fair measurements
Separate clean build, warm/cached build, representative incremental rebuild, simulation wall time, CPU time, I/O and peak memory. Record compiler/flags/target, hardware/OS, source/binary/deck hashes, solver/physics, precision, threads and exact commands. Use the optimized documented Fortran build, not its diagnostic build. Match workload, start/end dates, input data and required outputs.

Benchmark one-thread Zig versus one-thread Fortran first, then equivalent allocated-core configurations. Keep the machine free of other agent compiles/runs. Use a stated warmup and at least three measured repeats, store individual results and report medians/spread. Do not compare one noisy run with an old measurement from another machine. Record the historical Ottawa six-year <300 s target only when its exact scenario and hardware applicability are confirmed.

## Profile before patching
Identify the actual dominant costs: residual/Jacobian assembly, factorizations, expensive constitutive evaluations, retries, data movement, allocations, output formatting or scheduler overhead as evidence shows. Instrument total and worst-hour solver work. Profile memory and per-thread replication. Binary size and shorter variable names are not runtime-performance targets.

For compiler bottlenecks, measure large generic/comptime instantiations, excessive inlining, monolithic generated code and build graph invalidation using supported tooling. Preserve the pinned compiler; a proposed upgrade is a separately tested compatibility change, not an unrecorded fix.

## Optimize incrementally
Prefer verified workspace reuse, eliminating redundant computation/copies, appropriate data layout/loop order, efficient sparse/banded operations when structurally justified, scoped specialization and output buffering. Validate compiler vectorization/CPU-target assumptions. Protect numerical evaluation order and exact couplings; reassociation, parallel reductions or relaxed math need their own accuracy evidence.

Parallelize independent grid work with explicit ownership and deterministic exchanges. Preserve dependency-ordered tile/phase traversal where required by the current model. Verify supported `--threads` behavior rather than assume a flag works. Test reproducibility across repetitions and declared thread counts and measure memory overhead/speedup saturation.

## Acceptance
Record before/after source digests, profiles, resource results, regression outcomes and final production comparison. The desired same-work runtime ratio is Zig/Fortran <=1 on the matched benchmark, with measurement uncertainty reported; do not promise or claim a universal language-level speed advantage. Report compile-time and memory outcomes separately. If a target remains unmet, keep that criterion failed/blocked rather than weakening physics to pass.
