# run-038 -- issue-108 carbon fix: root-atmosphere gas exchange booked with legacy's input sign; the hour-3,289 carbon row closes (2026-09-24)

Task `20260924-132727-40bac6ee`.

## Defect and legacy rule

`soil/diagnostics/daily_gas_flux.zig` `combinedHourIncrement` computed the ecosystem net gas input as `boundary + root_withdrawal - atmosphere_to_root`. `HourlySpeciesActivity.signedComponentSumG` used the same minus. Its comment treated the result as "DAY gas output is positive ecosystem -> atmosphere". But `boundary` and the withdrawal term are input-signed, and the hourly cell ledger books the result as `carbon_net_input_g_c`.

- Legacy: `extract.f:714` `CO2A += RCOFLA - RCODFA` (RCOFLA = "root gaseous-atmosphere CO2 exchange", positive into the root). `redist.f:6530` `CIB=TCOFLA`, then `:6568` `CO2GIN=CO2GIN+CIB+CHB`, `:6573` `HCO2G=HCO2G+CIB`, `:6574` `UCO2G=UCO2G+CIB`. So the root-atmosphere exchange is ADDED to the input-signed budget.
- In-repo corroboration: the layer sidecar (`layer_local_conservation.zig:3117-3170`, "`T*FLA` is positive atmosphere to root") books it as an external gain, and no layer carbon row failed at hour 3,289 while the cell carbon row did.
- Measurement (run-037): the root vent was `atmosphere_to_root_c = -1.07581e-6`, and storage fell by exactly that amount, so the ledger is inward-positive. Subtracting it produced a booking error of 2 x 1.0758e-6 = the -2.1516e-6 residual.

## Change

- `combinedHourIncrement`: `+ root_atmosphere_exchange_g_per_h`, with the legacy citation. `signedComponentSumG`: `+ root_atmosphere_to_root_exchange_g`.
- Three existing tests encoded the old algebra and are reconciled with legacy-cited comments, not relaxed: DAY accumulator (C 2.5 -> 5.5, H 1.5 -> 2.5), current-hour activity (C 1.25 -> 2.75, H 0.75 -> 1.25), ammonia components (net 1.375 -> 1.625, N input 3.625 -> 3.875). Each new value is the same inputs under the legacy sign, recomputed by hand in the test comment.
- Scope note: the DAY gas accumulator (`accumulateHour`) uses the same function, so the daily gas outputs change wherever root venting is nonzero. That is intended (legacy `UCO2G += CIB`). Before this deck's first root hours the root term was 0, so earlier DAY outputs are unaffected.

## Verification

- Module suite `audit/runs/issue-108-fix-tests/receipt.json`: exit 0, 2,324.3 s, **4387 passed / 1 skipped / 0 failed**. All `daily_gas_flux` tests OK.
- Build `audit/runs/issue-108-fix-build/receipt.json`: exit 0, 864.2 s. exe prefix `281BE720B2716122`.
- Prod-deck run from a fresh copy: `audit/runs/issue-108-fix-run/receipt.json`, exit 1, 2,124.1 s. stderr SHA256 `827426D0B2D6C1E7442C827775C18436FF59E0E7C9B8D2FC9BA5A2FC2EEAE239`.

## Result against the prediction (`audit/runs/issue-108-fix-prediction/prediction-registered-before-run.txt`): CONFIRMED in full

- The hour-3,289 cell **carbon** failure row is gone.
- Hour 3,289 still fails on **calcium** `+9.194830904164196e-8`, **sodium** `+2.9103828126891383e-10` and **potassium** `+1.4915711942786913e-10`. These are bit-identical to run-036/037, so this change does not touch them.
- The frontier is unchanged at 3,288 accepted (`census_positive_control entries=3288`).

No gate is promoted.
