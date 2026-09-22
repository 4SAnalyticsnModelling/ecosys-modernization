# Issue 093 -- the litter-geometry carbon input uses one all-inclusive total for every pool, where legacy `RC0` uses a DIFFERENT composition per pool

Status: **OPEN, CONFIRMED BY SOURCE ON BOTH SIDES, but MUCH SMALLER THAN FIRST CLAIMED -- see the correction immediately below. Behavioural fix deliberately NOT applied while `issue-091` blocks production validation (filed 2026-09-22, adversarial Claude/Pi session).** Found run-free, as the terminal step of the `run-014` litter-thickness trace.

> ### CORRECTION, same day: the quantitative prediction in this issue is REFUTED
>
> This issue was filed claiming to be "the first identified cause in the surface/litter
> divergence cluster", and predicted that about **670 g C m-2** of spurious pool-4 carbon
> would account for the whole 0.0268 m mean litter-thickness difference. **That prediction
> is wrong.** A per-key trajectory of the `SURF_ELEV` signed error (obtained afterwards with
> the new `outcompare.py --trace`) shows the error is **~1e-3 m or less through day 12**
> (day 12: `-2.9e-6`), only ~5e-4 m by day 40, and then **jumps by more than an order of
> magnitude at day 68 and day 90** to 1.3e-2 and 5.4e-2, ending at 8.2e-2. Those jump days
> coincide with the snowmelt window.
>
> A dry-volume composition defect accumulates smoothly with humus; it cannot produce step
> changes locked to snowmelt. So the composition mismatch documented below accounts for at
> most the small early-season component -- roughly **2%** of the reported mean -- and the
> bulk of the difference is the litter geometry's **excess-water** term, driven by
> **`issue-094`** (ecosys-ng's subsurface water export is near zero, so the profile never
> drains and the litter sits saturated).
>
> **What survives:** the per-pool composition mismatch is real, source-verified on both
> sides, and still needs fixing. **What does not:** the claim that it is the cluster's cause,
> and the 670 g C m-2 figure. Do not prioritise this issue as a root cause; `issue-094` is
> the root cause. See `issue-094` for the trajectory evidence.

The five readouts recorded in `run-014` (`ICE_1`-`ICE_5` gradient, `WTR_1` bias, `SNOWPACK` persistence, litter thickness, `PSI_SURF`) all measure litter state, and `issue-094` now explains all five. This issue is a genuine but minor defect in how litter carbon is *assembled*.

## What is already proven faithful

The preceding trace (commit `933c2ac`) established that the litter-geometry **formula** is an exact term-for-term port, and that the **parameters** match the legacy `DATA` statements exactly:

| parameter | legacy | ecosys-ng |
|---|---|---|
| retention capacity | `DATA THETRX/2.0E-06,5.0E-06,5.0E-06,5.0E-06,5.0E-06/` (`hour1.f:128`) | `water_retention_m3_per_g_c = {2e-6,5e-6,5e-6,5e-6,5e-6}` (`gas_parameters.zig:339`) |
| dry bulk density | `DATA BKRS/0.100,0.0125,0.025,0.025,0.025/` (`starts.f:76`) | `dry_bulk_density_megagrams_per_m3 = {0.1,0.0125,0.025,0.025,0.025}` (`gas_parameters.zig:340`) |

Formula and parameters being identical, the ~0.0268 m thickness difference must live in the **carbon input**, which is what this issue is about.

## The legacy composition rule, which is per-pool and not uniform

The substrate index is `K=0` woody litter, `K=1` non-woody litter, `K=2` manure, `K=3` POC, `K=4` humus (`erosion.f:649-650`, `redist.f:3010`, `nitro.f:2716`). `RC0(K)` is rebuilt every hour at `redist.f:5528-5599`, and **each inventory carries a different `K` bound**:

| inventory | loop | `K` range actually accumulated into `RC0` |
|---|---|---|
| `OMC` microbial biomass | `DO 6970 K=0,5` with **`IF(K.NE.4)`** (`:5533-5534`, add at `:5547`) | 0,1,2,3,5 -- **humus excluded** |
| `ORC` microbial residue | inside `DO 6900 K=0,2` (`:5561`, add at `:5566`) | 0,1,2 |
| `OQC+OQCH+OHC+OQA+OQAH+OHA` DOC/acetate | inside `DO 6900 K=0,2` (add at `:5579-5580`) | 0,1,2 |
| `OSC` structural | `DO 6930 K=0,4` (`:5587`, add at `:5598`) | 0,1,2,3,4 |

The geometry then reads pools **0,1,2,4** (`hour1.f:4354-4355`), so the composition that actually reaches the thickness calculation is:

```
RC0(0), RC0(1), RC0(2) = OMC + ORC + (OQC+OQCH+OHC+OQA+OQAH+OHA) + OSC
RC0(4)                 = OSC ONLY
```

**`RC0(4)` receives the structural term and nothing else** -- microbial is removed by `IF(K.NE.4)` and residue/DOC never reach `K=4` because their loop stops at 2.

### These exclusions are deliberate, not incidental

Two independent confirmations:

1. **The arrays are dimensioned to hold the excluded slots.** `redist.f:159-161` declares `TORC(2,0:4)`, `TOQC(0:4)`, `TOHC(0:4)`, `TOQA(0:4)`, `TOHA(0:4)`, `TOMC(3,7,0:5)`. Slots `K=3,4` exist and are carried; `RC0` simply does not count them. They are **not** structurally zero, so this cannot be dismissed as a no-op difference.
2. **`starts.f` uses deliberately DIFFERENT bounds for the same quantity.** At initialization (`starts.f:1492-1570`) `RC0` is built with `DO 6990 K=0,5` and **no** `K.NE.4` guard on the microbial add (`:1522`), and with `DO 6995 K=0,4` for residue/DOC/structural (`:1524`, adds at `:1535`, `:1550-1551`, `:1569`). Two different routines choosing two different bound sets for the same array is the signature of intent, not of a uniform rule sloppily transcribed.

`starts.f` also carries its own quirk worth recording separately: the microbial add at `:1522` is **not** wrapped in the `IF(L.EQ.0)` guard that protects the residue, DOC and structural adds (`:1534`, `:1549`, `:1568`), so during initialization `RC0` accumulates `OMC` across **every** soil layer while taking the other three inventories from `L=0` only. `redist.f` overwrites `RC0` completely on its first call, so this affects only the initialization-phase geometry at `hour1.f:1927-1931`. Not the subject of this issue, but it must not be "tidied" into consistency without a decision, because it changes hour-0 geometry.

## What ecosys-ng does instead

`litter_geometry_step.zig:121` gathers all five pools through a single general-purpose total:

```zig
for (&carbon, 0..) |*value, pool| value.* = try context.surface_organic.substrateCarbon_g_c(cell, pool);
```

and `substrateCarbon_g_c` (`soil/organic/initialization.zig:487-499`) sums **every** category for **whatever** substrate it is handed, with no per-pool exclusion:

```zig
for (0..microbial_population_count * kinetic_fraction_count) |index| total += self.microbial[...].carbon_g_c;   // :490
for (0..residue_fraction_count) |fraction| total += self.residue[...].carbon_g_c;                                // :491
total += self.dissolved[...].carbon_g_c;                                                                         // :492
total += self.adsorbed[...].carbon_g_c;                                                                          // :493
total += self.dissolved_acetate_carbon_g_c[...];                                                                 // :494
total += self.adsorbed_acetate_carbon_g_c[...];                                                                  // :495
for (0..structural_fraction_count) |fraction| total += self.structural[...].carbon_g_c;                           // :496
```

**The function itself is correct** and should not be changed: it is the faithful analogue of legacy's all-inclusive `DC`/`OC` accumulators (`redist.f:5575-5576`, `starts.f:1538-1539`), and it has eight call sites of which seven want exactly this total. The defect is at the **call site** -- using the all-inclusive total where the legacy source uses a restricted, pool-dependent one.

### Consequence 1: pool 4 is over-included (makes ecosys-ng's litter THICKER)

For `pool = 4`, ecosys-ng adds microbial, residue, dissolved, adsorbed and both acetate categories that `RC0(4)` excludes. Every one of those is a positive quantity, so:

> ecosys-ng's pool-4 carbon is **greater than or equal to** the legacy value, with equality only if all six excluded categories are exactly zero at substrate 4 in the surface layer.

`BKRS(4) = 0.025 Mg m-3` is among the lowest densities in the vector, so pool-4 carbon is the **second most volume-efficient** term in the sum: each excess gram contributes `1e-6/0.025 = 4.0e-5 m3` of dry volume.

**The sign matches the measurement.** `run-014` reports `SURF_ELEV` bias `+2.68165e-2`, and `outcompare.py` defines `err = b - a` with `a` the oracle and `b` the candidate (`outcompare.py:391-395`), so the candidate's `SURF_ELEV` is the larger. Since `surface_litter_thickness_m` enters `SURF_ELEV` with coefficient `+1`, **ecosys-ng's litter is thicker than the oracle's by ~0.0268 m** -- the direction over-inclusion predicts.

**Prediction made here and SUBSEQUENTLY REFUTED**: per m2 of cell area, 0.0268 m of excess thickness is 0.0268 m3, requiring about `0.0268 / 4.0e-5 =` **670 g C m-2** of spurious pool-4 non-structural carbon, which would have made this defect the whole story. The `SURF_ELEV` trajectory refuted it the same day -- the error is ~1e-3 m through day 12 and jumps at the snowmelt, so the second contributor named as the alternative is in fact the dominant one (`issue-094`). See the correction at the top. The arithmetic above remains valid as an *upper bound* on what pool-4 carbon could contribute, which the trajectory then bounds far lower still.

A further reason the strong form was implausible and should have been caught before filing: `initializeMappedSurfaceInPlace` (`soil/organic/initialization.zig:640-643`, `:682`) gives the surface layer carbon **only** in substrates 0, 1 and 2, and sets substrate-4 microbial carbon to `residue_microbial_fraction * 0 = 0`. So pool-4 non-structural carbon starts at **exactly zero** and can only grow through the hourly processes -- it cannot support a near-constant 0.0268 m offset, and the early-season agreement (day 12: `-2.9e-6`) is exactly what that zero start predicts.

### Consequence 2: pools 0,1,2 are under-included (opposite sign, smaller)

Legacy's DOC group has **six** terms; ecosys-ng has **four**. The missing two are the macropore pools `OQCH` (macropore DOC) and `OQAH` (macropore acetate). ecosys-ng has **no macropore organic carbon state at all** -- a search across `ecosys-ng/src` finds `macropore` only on dissolved **gas** transport (`hourly_heat_water_solute.zig:3276-3278`, `hourly_gas_surface_water.zig:246`) and never on organic carbon, and `soil/organic/initialization.zig` contains no occurrence of the word. The legacy mapping is therefore `dissolved`->`OQC`, `adsorbed`->`OHC`, `dissolved_acetate`->`OQA`, `adsorbed_acetate`->`OHA`, with `OQCH` and `OQAH` unrepresented.

This pushes thickness the **other** way, so the two consequences partially cancel and the net 0.0268 m is a lower bound on the individual magnitudes. It is also a broader question than litter geometry -- whether macropore organic carbon is modelled at all is a science-scope matter, since `OQCH`/`OQAH` participate in transport throughout `redist.f`, not just in `RC0`. **Recorded here, but it deserves its own scope decision rather than being folded into this fix.**

## Why the geometry defect is not confined to a reported number

`litter_geometry.zig:63-88` feeds the pool sum into `dry_litter_volume_m3`, and from there into `pore_volume_m3`, `air_volume_m3`, `porosity_m3_per_m3`, `field_capacity_m3_per_m3` and `wilting_point_m3_per_m3`. Field capacity and wilting point are **water-solver inputs**, not diagnostics. So this is a candidate cause for the litter **water** divergence (`issue-087`, `issue-024`) and not only for the thickness readout -- which is exactly why it was worth chasing the geometry scalar first.

## Fix sketch, deliberately NOT applied

The change belongs at `litter_geometry_step.zig:121`, leaving `substrateCarbon_g_c` untouched: gather pools 0-2 with the existing all-inclusive total, and gather pool 4 from the **structural fractions only**. Pool 3 is already excluded by `litter_geometry.zig:60` so its composition is irrelevant to the geometry.

This needs a new narrow accessor on `Organic.State` (a `structuralCarbon_g_c(layer, substrate)` summing `structural[(layer*substrate_count + substrate)*structural_fraction_count + fraction]` over `fraction`), so the restricted composition is expressed once and testable, rather than open-coded at the call site.

**It is not applied in this session, on purpose.** The change alters field capacity and wilting point, which are water-solver inputs, and `issue-091` currently makes every production run impossible. `run-013` in this same session regressed the frontier by 280 hours precisely because two plausible science changes were landed together without production validation. Landing an unvalidatable solver-input change would repeat that error. Per `PROJECT_CONTRACT.md` this stays `unresolved` rather than being converted to a pass.

**Required before it lands**: (1) `issue-091` cleared so a production run is possible; (2) an instrumented measurement of pool-4 non-structural carbon at `L=0` to confirm the 670 g C m-2 prediction; (3) a regression test pinning `RC0(4)` to the structural-only composition with the `redist.f:5533-5599` bounds cited; (4) a full-suite run and a production run compared against the oracle on `SURF_ELEV`/`ACTV_LYR`.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/redist.f --lines 5524-5600   # per-pool RC0 bounds
uv run ecosys-audit/scripts/f77query.py show f77src/starts.f --lines 1486-1572   # the DIFFERENT init bounds
uv run ecosys-audit/scripts/f77query.py show f77src/hour1.f  --lines 4350-4356   # geometry reads pools 0,1,2,4
uv run ecosys-audit/scripts/f77query.py grep 'ORC\(2,0:2|OQC\(0:|OMC\(3,7'       # 0:4 / 0:5 dimensions
```

Then read `ecosys-ng/src/surface/litter_geometry_step.zig:121` against `ecosys-ng/src/soil/organic/initialization.zig:487-499`.

**Tool limitations, quoted as required**: `f77query.py` reports its own scope as text parsing only -- it "does not compile the model, prove equivalence, or decide a gate". Every claim above is a reading of source text on both sides plus one already-recorded `outcompare.py` bias figure. **No claim here is backed by a model run**, and the 670 g C m-2 figure is arithmetic on the observed bias, not a measurement. Note also that `f77query.py grep` truncates fixed-form continuation lines in its output: the DOC add at `redist.f:5579` initially appeared to be `OQC+OQCH` only, and its full six-term form was visible only after `show` was used on the line range. Prefer `show` over `grep` when a statement may continue.
