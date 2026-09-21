# Issue 075 -- `pond_inventory_transfer.zig`'s cross-file `CarrierVolumes` test literal was never updated when `issue-069` added a required `cell_area_m2` field, breaking the untargeted full test suite

Status: **CLOSED, FIXED -- 2026-09-21.** One missing `.cell_area_m2 = 1` field added to a single anonymous `CarrierVolumes` struct literal in `ecosys-ng/src/surface/pond_inventory_transfer.zig`'s test `"pond sidecars count canonical gas and chemistry mirrors exactly once"`. Test-only change; no production logic touched.

Owner: unassigned
Cross-references: flagged originally (untriaged) in `audit/HANDOFF-SUMMARY-2026-09-20.md` Section 7 by the `issue-074` implementing agent, who found it as a side effect while working a neighboring file and left it unfixed as out of scope. That note also asserted the break "predates and is unrelated to any of this session's water-carrier work" -- **this pass found that characterization is not accurate; see "Corrected provenance" below.**

## Failure signature

```
src\surface\pond_inventory_transfer.zig:465:10: error: missing struct field: cell_area_m2
        .{
        ~^
src\surface\pond_chemistry_transfer.zig:9:28: note: struct declared here
pub const CarrierVolumes = struct {
                           ^~~~~~
referenced by:
    surface_pond_inventory_transfer: src\module_index.zig:356:53
    test_0: src\index\surface_test_index.zig:102:15
```

Reproduced with (cwd `ecosys-ng`, Zig 0.16.0): `zig test src/module_index.zig --test-filter "pond sidecars count canonical gas and chemistry mirrors exactly once"`. Confirmed (per the original note) to also break the full untargeted `zig test src/module_index.zig` / `zig build test`; targeted/filtered tests elsewhere, `zig build`, and `zig build -Doptimize=ReleaseFast` are unaffected because this literal is test-only code inside a `test { ... }` block that only the full-suite compilation unit pulls in alongside the failing one.

## Root cause

`ecosys-ng/src/surface/pond_chemistry_transfer.zig`'s `CarrierVolumes` struct (line 9) has a required (no-default) field `cell_area_m2: f64`, added by commit `89e17ba` ("issue-069: fix pond_chemistry_transfer and gatherTillageSurfaceAmounts exact-zero carrier guards", 2026-09-20). That commit's own message states "All 11 pre-existing `CarrierVolumes` test literals updated with `cell_area_m2=1`" -- but all 11 of those literals live inside `pond_chemistry_transfer.zig` itself. It missed a **12th, cross-file** call site: `pond_inventory_transfer.zig`'s test `"pond sidecars count canonical gas and chemistry mirrors exactly once"` (lines 460-480), which calls `chemistry_transfer.acceptedSurfaceTransfer(...)` with its own inline anonymous `CarrierVolumes` literal (lines 465-477) rather than a `const carriers: CarrierVolumes = .{...}` declared alongside the others. A grep/sweep scoped to one file would not have found this sibling.

This is a genuine stale test literal exactly as the handoff described -- the test asserted (implicitly, via the anonymous literal) against an old, now-incomplete shape of `CarrierVolumes` because a sibling struct gained a new required field elsewhere in the same commit's sweep. No production logic was touched or needed changing; the fix supplies the missing field with the same neutral value (`1`) used by all 11 sibling literals fixed in the original commit, which does not fall in the newly-widened `(0, 1e-6]` legacy-`ZEROS2` floor band, so it does not change this test's expected values.

## Corrected provenance (this pass's finding)

The original note in `HANDOFF-SUMMARY-2026-09-20.md` Section 7 states this break "[reproduces] even at commits before this session's fix chain started (confirmed via `git stash`/retest at git HEAD `ce0564e`)" and concludes it "predates and is unrelated to any of this session's water-carrier work."

Checked this pass via `git log --oneline -- ecosys-ng/src/surface/pond_inventory_transfer.zig` (only ever touched by the initial `514dd68` "Add ecosys-ng Zig implementation" commit, never since) and `git merge-base --is-ancestor 89e17ba ce0564e` (exit `0`, confirming `89e17ba` *is* an ancestor of, i.e. already present at, `ce0564e`). So:

- The break did **not** predate the 2026-09-20 session's water-carrier work as a whole -- it was directly **introduced by that same session's `issue-069` commit (`89e17ba`)**, which is explicitly listed as part of that session's water-carrier fix chain in the handoff's own Section 2.
- What is accurate is narrower: the break predates the *later* `issue-072`/`073`/`074` sub-chain (commits `fcf94d9` through `e39f3a7`/`532f115`/`3c9f3bf`), since `ce0564e` sits between `89e17ba` and those. The original agent's `git stash`/retest at `ce0564e` correctly showed the break was already present before *their own* fix, but the broader claim that it predates "this session" and is "unrelated to any of this session's water-carrier work" overstates that -- `issue-069` is itself water-carrier work, from the same session.
- This does not change the fix (still a pure stale-test-literal correction, no production logic involved) or its safety, but the record is corrected here for anyone tracing causality later.

## Verification

Commands (cwd `ecosys-ng`, Zig 0.16.0), before fix: the exact filter above fails to compile with the error shown. After fix:

- `zig test src/module_index.zig --test-filter "pond sidecars count canonical gas and chemistry mirrors exactly once"` -> compiles and passes (52/52 in the grouped run this filter pulled in).
- `zig test src/module_index.zig --test-filter "surface pond inventories transfer atomically"` -> passes.
- `zig test src/module_index.zig --test-filter "REDIST L0 dry mineral settling"` -> passes.
- `zig test src/module_index.zig --test-filter "late invalid particulate inventory"` -> passes.
- `zig test src/module_index.zig --test-filter "carrier"` (broad sweep of every `CarrierVolumes`-adjacent test across the codebase) -> 184/184 passed.
- Full untargeted `zig test src/module_index.zig` (no filter) -- now **compiles and runs to completion** (previously failed at compile time before it could run at all). Result: `4354 passed; 1 skipped; 7 failed` (4362 total). The 7 failures are pre-existing, unrelated runtime test failures, not compile errors and not regressions from this fix:
  - `canopy.symbiosis.plant_symbiotic_fixation.test."production binds WTHR fire to root and canopy before one-shot inoculum publication"` -- `MissingHourlyScienceCall`
  - `soil.heat.solver_tests.test."final conservation refinement retains adjacent endpoints while free coordinates advance"` -- `TestUnexpectedResult`
  - `soil.heat.solver_tests.test."heat primary Newton yields only to measured recovery signals"` -- `MissingHeatDenseEnthalpyNewton`
  - `soil.heat.solver_tests.test."transition-optimized endpoint discovery full-scans before recovery or ceiling"` -- `TestUnexpectedResult`
  - `soil.heat.solver_tests.test."rejected mixed endpoint repricing preserves the current signed MJ vector"` -- `TestUnexpectedResult`
  - `io.output.production_integration_test.test."hourly soil water output includes accepted ground evaporation"` -- `MissingOutputTransactionIntegration`
  - `driver.outer_hour_transaction.test."production outer hour explicitly owns soil gas and pending surface ledger"` -- `TestExpectedEqual` (expected 1, found 0)

  None of these are in `pond_inventory_transfer.zig`/`pond_chemistry_transfer.zig` and none mention `CarrierVolumes`/`cell_area_m2` -- confirmed by grepping the full run log. The `soil.heat.solver_tests` cluster is consistent with this session's already-open, explicitly-escalated `issue-024`/`issue-068` phase-solver/heat-domain decision (Section 3 of the handoff); the other two failures are separate, out of this issue's scope and not investigated further here. This issue does not attempt to fix or re-triage any of the 7; it only establishes that the compile break itself is gone and nothing it touched regressed.

`git status --short` before commit showed exactly one changed file: `ecosys-ng/src/surface/pond_inventory_transfer.zig`.

## Disposition

`legacy-defect-corrected` does not apply (this is Zig-native test code with no Fortran counterpart); classified as a plain test-maintenance fix, no feature/disposition entry needed since no production statement, equation, or binding was touched. Issue **CLOSED**. `HANDOFF-SUMMARY-2026-09-20.md` Section 7 updated to point here and marked resolved, with the provenance correction above.
Independent reviewer: not yet done.
