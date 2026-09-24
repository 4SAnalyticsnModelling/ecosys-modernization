# Issue 104 -- the executable test root (`src/ecosys_ng.zig`) does not compile; its tests have not been running

Status: **OPEN** (found 2026-09-24 during task `20260924-070126-c8a42446`). Blocks the Engineering-validation gate, which needs every test root to pass.

## Facts

- `build.zig:36-39` has two test roots: `module` (`src/module_index.zig`) and `executable.root_module` (`src/ecosys_ng.zig`), described as "a second module root, not reachable from src/module_index.zig".
- Every suite figure quoted in this repo (4380/4383/4385 passed) is from `zig test src/module_index.zig`, the first root only. `zig build test`, which would run both, is recorded as hanging (`audit/manifest/command_registry.json` `zig_targeted_tests.note`).
- A working direct invocation of the second root exists: `zig test --dep ecosys_ng "-Mroot=src\ecosys_ng.zig" "-Mecosys_ng=src\module_index.zig"` (cwd `ecosys-ng`). Forward-slash paths fail with `found another zig file '.zig' after root source file` (`audit/runs/issue-103-exe-root-tests/`). Backslashes work.
- With `--test-filter ISSUE-103` it compiles and passes 4/4 (`audit/runs/issue-103-exe-root-tests2/`, 23.9 s), because lazy analysis skips the filtered-out tests.
- Unfiltered, it fails to compile (`audit/runs/issue-103-exe-root-full/`, exit 1, 1.75 s):
  `src\ecosys_ng.zig:7295:48: error: no field named 'fertilizer_band_state' in struct 'driver.fertilizer_production_fixture.verifyApplication__anon_...'`, referenced from `src\driver\fertilizer_production_fixture.zig:113:20` and `:7:26`, with the struct declared at `:76`.
- Line 7295 is the ISSUE-090 wiring (`.fertilizer_band = &driver_context.fertilizer_band_state.*`). The ISSUE-100 wiring adds `initial_chemistry_state`, and the issue-100/103 TEMP_DIAGNOSTIC probes read `hourly_science_context` and `executed_weather_hours` from the same driver context, so the fixture will need those too.

## Consequence

None of the tests reachable only from `src/ecosys_ng.zig`, including every `src/stages/*.zig` test block (e.g. issue-073's `fertilizerBandGeometryCarrierM3` regression), is known to have run since at least ISSUE-090. They are NOT_ASSESSED, not passing.

## Next

Update `fertilizer_production_fixture.zig`'s anonymous driver context with the missing fields (test-only change), compile the unfiltered root, and record its pass/fail count as the second-root figure. Record the working argv in `command_registry.json`.
