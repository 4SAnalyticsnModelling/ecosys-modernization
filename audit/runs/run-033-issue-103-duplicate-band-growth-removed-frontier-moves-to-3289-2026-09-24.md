# run-033 -- issue-103 fix: the duplicate NO3/PO4 band growth is removed; hours 3,277-3,288 are accepted and the frontier moves to 3,289 (2026-09-24)

Task `20260924-070126-c8a42446`.

## Change

- `soil_chemistry_convergence.zig`: removed the call to `updateFertilizerBandGeometry` (and its two issue-065 trace brackets) from the SOLUTE chemistry hour, and deleted the now-dead 343-line function. A comment at the call site records the legacy citation. Legacy grows each band once per hour in HOUR1's `DO 9986` (`hour1.f:4888-5155`, with NO3 at `:4992-5070`), and `f77query` finds no other `WDNOB`/`DPNOB`/`VLNOB` growth site. `fertilizer_band_production.prepareHour` already ports that loop for all three families (`prepareFamily` for each of `ammonium`, `nitrate`, `phosphate`) through the coordinator, and `consumeUndissolved` repartitions from its persisted relative changes.
- The stale doc on `fertilizerBandGeometryCarrierM3` now says it has no production caller. The helper and its issue-073 regression are kept, not deleted.
- New structural regression `ISSUE-103: the SOLUTE chemistry hour grows no fertilizer band outside the HOUR1 coordinator`. It slices the production source between `applyFertilizerDissolution` and `publishHourlyChemistry` and forbids `ecosys.fertilizer_band_nitrate_phosphate.`, `updateFertilizerBandGeometry(`, `.prepareFamily(` and `.activateBandFromApplication(`. It would have failed on the removed call.
- Legacy timing check: the upward band extension into `L-1` (`hour1.f:5021-5025`) sets `DPNOB/WDNOB(L-1)` after `L-1`'s `VLNOB` was already computed in the same loop, so its volume fraction takes effect next hour. The removed pass applied it in the same hour.

## Verification

- Module test root: `audit/runs/issue-103-fix-tests/receipt.json`, exit 0, 2,338.4 s, **4385 passed / 1 skipped / 0 failed**.
- **The new regression lives in the executable test root, which the module suite never runs** (0 `soil_chemistry_convergence` tests in this run or the previous one). Run directly with `zig test --test-filter ISSUE-103 --dep ecosys_ng "-Mroot=src\ecosys_ng.zig" "-Mecosys_ng=src\module_index.zig"`: `audit/runs/issue-103-exe-root-tests2/receipt.json`, exit 0, **4/4 passed** including the ISSUE-103 test. The unfiltered executable root does NOT compile. That is a pre-existing ISSUE-090 fixture defect, filed as `audit/issues/issue-104-executable-test-root-does-not-compile.md` (`audit/runs/issue-103-exe-root-full/`).
- ReleaseSafe build: `audit/runs/issue-103-fix-build/receipt.json`, exit 0, 863.5 s, exe prefix `E2810A89DE72F6CB`.
- Prod-deck run (fresh staged copy of `ecosys-ng-prod-examples/`, no checkpoints): `audit/runs/issue-103-fix-run/receipt.json`, exit 1, 2,082.4 s. stderr SHA256 `DD57CDEF32ED8E9670424288673B471C791C88693369BDA76796558B94198A7D`.

## Result against the prediction registered before the run (`audit/runs/issue-103-fix-prediction/prediction-registered-before-run.txt`)

- Predicted: hour 3,277 accepted. **Confirmed.** `census_positive_control entries=3288 first_hour=1 last_hour=3288`, `across 3289 simulated hour(s)`. Day 137 closes with `daily conservation accepted: day=137 ... nitrogen=1.47e-14`.
- Predicted: layer-1 NO3 band fraction stays 0 at hour 3,277. **Confirmed**: `n103_layer1[chem_before_validate_carrier_volumes]` has `frac_no3_nb=1e0`.
- No prediction was made about the next failure.

## New frontier (issue-105)

**3,288 accepted, failing on attempted hour 3,289** (day 138, hour 1, 1998-05-18): `hourly science failed: ... scene_hour=3289 ... error=InvalidRootAqueousDiffusionInput`. This is not a conservation failure. The stage census now reports `executed: root_uptake_geometry`, the first root-uptake stage recorded as executing on this deck.

No gate is promoted.
