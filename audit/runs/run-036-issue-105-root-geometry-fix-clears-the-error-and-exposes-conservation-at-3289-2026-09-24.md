# run-036 -- issue-105 fix: root geometry is defined for every layer; the hour-3,289 error is gone, and the same hour now fails C/Ca/Na/K conservation (2026-09-24)

Task `20260924-104044-3fc27a08`.

## Change

- `plant/root/water_balance.zig`: the existing `rootUptakeGeometry` (already a faithful `uptake.f:526-538` port, including its `RRAD2M`/`DLYR`/`6.283*RTLGP` else-branch) is now evaluated, and its radius, path and area-per-radius published, for every root layer right after the rooted fraction. Previously it ran after the six hydraulic `continue` guards. The guards now apply to the hydraulic path only. The evaluation is unchanged except that the micropore fraction is guarded against a zero layer volume.
- Two regressions: a structural one (the radius publication precedes the water and conductivity guards, and there is exactly one geometry evaluation in the production loop, bounded before the test blocks), and a unit test of the unrooted-layer defaults.

## Verification

- Module suite `audit/runs/issue-105-fix-tests/receipt.json`: exit 0, 2,317.0 s, **4387 passed / 1 skipped / 0 failed** (both ISSUE-105 tests `OK`).
- ReleaseSafe build `audit/runs/issue-105-fix-build/receipt.json`: exit 0, 1,020.2 s. exe prefix `D204F3FE7A80D11A`.
- Prod-deck run from a fresh copy of `ecosys-ng-prod-examples/`: `audit/runs/issue-105-fix-run/receipt.json`, exit 1, 2,110.7 s. stderr SHA256 `3108D56DF4C5532180E84CDD12703FD25034A456B3ED9D8C8BD8C17D48294607`.

## Result against the prediction (`audit/runs/issue-105-fix-prediction/prediction-registered-before-run.txt`)

- Predicted: hour 3,289 no longer raises `InvalidRootAqueousDiffusionInput`, and the issue-105 error-path log does not fire. **Confirmed**: there are no `TEMP_DIAGNOSTIC issue-105` lines and no `hourly science failed`.
- Predicted: the census passes 3,289. **Refuted.** `census_positive_control entries=3288`. The same hour now ends in `HourlyCellConservationFailure`. The registered risk (newly active root exchange perturbing closure) is what happened.

## New failure at hour 3,289 (issue-108)

Cell 0 rows (`quantity`, `residual`, `effective_limit`):

| Quantity | Residual | Limit | Note |
|---|---|---|---|
| carbon | -2.1516191145432018e-6 | 1.36e-10 | `external_outputs=1.2294e-1` |
| calcium | +9.194830904164196e-8 | 2.40e-11 | |
| sodium | +2.9103828126891383e-10 | 2.46e-11 | |
| potassium | +1.4915711942786913e-10 | 2.46e-11 | |

Layer scope 2 carries the full Ca/Na/K residuals (+9.1949e-8, +2.877e-10, +1.460e-10). Layer 2 is the one whose root geometry the fix now defines, which fits root exchange running for the first time there. That is a hypothesis to test, not a finding. The carbon row's layer split is not printed.

The frontier stays at 3,288 accepted, failing on 3,289, but on a different defect. No gate is promoted.
