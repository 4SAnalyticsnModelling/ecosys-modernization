# Issue 100 -- hour 3,275 nitrogen conservation residual: 0.0677 g N unaccounted, about 4% of the banded ammonium application

Status: **OPEN, MEASURED, NOT DIAGNOSED (filed 2026-09-22, adversarial Claude/Pi session; sharpened later the same day).** This is the frontier blocker exposed once `issue-099`'s fix restored phosphorus and calcium conservation (`run-023`). Filed with the measurement and two numeric leads, deliberately **without** a proposed mechanism -- `issue-099` cost eight wrong mechanisms proposed from source reading, and the discipline this round is to measure first.

**The filename's "about 4% of the banded ammonium input" framing is superseded and should not be read as the characterisation.** Hour 3,275 fails on **two** cells, 0 and 2, which lose the **same absolute mass** -- `0.0676655386` g N, agreeing to eleven significant figures -- despite differing 12.7x in storage and fourteen orders of magnitude in `external_outputs`. The defect is a **fixed quantity dropped once per affected cell**, not a percentage of anything. The "4%" is simply that mass divided by one of the two different inputs (4.084% for cell 0, 3.786% for cell 2). See "The decisive fact" below; both originally filed leads are now refuted or downgraded.

## The measurement

`run-023`, hour 3,275, the complete ledger row:

```
error: hourly cell conservation failure: cell=2 quantity=nitrogen
  before=5.04112824263519e1   after=5.1993688088010714e1
  external_inputs=1.7186002174175976e0
  external_outputs=6.85290171591924e-2
  internal_production=0e0     internal_consumption=0e0
  residual=-6.766553859959434e-2
  normalized_relative=3.7862700296332076e-2
  effective_limit=1.7872466678681151e-9
```

Arithmetic check, which confirms the ledger is self-consistent:

```
after - before            = 1.5824056616588
external_inputs - outputs = 1.6500712002584
residual                  = 1.5824056616588 - 1.6500712002584 = -0.0676655385996   (matches)
```

**So 0.0676655 g N did not arrive in storage.** The residual is 7 orders of magnitude outside the effective limit (1.787e-9), so it is not a tolerance question. `normalized_relative = 3.79e-2`.

## What the numbers identify

**The input is the banded ammonium application.** `external_inputs - external_outputs = 1.6500712002584`, and the deck's day-137 line (`f77example/Cool Temperate Maize-Soybean ON/f25fr98`) is

```
17051998  0  0  0  0  1.65  0 ... 0.05  0.76  1  0  0
                        ^^^^ field 5 = Z4B = banded NH4 (hour1.f:231)
```

`1.65` against `1.65007` -- five significant figures. The same line's `0.05`/`0.76` are the depth and row spacing whose band fraction `run-021` measured at 1.6447e-2 in **cell 2**, the cell that fails here. So the failing hour is the banded NH4 application hour, in the application layer.

**This is NOT the shape of `issue-099`'s defect.** That one lost **100%** of the banded input (`residual` equal to `-external_inputs` to fifteen digits). This loses **about 4%** of it. A partial discrepancy and a total annihilation should not be assumed to share a cause.

**And the nitrogen path already uses zone water**, so it is not the phosphate defect's analogue. `stages/soil_chemistry_convergence.zig:484-490` passes `prepared_zones.ammonium_non_band_water_m3` and `ammonium_band_water_m3` into `soil_fertilizer_dissolution.normalizationBasisPerWaterVolume` -- per-zone carriers by name, where `mineral_fertilizer_inventory.publishSoil` was using the full layer water before `issue-099` fixed it.

## The decisive fact: TWO cells lose the SAME absolute mass

The row quoted above is not the only one. Re-reading the run's own log rather than my notes, hour 3,275 emits **exactly two** cell conservation failures, both nitrogen, and **nothing else** -- no other cell, no other quantity, no `CONSERVATION_BREACH` summary line:

| | cell 0 | cell 2 |
|---|---|---|
| `before` | `6.418057163733818e2` | `5.04112824263519e1` |
| `after` | `6.433946871895852e2` | `5.1993688088010714e1` |
| storage delta | `1.5889708162034` | `1.582405661658814` |
| `external_inputs` | `1.6566363548027827` | `1.7186002174175976` |
| `external_outputs` | **`4.033074007076744e-16`** | `6.85290171591924e-2` |
| net booked | `1.6566363548027827` | `1.6500712002584052` |
| **`residual`** | **`-6.76655385993683e-2`** | **`-6.766553859959434e-2`** |
| `normalized_relative` | `4.084513683597367e-2` | `3.7862700296332076e-2` |

Both residuals recomputed from the row's own terms and both match. **The two residuals agree to eleven significant figures** -- `6.76655385993683e-2` against `6.766553859959434e-2`.

That agreement is the finding. The same `0.0676655386` g N goes missing in both cells although:

- their **storage differs by 12.7x** (641.81 against 50.41), so the loss is not a fraction of storage;
- their **`external_outputs` differ by fourteen orders of magnitude** (`4.03e-16` against `6.85e-2`), so the loss is not a function of the outputs;
- their **`external_inputs` differ** (`1.6566` against `1.7186`), so it is not a fraction of the input either -- 4.084% of one and 3.786% of the other.

A **fixed absolute quantity, lost once per affected cell**, is a different class of defect from anything proposed so far. It rules out the whole family of proportional errors -- wrong zone fraction, wrong divisor, double-counted fraction -- that `issue-098` and `issue-099` both turned out to be.

Cells 1 and 3 do not fail at all, so it is not every cell.

### This refutes lead 1 and downgrades lead 2 -- using data I already had

1. **"The residual is close to `external_outputs`" is dead.** It was based on cell 2's `0.0676655` against `0.0685290`. **Cell 0 has the same residual with `external_outputs = 4.03e-16`, effectively zero.** A quantity cannot be explained by an output term that is absent in a case showing the identical quantity. Withdrawn.
2. **"4.1% of 1.65" is downgraded to coincidence.** Cell 2's net booked input is `1.6500712`, which matched the deck's `FERT(5)=1.65` to five figures and drove the banded-ammonium identification. **Cell 0's net booked input is `1.6566364`** -- it does *not* match `1.65` to five figures, yet loses exactly the same mass. So the five-figure match was a property of one cell, not of the defect. The percentages differ between the two cells (4.084% and 3.786%) precisely because the absolute loss is what is conserved.

**Both leads were filed as explicitly unverified and both fell to one careful re-read of the log.** Neither cost a run. What they did cost is the earlier framing of this issue around cell 2 alone -- which also meant the first probe filtered to `cell == 2` and would have missed the cleaner of the two cases.

### Cell 0 is the better experiment

Cell 0's `external_outputs` is `4.03e-16`, i.e. zero to within roundoff. So for cell 0 the closure reduces to `after - before` against `external_inputs` alone, with no output term to confound it. Any future measurement should start there.

### `cells.len >= 3`, confirmed empirically

The log contains rows for cell 0 and cell 2, and `evaluate` indexes `cell` over `0..boundary.len` (`:2356-2358`). So the ledger really does have at least three cells. This stands **against** the deck derivation: `runottawa:3` is `1,1,5` (a 1x1 domain), `runottawa:4`'s `geospatial_grid,45.25,45.35,-75.75,-75.65,0.10,0.10` is a 0.10-degree span at 0.10-degree resolution, and `spatial_grid.RegularGrid` documents its bounds as **cell edges** (`:40-41`) with counts from `intervalCount(span, interval)` -- which is 1 row by 1 column, one cell. `runscript.zig:1815-1819` confirms the geospatial record *overrides* the `1,1,5` header, so the geospatial path is the live one. The unexplained factor is most likely `tile_layout,1,1,2`'s `lateral_flow_halo_cell_count = 2` (`runscript.zig:1811`), since `spatial_grid` carries a `neighbor_halo_cell_count` concept (`:282`, `:297`, `:354`) -- **but that is a hypothesis, not a trace.** The probe reports `cells.len` from `init` so the number comes from the run.

If the ledger extent does include halo cells, then "cells 0 and 2 fail, 1 and 3 do not" may be a statement about interior versus halo cells rather than about geography, and that would matter for interpreting the residual. Not established.

## First measurement: cell 2's nitrogen does NOT arrive through `BoundaryLedger.accumulate`

A probe was placed in `BoundaryLedger.accumulate` (`hourly_cell_conservation.zig:845`) logging every contribution with nonzero `nitrogen_input_g` or `nitrogen_output_g` for `cell == 2`, and run to the frontier. The run reproduced `run-023` exactly -- same nitrogen row, `census_positive_control entries=3275` -- and the probe fired **zero times**.

So cell 2 accumulates `external_inputs=1.7186002174175976` of nitrogen **without any of it passing through `accumulate`**. That is the one solid result of the measurement, and it is a negative one.

### Who writes `cells[2]`: twelve call sites, all inside the file itself

`accumulateCells` (`:898`) and `accumulateIntercell` (`:917`) are called **only from within `hourly_cell_conservation.zig`**, which is why they look unused from outside it:

| caller | path |
|---|---|
| `:1139`, `:1177`, `:1217`, `:1244` | `accumulateCells` |
| `:1560`, `:1612`, `:1655`, `:1771` | `accumulateCells` |
| `:2084`, `:2141`, `:2178`, `:2187` | `accumulateIntercell` |

These are the transport booking helpers -- `accumulateDissolvedGasTransport` (`:1505`) and its siblings. Each allocates a local `activities` slice sized `ledger.cells.len`, folds the producer's signed extensive fluxes into it, and commits the whole candidate through `accumulateCells`. **The cell index is computed as `layer / soil_layer_capacity`** (`:1534-1537`) for boundary fluxes and from `face.first_cell / soil_layer_capacity` (`:1544-1545`) for horizontal faces. Nitrogen specifically is folded at `:1536`, `:1554`, `:1591`, `:1606` and `:1652` via `addSignedBoundary`/`addSignedFace` with the field names `"nitrogen_input_g"`/`"nitrogen_output_g"`.

So cell 2's nitrogen almost certainly arrives from one of these, for the layer range `[2*soil_layer_capacity, 3*soil_layer_capacity)`. **That is now a site list to measure, not a mechanism** -- which of the twelve, and with what magnitude, is exactly what the extended probe reports.

### Two of my own claims in this section were wrong first; both cost a grep, not a run

1. I wrote that the booking "must" arrive via the two uninstrumented paths. That was an inference from reading the struct rather than from checking callers -- correct as it turns out, but not established at the time.
2. I then "refuted" it with a grep that **excluded `hourly_cell_conservation.zig`** -- the very file under study, and the only file containing the call sites. The exclusion was there to suppress the definitions and it suppressed the evidence with them. **Never exclude the file under study from the search that is supposed to explain it.**

The corrected position is the original one: the two bulk paths are live in production and were the uninstrumented ones.

### The probe field name is the right one -- checked, not assumed

`transaction` maps the nitrogen quantity at `:2453` as `.external_inputs = activity.nitrogen_input_g` -- a single field, not a sum over several nitrogen-bearing fields. So the probe's `activity.nitrogen_input_g != 0` filter is testing exactly the quantity the failing row reports, and "the filter watched the wrong field" is excluded.

### Making the next measurement self-verifying

Two failure modes of the last measurement are cheap to kill outright, so the probe was extended rather than removed:

1. **"Fired zero times" and "was not in the binary" produce identical logs.** A presence marker in `init` now logs unconditionally. This session has already lost three runs to launch-method flakiness, so this is not a paranoid control.
2. **The `cell=2` coordinate was never verified.** Covered above -- the `init` marker reports `cells.len` so the extent comes from the run, not from my reading of the deck.
3. **The probe filtered to `cell == 2` and so excluded the cleaner case.** Now removed; the trace covers every cell and prints the index. The hour gate keeps the volume trivial.

A fourth control matters because of how the last two probes were wasted: the trace is gated on `diagnostic_nitrogen_trace_hour == 3275`, published from the driver beside the per-hour `reset()` (`ecosys_ng.zig:6853-6859`). Without a gate this fires from twelve booking sites every hour for 3,275 hours, and `run_support.zig:448` flushes every line -- an ungated census diagnostic earlier in this session cost roughly **140x throughput** (hour 48 in 596 s).

The nitrogen trace was also factored into a single `traceNitrogen` helper called from all three mutation sites, so an incomplete-by-construction measurement cannot recur the same way.

## Next bounded action -- measure, do not read

Instrument every nitrogen booking for **all** cells at hour 3,275, attributed by call site, and compare the sum against each cell's `before`/`after` storage delta. **Start from cell 0**, whose `external_outputs` is `4.03e-16`, so its closure has no output term to confound. One `ReleaseSafe` build plus one ~10-minute run; staged and building as of this update.

The question the run answers is narrow: does the sum of traced bookings equal the row's `external_inputs`? If yes, the **ledger is right and the storage census is short** by a fixed `0.0676655386` g N per affected cell -- a state-update problem. If no, the ledger's own total is wrong and the discrepancy is in the booking path. Everything else follows from which.

`issue-099`'s record is the argument for this ordering: seven static mechanisms were refuted there before the eighth was measured, every component was individually correct, and two of my ordering conclusions came from reading source line numbers in different functions. On this issue **both** filed leads have now been refuted or downgraded, and three of my own intermediate claims corrected -- all from re-reading the log and checking call sites, none from a run. That is the intended ratio.

## Limitations

Single run, no repeat. The per-row numbers are quoted verbatim from the run's own log; the residuals and net booked inputs in the two-cell table were recomputed from the row's own terms and agree, but the storage census itself was not independently recomputed. **The `Z4B`/banded-ammonium identification no longer carries weight**: it rested on cell 2's five-figure match to the deck's `1.65`, and cell 0 loses the identical mass without that match, so the input identification is not evidence about the mechanism. The claim that the nitrogen dissolution uses zone water still rests on **field names** at `soil_chemistry_convergence.zig:484-490`; the arithmetic inside `normalizationBasisPerWaterVolume` was not verified. The halo explanation for `cells.len >= 3` is an unverified hypothesis. `check_gate.py` owns gate status; the run still stops at 1.25% of the horizon, so criterion 1 remains unverifiable and criterion 3 is untouched.
