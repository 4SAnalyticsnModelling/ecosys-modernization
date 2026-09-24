# run-032 -- issue-103: the hour-3,277 nitrate loss is a re-base caused by a SECOND, out-of-coordinator NO3 band growth in the chemistry stage (2026-09-24)

Task `20260924-055505-f4a901f5`.

## Run identity

- Source: HEAD `d25b327`, plus TEMP_DIAGNOSTIC edits: `diagnostic_nitrogen_trace_target_hour` re-gated to 3,277, and a new `diagnostics.traceIssue103LayerNitrate` (layers 1-2). The new probe is placed beside every issue-100 probe site and at the five chemistry brackets in `soil_chemistry_convergence.zig` (`before/after_validate_carrier_volumes`, `after_refresh_matrix_from_reaction_state`, `after_export_chemistry`, `after_consume_undissolved`). Logging only.
- Build `audit/runs/issue-103-probe-build/receipt.json`: exit 0, 947.7 s, exe prefix `94ED9E8E514E91A3`. Run on a fresh prod-deck copy: `audit/runs/issue-103-probe-run/receipt.json`, exit 1, 2,089.5 s. stderr SHA256 `ff525a29241608bcab2f78087037e220cfc5637dc5c6fe4e6f20fd9f1a436849`.
- The frontier and the failing row are identical to run-031 (`census_positive_control entries=3276`; cell-0 `residual=-1.0368401319391096e-6`).

## Prediction (registered before the run: `audit/runs/issue-103-probe-prediction/prediction-registered-before-run.txt`): CONFIRMED

The loss appears at `chem_after_refresh_matrix_from_reaction_state`, 99% in layer 1:

| Layer | Bracket | `mx_no3_nb_g` | `mx_no3_b_g` | Net |
|---|---|---|---|---|
| 1 | validate -> **refresh** | -1.0266e-6 | 0 (band conc 0) | **-1.0266e-6** (= layer-1 residual) |
| 2 | validate -> **refresh** | -1.6964e-6 | +1.6861e-6 | **-1.03e-8** (= layer-2 residual) |

The cell census step at this bracket is -1.0368e-6, which equals the reported residual. No other bracket moves census nitrate unbooked.

## Mechanism (measured)

1. Between `trace2_after_uptake` and `chem_before_validate_carrier_volumes`, the science NO3 fractions change with no concentration change. Layer 1 `frac_no3_b` goes 0 -> 0.0026083, and layer 2 moves by 1.4906e-3. The concentration view `C*W*f` drops accordingly in layer 1 (-1.0266e-6), because the layer-1 band concentration is 0.
2. `refreshMatrixFromReactionState` then rebuilds matrix amounts from that view, which turns the fraction change into a census loss.
3. `consumeUndissolved` afterwards applies the coordinator's persisted relative changes. For layer 2 that is a DIFFERENT fraction change (1.4343e-3), conserved (nb -1.6323e-6 / b +1.6323e-6). For layer 1 it does nothing (-4.4e-17).

The only geometry mutator in that interval is `soil_chemistry_convergence.updateFertilizerBandGeometry` (called at `soil_chemistry_convergence.zig:211`, after `solveHourlyReactionCells`). It passes `fertilizer_band.geometry(cell, .nitrate|.phosphate)` slices, which alias the band state, into `fertilizer_band_nitrate_phosphate.updateLayer`. That grows the band in place. The NO3/PO4 pool arrays it repartitions are scratch allocations that are never written back, and it records no coordinator relative change.

## Legacy check

- `fertilizer_band_nitrate_phosphate.updateLayer` documents itself as "Translates `hour1.f` lines 4992--5200". `hourly_fertilizer_band_geometry` (driven by `fertilizer_band_production.prepareHour` for all three families) documents "HOUR1 (`hour1.f`) lines 4888-5151 ... invokes this independently for each nutrient family".
- `f77query grep` finds exactly ONE NO3 band-growth site in the legacy code, the `hour1.f` `DO 9986` loop (`WDNOB`/`DPNOB`/`VLNOB` at `:5005-5064`). The only other assignments are activation (`:362-372`), reset (`redist.f:11322-11324`) and initialization (`starts.f:1600-1601`).
- **So ecosys-ng grows the NO3 (and PO4) band twice per hour where legacy grows it once.** The two Zig passes also disagree in layer 1: only the chemistry-stage pass extends the NO3 band there.

## Not established / next

- Which of the two Zig growth passes is the faithful `hour1.f:4992-5151` translation (including the layer-1 extension), and whether the duplicate should be removed or merged into the coordinator path. That is a translation-fidelity adjudication against legacy, not a policy decision, and it is the next task. It must include a PO4 check: issue-099's open phosphate activation, and issue-065's "ruled out updateFertilizerBandGeometry for phosphorus", which was measured in a different hour.
- No source change here beyond TEMP_DIAGNOSTIC probes. No gate changes.
