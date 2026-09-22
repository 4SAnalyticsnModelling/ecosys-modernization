# Issue 100 -- hour 3,275 nitrogen conservation residual: 0.0677 g N unaccounted, about 4% of the banded ammonium application

Status: **OPEN, MEASURED, NOT DIAGNOSED (filed 2026-09-22, adversarial Claude/Pi session).** This is the frontier blocker exposed once `issue-099`'s fix restored phosphorus and calcium conservation (`run-023`). Filed with the measurement and two numeric leads, deliberately **without** a proposed mechanism -- `issue-099` cost eight wrong mechanisms proposed from source reading, and the discipline this round is to measure first.

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

## Two leads, both unverified

1. **The residual is close to `external_outputs`.** `0.0676655` against `0.0685290` -- within 1.3%. If a booked output were applied twice, or an unbooked output of that size occurred, storage would fall short by about that amount. **This is a numeric near-coincidence, not evidence**; 1.3% is a large gap at this precision and the two quantities may be unrelated.
2. **4.1% of 1.65** is `0.0677`. Whether any zone fraction, dissolution fraction or partition constant in the nitrogen application path equals ~0.041 has **not** been checked.

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
2. **The `cell=2` coordinate was never verified.** `evaluate` takes `cell` as a loop index over `0..storage_before.len` and requires `boundary.len` to equal it (`:2356-2358`), so `cell=2` **requires `ledger.cells.len >= 3`**. Against that, the deck's own `runottawa:5` is `1,1,1,1` -- `NHW,NHE,NVN,NVS`, a 1x1 grid, one landscape cell. Those two cannot both be true of the same index space, so either `state.cell_count` is not the Fortran grid cell count or my reading of one of them is wrong. The `init` marker reports `cells.len` directly and settles it from the run.

The nitrogen trace was also factored into a single `traceNitrogen` helper called from all three mutation sites, so an incomplete-by-construction measurement cannot recur the same way.

## Next bounded action -- measure, do not read

The measurement that would settle it: instrument the nitrogen external-input and external-output producers for cell 2 at hour 3,275, logging each contribution with its source, and compare the sum against the `before`/`after` storage delta. One `ReleaseSafe` build plus one ~10-minute run.

`issue-099`'s record is the argument for this ordering: seven static mechanisms were refuted there before the eighth was measured, every component was individually correct, and two of my ordering conclusions came from reading source line numbers in different functions. On this issue the two leads above are explicitly labelled unverified for that reason.

## Limitations

Single run, no repeat. Every number is quoted verbatim from the run's own ledger and was not independently recomputed. The `Z4B` identification is a field-position match against `hour1.f:231` plus the deck line -- the ecosys-ng nitrogen application path has **not** been read, so it identifies the input, not the mechanism. The claim that the nitrogen dissolution uses zone water rests on **field names** at `soil_chemistry_convergence.zig:484-490`; the arithmetic inside `normalizationBasisPerWaterVolume` was not verified. `check_gate.py` owns gate status; the run still stops at 1.25% of the horizon.
