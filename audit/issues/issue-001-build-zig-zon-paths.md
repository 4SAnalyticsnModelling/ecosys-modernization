# Issue 001 -- build.zig.zon .paths lists nonexistent directories/files

Status: **FIXED 2026-09-18** in `D:\ecosys_modernization` (the master project). See resolution.
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
Cause and focused patch: hypothesis (a) turned out to be half right, but for a different tree. The OneDrive reference copy's `build.zig` genuinely does declare `tools/compare_legacy.zig` and `tools/grid_inv_harness.zig` executables wired into a `check` step, and `tools/` and `runtime_parameters/` genuinely exist there. But `D:\ecosys_modernization\ecosys-ng\build.zig` (the master project's own build file) has never had that `check` step or those executables -- it only ever defined the `ecosys_ng` module/executable and `install`/`run`/`test` steps. So `.zon`'s comment was describing the *other* tree, not this one. Separately verified `runtime_parameters/` is not a real functional gap for this tree either: the one source comment citing `runtime_parameters/starts_organic.txt` (`src/soil/organic/parameters.zig:303`) turned out to describe a test-only default-provider function with zero production impact -- the real production data comes from the deck's own `soil_organic_initialization_parameters.txt` via the ordinary runscript file records. Fixed by trimming `build.zig.zon`'s `.paths` to `build.zig`, `build.zig.zon`, `src` -- what this tree's build actually needs -- with an inline comment recording why the other four entries were removed rather than fabricated.
Before/after results: before, `.paths` listed four nonexistent entries alongside a comment describing tooling this tree's `build.zig` does not have. After, `.paths` matches this tree's actual build exactly.
Regression added and actually executed: none needed -- this is package-manifest metadata, not executable logic; `zig build test` was already unaffected either way (confirmed both before and after this session's fixes).
Invalidated evidence and rerun dependencies: none.
Independent reviewer: none yet.
Remaining limitation or final disposition: RESOLVED for `D:\ecosys_modernization` as it stands. Noted but explicitly NOT done: porting the OneDrive tree's `tools/compare_legacy.zig` (a legacy-vs-Zig output comparator) and `grid_inv_harness.zig` into the master project. That tooling would be directly useful for this project's output-comparison work, but importing it is a deliberate feature addition with its own scope and risk (unknown size/dependencies, needs its own `build.zig` wiring and review), not a manifest-accuracy fix -- left for explicit future direction rather than done unprompted.
