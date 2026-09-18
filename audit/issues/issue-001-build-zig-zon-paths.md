# Issue 001 -- build.zig.zon .paths lists nonexistent directories/files

Status: NOT_ASSESSED (severity: low-moderate, packaging/documentation, not proven to block local `zig build`)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979

Failure signature and first bad time/location/process:
`ecosys-ng/build.zig.zon` (.paths field) lists `tools`, `runtime_parameters`, `README.md`, and `MIGRATION.md`. None of these exist under `ecosys-ng/` (verified 2026-09-17 via `Test-Path`, all four returned False). The .zon file itself carries an inline comment claiming `build.zig` declares two executables rooted at `tools/compare_legacy.zig` and `tools/grid_inv_harness.zig` wired into a `check` step -- but the current `ecosys-ng/build.zig` (43 lines) has no `tools` reference and no `check` step at all; it only defines the `ecosys_ng` module, the `ecosys_ng` executable, an `install`/`run` step, and a `test` step.

Legacy/Zig source anchors: `ecosys-ng/build.zig.zon` lines 1-20; `ecosys-ng/build.zig` (whole file, 43 lines). No Fortran counterpart (build metadata only).

Scientific/output impact: none directly -- `zig build test` completed (see issue-003) so this is not currently blocking local test/build invocation. It does affect `zig build` package-fetch validation for any consumer that depends on this package via the Zig package manager (missing declared paths are typically an error in that path), and it is stale/misleading documentation of intended tooling (a legacy-vs-Zig output comparator and a grid-inversion harness) that either was never added or was removed without updating the manifest.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: `Test-Path ecosys-ng/tools`, `Test-Path ecosys-ng/runtime_parameters`, `Test-Path ecosys-ng/README.md`, `Test-Path ecosys-ng/MIGRATION.md` from `D:\ecosys_modernization` -- all False, 2026-09-17.
Input/state provenance: initial repository state at candidate-001 snapshot; no edits made.
Hypothesis: either (a) `tools/compare_legacy.zig` and `tools/grid_inv_harness.zig` are planned-but-not-yet-written comparison/inversion tooling directly relevant to `ecosys-output-comparison`/`ecosys-divergence-diagnosis` work, and the .zon comment is forward-looking documentation left behind after a partial revert, or (b) the paths list is simply stale and should be trimmed to `build.zig`, `build.zig.zon`, `src`.
Stop/resource budget: one read pass of build.zig.zon/build.zig (done); resolution deferred to G0 completion, not blocking G1 source-reading work.

## Experiments
1. Read `build.zig.zon` and `build.zig`, confirm mismatch, confirm `tools`/`runtime_parameters`/README/MIGRATION absent via `Test-Path`. Result: mismatch confirmed as described above. Next action: leave open, do not fabricate the missing files or silently trim `.paths` without understanding whether `tools/compare_legacy.zig` was intentionally planned.

## Resolution
Cause and focused patch: not yet determined -- open.
Before/after results: n/a
Regression added and actually executed: n/a
Invalidated evidence and rerun dependencies: none
Independent reviewer: none yet
Remaining limitation or final disposition: UNRESOLVED. Does not block G1 source-reading/testing. Should be resolved before any G4 packaging/release step that relies on `zig build.zig.zon` path fidelity (e.g. distributing this as a fetchable package), and before deciding whether a legacy-output comparator tool is still owed as part of `ecosys-output-comparison` tooling.
