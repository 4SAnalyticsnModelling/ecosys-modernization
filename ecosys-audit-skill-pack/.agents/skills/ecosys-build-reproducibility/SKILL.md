---
name: ecosys-build-reproducibility
description: "Verify pinned compilers, actual build commands, runtime packaging, restart integrity and reproducible ecosys-ng production runs. Use for ReleaseFast compile issues, environment drift and clean-room release checks."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Reproduce one precisely identified model

Discover the project build definition and exact supported flags. Record Zig version, target, dependency hashes, Fortran compiler/flags, required environment and external data. Do not assume current web documentation matches the pinned toolchain or upgrade it silently. Confirm what the project calls `ReleaseFast` and which production artifact is built.

## Build evidence
Record a clean isolated build with its full command, cwd, log, exit code, elapsed time and peak memory when available. Separately measure cached and incremental builds. Do not delete a developer's shared cache to simulate "clean"; use dedicated recorded build/cache locations supported by the actual toolchain. Verify that no stale executable from a prior successful build is run after a failure. Hash and identify the actual binary used by every run.

Use safety-enabled and optimized test configurations appropriate to the pinned version. Confirm all intended tests/modules are included. Audit dependency/platform/link settings and generated assets. Treat compiler warnings or version-specific behavior as evidence to review, not noise to suppress.

## Runtime reproducibility
Stage the two authoritative decks without changing inputs and direct outputs into unique run directories. Record final simulation time, files/key counts, final state, exit status and physics checks. A process that exits early with code zero has not completed. Check repeatability with identical inputs and the declared thread policy; document platform/compiler differences rather than claiming universal bitwise reproducibility.

Test checkpoint/restart against uninterrupted execution, including management calendar, solver-persistent state, random seeds if used, daily/cumulative counters and pending exchanges. Version checkpoint schemas and reject incompatible/truncated data cleanly. Use atomic replacement where supported and verify write/flush/rename failures cannot corrupt an existing valid checkpoint. Durable publication may fail even though memory/resource cleanup must succeed; report that error honestly.

## Package without publishing
Prepare run/build instructions, required inputs, tested platforms, known limitations, version information and checksums for the exact local candidate. Ensure paths are portable within the declared environment, dependencies are pinned and no credentials/private unrelated files enter artifacts. Do not tag, push or publish unless the user explicitly authorized it.

## Done
A fresh isolated checkout/staging environment using the documented toolchain and inputs reproduces the accepted build/run within the declared numerical policy. Unavailable environment verification remains a recorded limitation, not a claimed pass.
