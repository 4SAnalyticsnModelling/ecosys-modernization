# Issue 094 -- ecosys-ng's subsurface water export is near zero, so the profile never drains: artificial (tile) drainage is 3.9 mm against the oracle's 213.5 mm

Status: **OPEN, CONFIRMED FROM OUTPUTS ON DISK, ROOT-CAUSE CANDIDATE FOR THE ENTIRE SURFACE/LITTER DIVERGENCE CLUSTER (filed 2026-09-22, adversarial Claude/Pi session).** Found run-free while `issue-091` blocks all runs. This supersedes the framing of the cluster as five independent readouts: they are consequences of one missing water loss pathway.

Severity is high and it is not an output-layer defect. A profile that cannot drain is wrong in the state, not in the reporting.

## The measurement

Daily water stream, cumulative over the 136 matched days both runs share (`run019` candidate against the preserved oracle), comparing the oracle's annual running totals against the candidate's per-day values running-summed over the same window:

| quantity | oracle (mm) | ecosys-ng (mm) | ratio |
|---|---|---|---|
| `TILE_DRG` artificial drainage (`UVOLY`) | **213.51** | **3.91** | **55x** |
| `DISCHG` net lateral+lower transfer (`UVOLO`) | -95.26 | +7.30 | -- |
| `RUNOFF` surface | 118.52 | 211.43 | 0.56x |
| `ET` | 45.58 | 66.54 | 0.69x |
| `PRECN` rainfall | 351.60 | 411.07 | 0.86x |
| `WATER` storage, day 1 -> day 136 | 805.78 -> 1031.14 (**+225.37**) | 801.72 -> 1213.31 (**+411.58**) | -- |

Two readings need no sign convention and no balance argument:

1. **ecosys-ng exports 3.91 mm through artificial drainage where the oracle exports 213.51 mm.**
2. **ecosys-ng's profile storage gains 411.58 mm over the window where the oracle's gains 225.37 mm** -- 186 mm more water retained -- starting from storage values that agree to 0.5% on day 1 (805.78 against 801.72).

The compensating signal is also visible: ecosys-ng sheds **93 mm more surface runoff**. Water it cannot pass downward leaves overland instead, which is what a model does when its subsurface outlet is shut.

## The sign conventions, settled from the source rather than assumed

`redist.f:1138-1160` defines all of it, and the distinction matters because `DISCHG` is negative for the oracle:

```
FLW,FLWH    = micropore,macropore water flux through lateral and lower boundaries   (:1139-1140)
FLWY,FLWHY  = micropore,macropore discharge through lateral and lower boundaries
              FROM ARTIFICIAL DRAINAGE                                              (:1141-1143)
UVOLO       = net water transfer through lateral and lower boundaries               (:1146-1147)
UVOLY       = water loss through lateral and lower boundaries from artificial drainage (:1148-1149)
XN          = flux direction: +1=gain, -1=loss                                      (:1150)

WO = XN*(FLW+FLWH) ;  UVOLO = UVOLO - WO                                            (:1154,:1158)
WY = XN*(FLWY+FLWHY);  UVOLY = UVOLY - WY                                            (:1159-:1160)
```

Because the accumulators subtract a gain-positive quantity, **negative `UVOLO` is a net gain** and **positive `UVOLY` is a loss**. So the oracle's picture is a coherent tile-drained field: roughly 309 mm enters through the lateral/lower boundary, 213.51 mm is removed by artificial drainage, netting the +95.26 mm gain that `DISCHG = -95.26` reports. ecosys-ng has neither side of that exchange -- about zero in and 3.91 mm out.

`outsd.f:118` and `:158` write the two columns as `1000*UVOLO/TAREA` and `1000*UVOLY/TAREA`, i.e. mm over the landscape area; the candidate declares `water_outflow[mm]` and `lateral_water_outflow[mm]`. Both divide by `TAREA` rather than the cell area, which coincides here only because this deck has a single cell.

## Configuration and wiring are both FAITHFUL -- the defect is in the realized flux

This was checked before blaming the configuration, because a deck-reading defect would be the cheaper explanation:

- **The deck switches artificial drainage ON.** `f25si98` line 1 is `45.3 92 5.4 3`, and `readi.f:152` reads that as `ALATG, ALTIG, ATCAG, IDTBLG` -- so `IDTBLG = 3`. `readi.f:157` gates the artificial water table on `IF(IDTBLG.GE.3)`, and `readi.f:134-137` documents the following records as `DTBLDIG` (depth of the artificial external water table) and `DTBLDGG` (its slope). The deck supplies `1.5 1.0` and then boundary distances/fractions `0.0 10.0 0.0 10.0 0.0 1.0 0.0 1.0`. Line 3's `NCNG = 1` selects the laterally **connected** mode, which is what lets `redist.f:1152`'s `IF(NCN.NE.3.OR.N.EQ.3)` accumulate boundary flux in every direction rather than only the vertical one.
- **ecosys-ng parses exactly that, with the same gate.** `state/site.zig:109` is `if (result.water_table_mode >= 3)`, matching `readi.f:157`, and `:111-116` read the depth, slope, per-boundary distances and exchange fractions. `site.zig:95-97` maps the connection mode `1 => .connected`, `3 => .disconnected`. An existing test at `site.zig:234` already pins `artificial_water_table_distance_m == {0, 10, 0, 10}`, which is this deck's line 6.
- **The solver consumes it.** `soil/water/solver_residual.zig:488-493` selects `artificial_water_table_depth_m`, its slope and the artificial boundary distance when the face is artificial, against the natural values otherwise.
- **The process is implemented and published.** `soil/water/solver_solve.zig:840-842`, `:1009-1010`, `:1587-1588` allocate and publish `artificial_drainage_outflow_m3_per_step`; `ecosys_ng.zig:3666` routes it into the daily ledger's `lateral_water_outflow_m3`; `soil/diagnostics/daily_water_budget.zig:13-19` documents that slot as the artificial-drainage subset.

So this is **not** unimplemented, not unparsed, and not unwired. The configuration reaches a solver that computes a boundary flux, and the flux it computes is about 55 times too small. That is a magnitude defect inside the realized boundary exchange.

Note also that ecosys-ng's profile is not short of water to drain -- the opposite. `WTR_1` reaches **0.717** while the oracle's is 0.098, so the surface is at or near saturation while the tile removes 3.91 mm. A saturated profile above a 1.5 m artificial water table should be draining hard.

## Why this reorganizes the whole cluster

`run-014` recorded five surface readouts and commit `933c2ac` narrowed them to "litter carbon and litter water". The per-key trajectories now show all of them are downstream of this one defect. Using the new `outcompare.py --trace`:

- **`WTR_1` rises monotonically and never dries**: 0.461 (day 60) -> 0.606 (day 68) -> 0.632 (day 90) -> 0.697 (day 120) -> 0.717 (day 136), while the oracle's cycles with weather and falls to 0.098. A one-way climb in a surface water content is the signature of an absent loss pathway, not of a mis-tuned retention parameter.
- **The bias attenuates with depth and vanishes below the drain**: `WTR_1` bias +0.262, `WTR_2`..`WTR_6` about +0.10, `WTR_7`..`WTR_9` +0.054..+0.062, `WTR_10` +0.016, **`WTR_11` -0.0003**. Water backs up above the artificial water table depth and the deep layers are unaffected -- exactly the vertical structure a failed drain produces, and not what a uniform retention or freezing error would produce.
- **Snow persists because the surface is waterlogged**: the oracle's `SNOWPACK` reaches 0 by day 90; ecosys-ng still has 354 mm then and does not clear until about day 120 (`issue-087`).
- **Litter thickness diverges in step jumps at the melt, not smoothly**: the `SURF_ELEV` signed error is ~1e-3 or less through day 12 (day 12: -2.9e-6), drifts to 5e-4 by day 40, then **jumps at day 68 and day 90** to 1.3e-2 and 5.4e-2, ending at 8.2e-2. Those jump days coincide with the melt window above. Litter thickness is `dry_volume + max(0, water + ice - retention)`, so a saturated litter drives it through the excess-water term.
- **`PSI_SURF` is extreme** because it is exponential in log water at saturation (already resolved as a symptom in `run-014`).

## Consequence for issue-093, whose prediction this REFUTES

`issue-093` established from the source that the litter-geometry carbon input uses the wrong per-pool composition (pool 4 over-included). That finding stands -- it is a source-verified composition mismatch. But `issue-093` also made a quantitative prediction: that about 670 g C m-2 of spurious pool-4 carbon would account for the whole 0.0268 m mean litter-thickness difference.

**That prediction is refuted.** The thickness error is ~1e-3 m or less for the first 12 days and only ~5e-4 m by day 40, then jumps by more than an order of magnitude at the melt. A composition defect in the dry-volume term would produce a smooth offset growing with humus accumulation, not step changes locked to snowmelt. The carbon composition defect therefore accounts for at most the small early-season component -- roughly 2% of the reported mean -- and the bulk of the 0.0268 m is the excess-water term driven by this issue.

`issue-093` is being annotated accordingly rather than withdrawn: the composition mismatch is real and still needs fixing, but it is not the cause of the cluster and must not be prioritised as though it were.

## Water balance: neither side closes on the reported columns, and the candidate's gap is 5x larger

Stated with the caveat that these six columns are **not** a complete budget -- snow water equivalent (the daily `SNOWPACK` is `1000*DPTHS`, snow **depth**, not water equivalent), canopy interception, litter water and any transpiration not inside `UEVAP` are all missing, and the cumulative fluxes cover days 1-136 while the storage delta covers days 2-136:

- Oracle: `351.60 - 45.58 - 118.52 + 95.26 = 282.76` against an actual `+225.37`, a **-57.4 mm** residual (about 16% of input).
- ecosys-ng: `411.07 - 66.54 - 211.43 - 7.30 = 125.80` against an actual `+411.58`, a **+285.8 mm** residual.

The candidate's residual is five times larger and of the opposite sign -- storage appearing that its own reported fluxes do not supply. This is **indicative, not a conservation proof**, because of the missing terms above; it should not be quoted as a mass-balance violation without closing those terms first. It is recorded because it points the same way as everything else.

## Secondary observation, needs its own check: cumulative rainfall differs by 59 mm

`PRECN` cumulative reaches 351.60 mm in the oracle and 411.07 mm in the candidate -- **17% more precipitation reaching ecosys-ng**, diverging mostly after day 100 (day 100: +2.9 mm; day 120: +13.8 mm; day 136: +59.5 mm). Earlier input-equivalence work in this session proved `WIND` bit-identical and `AIR_TEMP` equal to 2.3e-14, but the **precipitation** input was not verified to the same standard. `URAIN` is accumulated at `redist.f:4407` as `URAIN=URAIN+WI`, so `PRECN` is rain reaching the surface rather than the raw forcing, and the difference could be a partition (rain against snow), an irrigation inclusion, or a genuine forcing mismatch. **Do not assume it is forcing and do not assume it is benign**: 59 mm is a quarter of the storage discrepancy. This needs its own comparison against the hourly `PREC` column and the weather file.

## Bounded next action

The diagnosis is now specific enough to target one computation. In order:

1. Compare the realized artificial-drainage boundary flux term by term: `soil/water/solver_residual.zig:488-493` against `watsub.f`'s `FLWY`/`FLWHY` producer, checking the head difference, the conductance, the distance and the exchange fraction. The configuration is proven identical, so the discrepancy is in one of those four factors.
2. Check the sign/direction handling of the natural boundary too. The oracle gains ~309 mm through it; ecosys-ng gains ~0. A drain with no recharge and a recharge with no drain are different defects and the outputs cannot separate them -- but both are near zero here, which hints at one shared gate rather than two coincidences.
3. Verify precipitation input equivalence to the standard already applied to wind and air temperature.

This does **not** need a production run: the oracle is on disk, `run019`'s candidate output is on disk, and step 1 is source comparison. That matters because `issue-091` still blocks every run.

## Addendum, same day: step 1 done -- the closed-form flux does NOT explain the 55x, and two of four candidates are eliminated

The artificial-drainage flux was compared term by term. Legacy producer is `watsub.f:5934-5954`; ecosys-ng's is `soil/water/boundary.zig:69-83` (`matrixDischarge`), called from `solver_residual.zig:522`.

```fortran
! watsub.f:5935-5952
PSISWD = XN*0.0049*SLOPE(N)*DLYR(N)*(1.0-DTBLDG)
PSISWT = AMIN1(0.0, -PSISA1 + 0.0098*(DPTH-DTBLY) - 0.0098*AMAX1(0.0,DPTH-DPTHT))
IF(PSISWT.LT.0.0) PSISWT = PSISWT - PSISWD
FLWT   = PSISWT*HCND(N,KB,N3)*AREA(N,N3)*(1.0-AREAUD(N3))/(RCHGFA+1.0)*RCHGFB*XNPHX
```

| term | legacy | ecosys-ng | verdict |
|---|---|---|---|
| driving potential | `AMIN1(0, -PSISA1 + 0.0098*(DPTH-DTBLY) - 0.0098*AMAX1(0,DPTH-DPTHT))` | `@min(0, -matric + saturation_term + 0.0098*(mid-ext) - 0.0098*@max(0,mid-int))` (`:78`) | **faithful**; `saturation_term` is 0 exactly when `artificial_drain` (`:77`), matching the term's absence from the legacy artificial branch |
| separation distance | `/(RCHGFA+1.0)`, `RCHGFA` = distance to the external table (`readi.f:141`, `reads.f:872`) | `driving /= external_separation_distance_m` (`:79`) **and** `/(recharge_frequency_divisor+1.0)` with the divisor passed as `0` (`solver_residual.zig:522`) | **differs, but the WRONG WAY.** For this deck's 10 m faces legacy divides by 11 and ecosys-ng by 10, so ecosys-ng's closed form is ~10% **larger**. Cannot explain a 55x deficit. |
| slope term | `PSISWD = XN*0.0049*SLOPE*DLYR(N)*(1-DTBLDG)` | `slope_gradient = sign*0.0049*slope_sine*(1-water_table_slope)`, no `DLYR` (documented `GRID-INV-002`) | **moot for this deck**: `f25si98` line 5 gives the artificial table slope `DTBLDGG = 1.0`, so `(1 - slope) = 0` zeroes the term on both sides |
| conductivity | `HCND(N,KB,N3)`, `KB` a wetness class from `THETW1 = AMAX1(THETZ, AMIN1(POROS, VOLW1/VOLY))` (`:5947-5950`) | `conductivityAt(properties, layer, axis, matrix_fraction, ice)` with `matrix_fraction = matrix_water / matrix_bulk_volume_m3` (`:462`) | **NOT ELIMINATED.** Legacy's wetness ratio is `VOLW1/VOLY`; ecosys-ng's is over `matrix_bulk_volume_m3`. Different denominators select different classes. Needs runtime values. |
| area above table | `(1.0-AREAUD(N3))` | `(1.0-fraction_face_below_water_table)`, `fraction_below = clamp((bottom-external)/thickness, 0, 1)` (`:520`) | **NOT ELIMINATED**; the `AREAUD` producer was not compared |
| boundary fraction, time | `*RCHGFB`, `*XNPHX` | `*recharge_time_multiplier` (= `exchange_fraction` = 1.0 here), `*time_fraction` | faithful |

**Gate (`IFLGD`) is structurally faithful.** Legacy `watsub.f:5352-5378` enables discharge when `IDTBL>=3`, the midpoint is above the artificial table, `PSISA1(L) > PSISA(L)`, and no deeper layer above the table fails the same test or lies below the active layer. ecosys-ng reproduces all four (`solver_residual.zig:470`, `:521`, `:480`, `:506-519`). Two details checked rather than assumed:

- Legacy *skips* layers at or below the table and continues the scan; ecosys-ng `break`s at the first such layer (`:511`). **Equivalent**, because `DPTH` increases monotonically with the layer index.
- The inequality direction initially looked inverted. It is not: `grid.matric_potential_megapascal` is **not** the trial iterate -- `solver_residual.zig:477` recomputes the trial potential separately, which would be redundant otherwise -- so `base_matric > grid.matric_potential` maps onto `PSISA1 > PSISA` correctly.

But ecosys-ng deliberately **freezes the active set at the hour-start state** ("so the implicit residual remains smooth", `:504-505`) where legacy re-evaluates `PSISA1` every substep. That is a documented deviation and it can only ever *disable* drainage that legacy would allow. **It is the leading remaining candidate.**

### Narrowed candidate list

Static reading eliminates the closed-form scaling and the gate's structure. What remains, in order of suspicion:

1. **The frozen active set** (`solver_residual.zig:504-505`). If the hour-start state fails `PSISA1 > PSISA` on most hours, drainage is gated off almost always regardless of how correct the flux is. A binary gate is the only one of these candidates that can plausibly produce 55x.
2. **The conductivity wetness class** -- `VOLW1/VOLY` against `matrix_water/matrix_bulk_volume_m3`.
3. **`AREAUD` against `fraction_face_below_water_table`.**
4. The `/(d+1)` against `/d` distance difference -- real but ~10% and of the wrong sign.

Also flagged while here, not yet an issue: `boundary.zig:113` (`macroporeDischarge`) divides by `recharge_frequency_divisor` with **no `+1`**, where the sibling micropore path at `:81` uses `+1.0` and the legacy macropore line `watsub.f:6003` uses `AMAX1(RCHGFA,1.0)`. The legacy itself is inconsistent between the two paths (`/(RCHGFA+1.0)` micropore at `:5952`, `AMAX1(RCHGFA,1.0)` macropore at `:6003`), so whatever ecosys-ng passes there needs checking against `:6003` specifically, and a zero would divide by zero.

**Honest status**: candidate 1 needs runtime values and cannot be settled by reading. A Debug replay is possible (`issue-091` confirms Debug is readable) but the tile-drainage gap only reaches 14x by day 40 (oracle 14.36 mm against 0.99 mm), i.e. ~960 simulated hours, which at the measured Debug rate of ~87 s/hour is ~23 hours of wall clock. So instrumenting the gate's hit rate over a short window is the affordable experiment, not reproducing the divergence.

## Reproduction

```
uv run ecosys-audit/scripts/outcompare.py --stream water_daily \
  --oracle    <scratch>/oracle-ottawa/ottawa_run/01998f25wd1 \
  --candidate <scratch>/run019deck/runottawa_output_files/modelled_outputs/water/lat_45.30_lon_-75.70_soil_or_eco_1998_..._f25wd1.txt \
  --cumulate-candidate TILE_DRG --cumulate-candidate DISCHG \
  --cumulate-candidate PRECN --cumulate-candidate ET --cumulate-candidate RUNOFF \
  --trace TILE_DRG --trace WTR_1 --trace SURF_ELEV
uv run ecosys-audit/scripts/f77query.py show f77src/redist.f --lines 1138-1165   # sign conventions
uv run ecosys-audit/scripts/f77query.py show f77src/readi.f  --lines 130-160     # IDTBLG gate
```

**Tool limitations, quoted as required.** `outcompare.py` reports that it "does not prove either run reached its required end time; completion is a separate mandatory proof and neither side has it" -- and neither does here: the oracle has 286 rows, the candidate 136, so this covers only the 136 shared days and says nothing about the remaining record. It also "applies no unit conversion", so the mm mapping rests on the `outsd.f:114-118`/`:158` reading above. The `--cumulate-candidate` mode is only valid because the matched keys start at day 1, the oracle's own annual reset (`day.f:84`, `I.EQ.1`), with `candidate_only=0` and the calendar cross-check passing 136/136 -- the tool reports those but does **not** enforce them. `f77query.py` "does not compile the model, prove equivalence, or decide a gate". No number here comes from a model run performed in this session.
