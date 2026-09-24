# run-034 -- issue-104: the executable test root compiles again; 107 passed, 1 failed, 1 hung, 6 never ran (2026-09-24)

Task `20260924-085645-5b125e5c`.

## Change (test infrastructure only; no science code)

- `ecosys_ng.zig`: removed the issue-100 TEMP_DIAGNOSTIC probes from the fertilizer dispatch (the `n_ledger[fertilizer_dispatch]` log and the two `after_fertilizer_publish` layer probes). issue-100 is fixed (run-031), and these probes made the phase read `hourly_science_context` / `executed_weather_hours`, which the fixture does not have. The other TEMP probes stay (gated on hour 3,277, logging only).
- `driver/fertilizer_production_fixture.zig`: the anonymous driver context now supplies the owners the fertilizer phase has read since ISSUE-090 and ISSUE-100: `fertilizer_band_state` (a real inactive `fertilizer_band_state.State`, 1 m row spacing because init rejects spacing <= 0), `initial_chemistry_state` (zeroed exchange and aqueous slices), and `runscript.soil_geometry_parameters.minimum_layer_thickness_m`. No banded application occurs on the fixture dates.
- `audit/manifest/command_registry.json`: new slot `commands.zig_executable_root_tests` with the working argv (backslash module paths). The file was re-serialized. A JSON-tree comparison against HEAD shows it is semantically identical apart from the new key.

## Result

`audit/runs/issue-104-exe-root-full2/` (the second run; the first, `issue-104-exe-root-full/`, used a 0 m row spacing, and tests 3-5 failed with `InvalidInitialFertilizerBandRowSpacing` before the fix):

- **Compiles** (this failed before: `audit/runs/issue-103-exe-root-full/`).
- 109 of 115 tests started. **107 OK**, including the three fertilizer production fixtures (3/115 lime, 4/115 gypsum, 5/115 organic).
- **1 FAIL: 71/115** `stages.hourly_heat_water_solute.test.fixed external hour recovery escalates through the full chain and stops on hard defects`. It expected the substep ladder `{1, 20, 32, 64}` (test at `hourly_heat_water_solute.zig:10555`) and found `{4, 20, 32, 64}`. The test dates from the initial import (`514dd68`). The first rung became 4 in `99234f1` ("Implement Fortran wthr.f NFH=4 universal substep baseline (issue-024)"). Because the test lives in the never-run root, it was never updated. The expectation is likely stale, but that is not verified against `wthr.f` here and the test is NOT changed. Filed as issue-106.
- **1 HUNG: 109/115** `stages.run_support.test.OutputTree creates the full structured layout under a fresh output root`. Its CPU rose continuously (355 -> 497 CPU-s over 180 s, and in the first run 487 -> 1,063 CPU-s over ~12 min) with no output. It follows 108/115 `second active run-log writer is rejected without stealing ownership`, which passed. `lockActiveRunLog` (`run_support.zig:322-331`) is a non-reentrant spin/yield lock with no timeout. The child `root.exe` was stopped deliberately after a snapshot (`stderr-snapshot-before-stop.log`), which the wrapper records as exit 1 and the zig driver as 255. Filed as issue-107.
- **110-115 NOT RUN.**

**This root is therefore NOT passing, and the Engineering-validation gate stays unmet.** This is the first measurement of the root since at least ISSUE-090.
