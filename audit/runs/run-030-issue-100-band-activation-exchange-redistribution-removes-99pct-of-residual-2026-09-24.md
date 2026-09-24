# run-030 -- issue-100 fix: redistributing exchangeable NH4 on NH4-band activation removes 99.23% of the hour-3,276 residual (2026-09-24)

Task `20260924-021525-7f4d4a24`.

## Defect and legacy rule

When a new NH4 band is initialized, `hour1.f:303-334` sets `DPNHB`/`WDNHB` and `VLNHB`/`VLNH4` for every layer, and then, in the same `DO 50 L` loop, "REDISTRIBUTE NON-BAND, BAND SOLUBLE, EXCHANGEABLE NH4 STATE VARIABLES WITH CHANGES IN NH4 BAND VOLUME" (`:322-334`): `XN4T=XN4+XNB`, `XN4=XN4T*VLNH4`, `XNB=XN4T*VLNHB`. ISSUE-090's activation (`hourly_fertilizer_band_geometry.activateFromApplication`, called from `fertilizer_management_dispatch.applyNitrogen`) ported the geometry (`:303-320`) but not the redistribution. The established repartition in `fertilizer_band_production.consumeUndissolved` covers band growth (`relative_non_band_change <= 0`) and is never driven by an activation. run-029 measured the result: a pure fraction re-base of -0.0671468785 g N.

## Change (bounded)

- `fertilizer_management_dispatch.zig`: a new `redistributeExchangeAmmoniumOnBandChange`. ecosys-ng stores exchange per Mg of each zone's own soil, so the legacy extensive split becomes the layer-mean concentration `c_nb*f_nb_old + c_b*f_b_old` in both zones, or zero in a band whose new fraction is 0. This conserves `c_nb*f_nb + c_b*f_b` exactly. `applyNitrogen` snapshots every layer's NH4 zone fractions before `activateBandFromApplication(.ammonium)` and redistributes every layer afterwards. The input is an optional `soil_cation_exchange_mol_per_megagram` field, the same pattern as ISSUE-090, so existing callers and literals are unchanged.
- `ecosys_ng.zig`: production supplies `initial_chemistry_state.cation_exchange_mol_per_megagram`.
- Three regressions: band creation with run-029's measured values (conserved to 1e-14, band = layer mean, and the pre-fix loss reproduced as exactly -0.0671468785121912); band disappearance merging into the non-band zone; rejection of non-partitioning fractions.

**Deliberately NOT changed (queued):** the aqueous half of the same legacy block (`:326-332`, `ZNH4S/B` and `ZNH3S/B`) and the NO3-band counterpart. ecosys-ng holds aqueous N both as zone-extensive transport amounts and as `chemistry.aqueous` concentrations. Which one is authoritative at the publish is unverified, and the census showed no aqueous loss at the publish, so this is a faithfulness question rather than this conservation defect.

## Verification

- Full unit suite (`zig test src/module_index.zig` via `run_logged.py`): `audit/runs/issue-100-fix-tests/receipt.json`, exit 0, 2,367.6 s, **4383 passed / 1 skipped / 0 failed**. That is the previous 4380 plus the 3 new tests, all `OK` at `2165-2167/4384`. One root, Debug, one platform; this is not the release test matrix.
- ReleaseSafe build: `audit/runs/issue-100-fix-build/receipt.json`, exit 0, 1,027.2 s. exe SHA256 prefix `75BAE72C372FE4F5`.
- Prod-deck run from a fresh staged copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/`, no checkpoints: `audit/runs/issue-100-fix-run/receipt.json`, exit 1, 2,105.3 s. stderr SHA256 `3293CB534181E016811F23448FAA643E5B83B988DA98E82C4AE1C7351B1B41AC`.

## Result against the prediction registered before the run (`audit/runs/issue-100-fix-run/prediction-registered-before-run.txt`)

| | Before fix (run-029) | After fix (run-030) | Predicted |
|---|---|---|---|
| publish-step unbooked | -0.0671468785122 | **-1e-13** | ~0 |
| `exch_nh4_b_mol_per_mg` after publish | 0 | 4.6024195228413856 (= non-band) | layer mean |
| `exch_nh4_b_g` after publish | 0 | 0.067146878512191158 | +0.0671469 |
| hour-3,276 cell N residual | -0.0676655385994 | **-5.186600871420755e-4** | ~ -5.19e-4 |
| frontier | 3,275 accepted, fail 3,276 | **unchanged: 3,275 accepted, fail 3,276** | still fails |

The residual falls by 99.23%. The remainder is the unexplained publish->`prepareHour` step (-5.171096914e-4, mostly `aq_nh4_nb_g` -4.986e-4) plus the chemistry step (-1.55e-6). The second producer's booked input moved by 7.6e-9 (`external_inputs` 1.6566363623897373) because the state now differs. Everything else in the census is unchanged.

## Not claimed

The frontier does not move. The residual is 3.1e5 times the tolerance (`physical_limit` ~1.66e-9). No gate changes.
