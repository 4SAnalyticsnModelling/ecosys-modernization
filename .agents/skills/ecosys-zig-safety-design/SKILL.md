---
name: ecosys-zig-safety-design
description: "Apply the project’s Zig principles to ownership, APIs, error paths, memory, maintainability and ReleaseFast safety. Use for code review, refactoring proposals, unsafe constructs and production hardening."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Make invalid state difficult to create and wrong results difficult to hide

Read the contract's complete philosophy table and the pinned Zig documentation. Audit actual code before introducing abstractions. Favor focused modules with explicit dependencies: immutable configuration/parameters, owned persistent state, bounded scratch/workspaces, narrow process interfaces and a single commit point for step acceptance. Do not reintroduce mutable global model state or a duplicate "fast" physics engine.

## Types, contracts and errors
Encode compile-time dimensions/configuration constraints where practical; validate runtime dimensions/units/domains at interfaces. Use explicit enums/error sets and clear ownership. Name or document units, coordinates and time levels. Avoid excessive type/comptime machinery that worsens compiler cost without reducing defects.

Audit `undefined`, `unreachable`, optional unwraps, pointer/integer/alignment casts, slices/strides, aliases, integer overflow and narrowing conversions. Establish proof obligations at every unchecked hot-path boundary. Never use `catch unreachable`, catch-to-zero or ignored error results for environmental, allocation, I/O or solver failures. Return actionable errors with time/cell/process context and a nonzero final status.

## Memory lifecycle
Identify each allocator/owner, allocation frequency, maximum size and deinit path. Check partial initialization, early returns, nested allocation failure and ownership transfer. Use correct `defer`/`errdefer` patterns for the pinned version. Cleanup must not require fresh allocation to succeed. Test leaks/double frees/use-after-free and allocation-failure paths with supported facilities. Protect existing valid checkpoints when a new write fails.

Reuse per-model/per-worker scratch where valid, reserve bounded buffers, avoid per-layer/iteration heap churn, giant stack arrays and copying full model state accidentally. Transactional solver workspaces must preserve rollback without unbounded copying. Measure tradeoffs rather than assume heap, stack, arena or static storage is always best.

## Production checks and maintainability
Explicit input, finite-state, domain and conservation checks needed for scientific safety must remain effective in `ReleaseFast`. Safety-enabled tests complement, not replace, optimized-build tests. Inspect floating-point mode separately; do not apply global fast-math as an optimization shortcut. Pin toolchain/dependencies and use `zig fmt` from that toolchain where available. Make minimal semantic diffs; no broad style rewrite during a translation investigation.

Document public interfaces, initialization/deinitialization order, error guarantees, threading rules and checkpoint format/version. Centralize verified constants and remove obsolete duplicate implementations only after provenance and tests demonstrate safety. Keep test-only references clearly separate from the production path.

## Done
Every high-risk construct has evidence of validity or a tested fix, ownership/failure paths are reviewed, required production checks work in optimized mode and refactors preserve science with measured resource consequences.
