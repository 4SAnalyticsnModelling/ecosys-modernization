# run-014 -- first quantitative legacy-oracle vs ecosys-ng output comparison (hours 1-3,252), and confirmation that the hour-3,253 frontier is unchanged

Date: 2026-09-21. Lane: editor (Claude Code), adversarial Claude/Pi session. One heavy run at a time respected.

**This is diagnostic evidence, not acceptance evidence.** Completion proof is ABSENT on both sides (see below). Nothing here may be read as satisfying the "outputs comparable to the legacy oracle" release criterion.

## Headline results

1. **The hour-3,253 frontier is confirmed unchanged on the reverted source**, with a bit-for-bit identical failure signature. This independently validates run-013's revert and confirms that run-013's hour-2,973 failure was a genuine regression introduced by that round's changes, not a pre-existing condition.
2. **The first real quantitative comparison against a legacy oracle in this project's history**: 3,252 matched hours, two streams, 46 columns accounted for individually.
3. **The deep soil profile agrees with the oracle to machine precision, and divergence increases monotonically toward the surface.** This independently reproduces `issue-024`'s central characterization by a completely different route (output comparison rather than solver instrumentation), and it is the strongest evidence yet that the translation is fundamentally sound and the divergence is localized.

## Configuration

- Candidate binary: `ecosys_ng.exe`, SHA-256 `330E931555726F10047068D8BE6842A9BC3358DA664C5171506C284C0FA893D7`, `zig build -Doptimize=ReleaseFast` exit 0, Zig 0.16.0, built from the post-revert source at commit `4f15771` lineage (working tree clean of source changes; only `audit/` and `ecosys-audit/scripts/` had additions).
- Candidate run: fresh from hour 1, no checkpoint, `ecosys_ng.exe runottawa` with cwd set to a `robocopy /E` scratch copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/` (`/XD runottawa_output_files`, recreated empty). The tracked deck was never written to.
- Oracle: the preserved gfortran 16.1.0 artifact recorded in `issue-084`, whose source is content-identical to this checkout's `f77src` except the single documented `EXTERNAL SPLIT` line in `soil.f`. Integrity re-verified by hash against its own `PROVENANCE.md`.
- Tool: `ecosys-audit/scripts/outcompare.py` (added this session).

## Completion status -- the mandatory separate proof, and it fails on both sides

| side | reached | stopped by |
|---|---|---|
| ecosys-ng | hour **3,252** accepted, failed at **3,253** of 262,920 (1.24%) | `RuntimeSoilPoreCapacityExceeded`, `issue-078` |
| oracle | hour **6,875** of 262,920 | `issue-023`'s `grosub.f:12766` format/argument abort at day 286, per `issue-084` |

Two equally truncated files can look identical, so this is stated first and never treated as a pass.

The candidate's failure is bit-for-bit the documented one:

```
error: runtime soil entry pore capacity exceeded: cell=0 layer=1 index=1
  previous_matrix_capacity_m3=7.670613113153217e-3
  refreshed_matrix_capacity_m3=7.654774304374367e-3
  matrix_occupied_m3=8.535563021092726e-3
  previous_matrix_excess_m3=8.6494990793...e-4
error: RuntimeSoilPoreCapacityExceeded
```

`census_positive_control entries=3252 first_hour=1 last_hour=3252`. The `8.649499e-4` excess matches `issue-078`'s dynamic-diagnosis measurement exactly.

**Note for `issue-083`**: run-013's candidate fix was aimed at precisely this hour and **never reached it** -- that run died at 2,973. So the fix was never actually exercised against its own target. That does not rehabilitate it (it broke something earlier, which is disqualifying on its own), but "it failed to fix hour 3,253" would be the wrong summary; "it never got there" is the accurate one.

## Alignment -- validated, not assumed

Both streams: **matched=3,252, candidate_only=0, oracle_only=3,623** (the oracle's longer horizon), first matched hour 1, last 3,252.

**Calendar cross-check: 3,252/3,252 agree** on both streams. The key is the cumulative 1-based hour of the simulated year, derived independently on each side (`DOY*24` for the oracle; `(day_of_year-1)*24 + hour + 1` for the candidate), and then the separately-printed year/month/day/hour fields are required to match on every key. Two alignment traps were found and are now encoded in the tool:

- The legacy `DATE` field is **DDMMYYYY**, not MMDDYYYY (elapsed day 2 prints `02011998`). A first attempt keyed on a MMDD reading matched only 1,052 of a possible 2,972 rows while looking superficially plausible.
- The legacy hour is 1..24 and the candidate hour is 0..23 **for the same instant**. That is a convention difference, not an off-by-one, and it is confirmed by the calendar cross-check passing on every row.

## Units -- verified against the value producer, not inferred from names

Established before any number was compared, and independently re-derived by the reviewer lane (round 18):

- Carbon/oxygen fluxes: `outsh.f:54-57` multiplies by `23.14815 = 1e6/(12*3600)` and `8.68056 = 1e6/(32*3600)`, i.e. g m-2 h-1 -> **umol m-2 s-1**, matching the candidate's declared `umol m-2 s-1`. No conversion applied or needed.
- Dissolved concentrations: written raw (`outsh.f:58-61`, `CCO2S`/`COXYS`), and `hour1.f:3778-3780` defines them as `CO2S(L)/VOLW(L)` and `OXYS(L)/VOLW(L)` -- **mass per m3 of liquid water**, matching `g C m-3 water` / `g O2 m-3 water`.
- Water/ice layer columns: `WTR_k` is `THETWZ(k)` and `ICE_k` is `THETIZ(k)` (`outsh.f:125-135`, `:146-155`), dimensionless volumetric contents, matching the candidate's `m3 m-3`.

## Hourly water stream (`f25wh1`), 3,252 pairs

Rule: `abs(candidate-oracle) <= 1e-12 + 1e-6*abs(oracle)` -- a deliberately tight **triage** rule, not a reviewed acceptance threshold.

| column | max abs err | MAE | bias | exceedances |
|---|---|---|---|---|
| EVAPN | 5.270e-1 | 3.882e-2 | +3.116e-2 | 3252 |
| RUNOFF | 3.432e+0 | 8.255e-2 | +2.857e-2 | **675** |
| SEDIMENT | 1.471e-4 | 5.043e-5 | -5.043e-5 | **1115** |
| DISCHG | 2.522e+0 | 1.357e-1 | +3.154e-2 | 3252 |
| SNOWPACK | 1.116e+2 | 1.678e+1 | +1.423e+1 | 3252 |
| WTR_1 | 7.325e-1 | 2.636e-1 | **+2.585e-1** | 3252 |
| WTR_2 | 2.957e-1 | 1.093e-1 | +1.041e-1 | 3252 |
| WTR_3 | 2.870e-1 | 1.074e-1 | +1.018e-1 | 3252 |
| WTR_4 | 2.429e-1 | 1.039e-1 | +1.018e-1 | 3252 |
| WTR_5 | 2.306e-1 | 1.011e-1 | +1.011e-1 | 3252 |
| WTR_6 | 2.211e-1 | 9.906e-2 | +9.906e-2 | 3252 |
| WTR_7 | 1.609e-1 | 5.982e-2 | +5.336e-2 | 3252 |
| WTR_8 | 1.498e-1 | 6.179e-2 | +6.118e-2 | 3252 |
| WTR_9 | 1.197e-1 | 5.638e-2 | +5.593e-2 | 3252 |
| WTR_10 | 4.450e-2 | 1.584e-2 | +1.569e-2 | 3252 |
| WTR_11 | 4.851e-2 | 2.603e-3 | -2.849e-4 | **2057** |
| WTR_12 | 1.543e-1 | 9.076e-3 | -9.073e-3 | **1964** |
| ICE_1 | 3.226e-1 | 8.074e-2 | -7.890e-2 | **1585** |
| ICE_2 | 1.945e-1 | 1.012e-2 | -9.216e-3 | **686** |
| ICE_3 | 1.439e-1 | 3.527e-3 | +3.527e-3 | **299** |
| ICE_4 | 1.064e-1 | 1.400e-3 | +1.400e-3 | **113** |
| ICE_5 | 9.499e-5 | 1.612e-7 | +1.612e-7 | **32** |
| ICE_6 | 1.115e-7 | 1.682e-10 | +1.682e-10 | **25** |
| ICE_7 | 9.267e-11 | 1.699e-13 | +1.699e-13 | **21** |
| ICE_8 | 1.533e-13 | 1.260e-16 | +1.260e-16 | **0** |
| ICE_9 | 1.090e-16 | 2.301e-17 | +2.301e-17 | **0** |
| ICE_10 | 6.054e-17 | 1.273e-17 | +1.273e-17 | **0** |
| ICE_11 | 6.054e-17 | 3.090e-18 | +3.090e-18 | **0** |
| ICE_12 | 4.407e-15 | 5.898e-18 | +5.898e-18 | **0** |

### The important structure in that table

**The ice profile is a clean monotonic ladder from machine precision at depth to gross divergence at the surface**, spanning thirteen orders of magnitude:

```
ICE_12..ICE_8   max err 1e-17 .. 1e-13      0 exceedances   (machine precision)
ICE_7                       9.3e-11        21
ICE_6                       1.1e-07        25
ICE_5                       9.5e-05        32
ICE_4                       1.1e-01       113
ICE_3                       1.4e-01       299
ICE_2                       1.9e-01       686
ICE_1                       3.2e-01      1585              (surface)
```

Five of the twelve ice layers agree with the oracle to **binary64 round-off with zero exceedances of a 1e-12 absolute rule**. A translation that was structurally wrong could not produce that. This is direct, independent, output-level confirmation of what `issue-024` round 11 concluded from the solver side: *"divergence exactly where phase change is active... agreement to 6+ figures at depth."* Nothing in this run was instrumented to produce that agreement; it falls out of the raw output files.

**The liquid-water profile has the matching signature, with the sign that matters.** `WTR_1`'s bias is **+0.2585 m3 m-3** -- the candidate is systematically **wetter** at the surface -- decaying with depth (+0.104 at layers 2-6, +0.055 at 7-9, +0.016 at 10) and reversing to slightly negative at layers 11-12. `issue-024` independently documented this deck's "chronically-elevated-water divergence" in the top layers from solver traces; here it is, quantified over 3,252 hours, in the production output.

**Columns that mostly agree** are as informative as those that do not: `RUNOFF` exceeds on 675 of 3,252 hours, `SEDIMENT` on 1,115, `WTR_11`/`WTR_12` on ~2,000, and `ICE_2`-`ICE_4` on 113-686. These are not uniform failures; they are episodic, which points at event-driven divergence (precipitation, freeze/thaw episodes) rather than a constant offset.

`SNOWPACK` is the largest relative outlier (bias +14.2 mm, max 111.6 mm) and is **not** explained by anything in this record. It deserves its own diagnosis and is the single most valuable unclaimed lead here.

## Hourly carbon stream (`f25ch1`), 3,252 pairs

| column | max abs err | MAE | bias | exceedances |
|---|---|---|---|---|
| SOIL_CO2_FLUX | 8.693e+0 | 9.785e-1 | +8.508e-1 | 3252 |
| ECO_CO2_FLUX | 8.693e+0 | 9.785e-1 | +8.508e-1 | 3252 |
| CH4_FLUX | 3.265e+0 | 2.548e-1 | -2.544e-1 | 3252 |
| O2_FLUX | 1.297e+2 | 1.636e+0 | -1.115e+0 | 3252 |
| CO2_1..CO2_4 | 3.57e+1 .. 7.19e+1 | 1.09e+1 .. 2.46e+1 | +6.6e+0 .. +2.38e+1 | 3252 |
| O2_1..O2_9 | 2.21e+1 .. 3.03e+1 | 1.01e+1 .. 1.69e+1 | +3.5e+0 .. +1.41e+1 | 3252 |

`SOIL_CO2_FLUX` and `ECO_CO2_FLUX` have **identical** statistics on both sides, which is the expected consistency check for a period with no live plant: the soil flux *is* the ecosystem flux, and both implementations agree that it is.

### The dissolved-gas columns are explained by construction, and must not be "fixed"

All thirteen `CO2_k`/`O2_k` columns are concentrations, defined as dissolved mass divided by layer liquid water (`hour1.f:3778-3780`). Two effects therefore feed them, and the second is decisive:

1. The denominator differs, because the layer water content differs (the `WTR_k` biases above).
2. **The numerator is initialized differently on purpose.** `starte.f:1419-1430` seeds every legacy aqueous pool with a trailing `*FC(L,NY,NX)` -- a *dimensionless* field-capacity fraction -- while the gaseous seeds on the preceding lines use the air volume `VOLP(L)` in m3. ecosys-ng's own source records this as **`STARTE-010`** (`soil/gas/inventory_initialization.zig:39-57`), states that "production passes `state.matrix_liquid_water_m3` and is dimensionally right where the source is not", and warns in advance: *"a later legacy comparison of day-zero dissolved gas will differ by construction and must not be 'reconciled' toward the source."*

This run is that later comparison, and the prediction holds. Disposition for the dissolved-gas columns: **`legacy-defect-corrected`, expected divergence, do not reconcile.** That same source note also records "Not verified: the magnitude of `FC/VOLW` in the shipped Ottawa profile... I did not build or run the Fortran" -- this run supplies the first real measurement against that open item, though deriving the exact predicted ratio from `FC=0.28` and the run's `VOLW` is **not** done here and should not be assumed to match the observed ratios.

The four flux columns are **not** covered by that explanation and remain unattributed.

## Columns accounted for but excluded, with citations

Never silently dropped, and never counted as passes:

- `CH4_15`, `WTR_13`-`WTR_20`, `ICE_13`-`ICE_20` -- **`issue-085`**: the deck selects soil layers beyond the 12-layer runtime profile. The oracle emits structural zeros from its fixed `JZ=20` arrays; ecosys-ng emits no column. 17 columns.
- `TTL_SWC` -- **`issue-086`**, a confirmed wrong binding: the oracle writes total cell water storage (`UVOLW*1000/AREA`, `outsh.f:121`) and ecosys-ng writes root water uptake in the same slot. Comparing them would compare a storage term against a flux. Excluded until the binding is fixed.
- `SURF_WTR`, `SURF_ICE` -- **`issue-086` second finding**, a label/unit defect only: the candidate value is the correct `THETWZ(0)`/`THETIZ(0)` analogue but is published as a depth in `m` rather than a dimensionless fraction.

## Limitations, to be quoted with every number above

- **Completion proof is absent on both sides** (top of this record). This is diagnostic evidence only.
- The oracle is a *derived* artifact: reconstructed inputs, GNU rather than the makefile's Intel target, most coupled-gas state absent from the fixed-width outputs. Its own provenance calls it "not a trusted historical baseline." See `issue-084`.
- The comparison rule is a triage rule. Per-quantity reviewed thresholds do not exist yet and are required before any acceptance claim.
- Only 2 of the 10 soil streams were compared (hourly carbon and hourly water). Energy, nitrogen, phosphorus, the five daily streams, and every plant stream are untouched.
- No unit conversion was applied anywhere; the mapping was verified unit-compatible first, column by column.
- Nothing was smoothed, interpolated, clipped, or reset.

## Next bounded actions

1. **Diagnose `SNOWPACK`** (bias +14.2 mm, max 111.6 mm, every hour). Largest unexplained single-column divergence and not covered by any existing issue. `outsh.f:123-124` gives the oracle expression `(VOLSS+VOLIS*DENSI+VOLWS)*1000/AREA`; the candidate's is `soil/water/output.zig:138`. Start there -- it may be as simple as a component missing from the sum.
2. **Fix `issue-086`** (both findings). The correct quantity already exists in the tree as daily `soil_water_storage` (`output_catalog.zig:134`, producer `daily_output.zig:365`, the same `*1000/area` form), and the daily catalog already uses the correct `surface_volumetric_liquid_water_fraction[m3 m-3]` naming the hourly one gets wrong. Pin slot 4 with a regression test citing `outsh.f:121`.
3. **Extend `outcompare.py`** to the energy, nitrogen and phosphorus streams, and to the daily cadence, verifying units per stream against `outsh.f`/`outsd.f` first.
4. Do **not** re-run the production deck to reach a later hour: the frontier is a known blocker with a documented, escalated next step (`issue-083`), and this run already supplies 3,252 hours of comparable output.

## Addendum, same session: energy and nitrogen streams added -- ALL FOUR hourly soil streams in this deck are now compared

The deck emits four hourly soil streams (`f25ch1`, `f25wh1`, `f25eh1`, `f25nh1`); hourly phosphorus is not emitted by this deck, so **hourly soil coverage is now complete**. The five daily soil streams and all plant streams remain untouched.

### Input equivalence is PROVEN -- the contract's mandatory first diagnosis step

The energy stream's first columns are pure weather forcing, so they double as an input-equivalence test. Over 3,252 matched hours:

| column | max abs err | exceedances |
|---|---|---|
| `WIND` | **0.000000e+00** | **0** |
| `AIR_TEMP` | 2.309e-14 | **0** |
| `HUM` | 4.970e-07 | **0** |
| `SOL_RADN` | 3.846e+01 | 54 |
| `PREC` | 4.600e+00 | 218 |

`WIND` is **bit-identical in every one of the 3,252 hours** and `AIR_TEMP` agrees to binary64 round-off. The two runs are driven by the same weather record. **Unequal inputs/initialization -- the first item in `PROJECT_CONTRACT.md`'s prescribed diagnosis order -- is therefore eliminated as an explanation for every other divergence in this record.** That is a significant result in its own right: it means the remaining divergences must be explained by parsing/output semantics, bindings, translation, convergence, or approved physics, and not by the forcing.

`PREC`'s 218 exceedances turned out to be a semantics defect, not a forcing difference -- filed as **`issue-088`**: the legacy column is `(PRECR+PRECW)` = rain + **snowfall** excluding irrigation (`outsh.f:254-255`), while ecosys-ng's is rain + **irrigation** excluding snowfall (`soil/heat/output.zig:95`). It differs in both directions. Bias is negative and the 6.7% hit rate matches an Ottawa Jan-May snowfall frequency.

`SOL_RADN`'s 54 exceedances are **recorded but not claimed** as a finding: small absolute magnitudes (first at hour 464, oracle 1.350 vs candidate 1.587 W m-2), consistent with low sun angle. The check it needs is stated in `issue-088`.

### Energy stream: the same surface-concentrated signature, in a third independent quantity

| column | max abs err | MAE | bias | exceedances |
|---|---|---|---|---|
| SOIL_RN / ECO_RN | 3.545e+2 | 2.977e+1 | -9.833e+0 | 3252 |
| SOIL_LE / ECO_LE | 1.971e+2 | 2.153e+1 | +1.019e+1 | 3252 |
| SOIL_H / ECO_H | 4.705e+2 | 4.847e+1 | -4.056e+0 | 3252 |
| SOIL_G / ECO_G | 8.535e+2 | 3.511e+1 | +7.872e+0 | 3252 |
| TEMP_1 | 2.558e+1 | 2.663e+0 | +4.069e-1 | 3252 |
| TEMP_5 | 1.068e+1 | 1.713e+0 | +9.707e-2 | 3252 |
| TEMP_9 | 5.932e+0 | 1.098e+0 | -9.862e-2 | 3251 |
| TEMP_11 | 2.459e+0 | 6.397e-1 | -4.568e-1 | 3251 |
| TEMP_LITTER | 2.459e+1 | 2.750e+0 | +5.053e-1 | 3252 |

Soil temperature error **decays monotonically with depth**, MAE 2.66 degC at layer 1 to 0.64 degC at layer 11, with `TEMP_LITTER` (2.75) the worst. **Ice, liquid water and temperature now all show the same surface-concentrated structure**, which is three independent quantities agreeing on where the problem is. The `SOIL_*`/`ECO_*` pairs are identical to each other on both sides, the expected consistency check for a period with no live plant.

`TEMP_16` is excluded as `issue-085` class (layer 16, profile has 12).

### Nitrogen stream: maps 1:1, bindings and units correct, no new defects

13 data columns on each side, a clean 1:1 mapping with **no exclusions needed** -- the first stream to require none. Units verified: slots 1-3 are `H*G/AREA` (g N m-2 h-1), slots 4-5 divide by `TAREA` (the landscape area, the same convention the water stream's `RUNOFF`/`SEDIMENT`/`DISCHG` use), and slots 6+ are raw `CZ2OS(k)` which `hour1.f:3782` defines as `Z2OS(L)/VOLW(L)`, g N m-3 water.

| column | max abs err | MAE | bias | exceedances |
|---|---|---|---|---|
| N2O_FLUX | 4.065e-4 | 3.386e-5 | +3.382e-5 | 3252 |
| N2G_FLUX | 1.333e+0 | 7.020e-2 | +5.146e-2 | 3252 |
| NH3_FLUX | 3.561e-5 | 2.009e-6 | +1.675e-7 | 3252 |
| SURF_N_FLUX | 5.406e-2 | 2.162e-2 | -2.162e-2 | **1632** |
| SUBS_N_FLUX | 1.246e+0 | 7.486e-1 | +2.893e-1 | 3252 |
| N2O_1 | 4.263e-1 | 5.108e-2 | -4.985e-2 | 3252 |
| N2O_6 | 8.948e-3 | 1.883e-3 | -6.214e-5 | 3252 |
| N2O_8 | 4.589e-2 | 2.552e-3 | -7.156e-4 | 3252 |

Absolute magnitudes are small (N2O and NH3 fluxes at 1e-4 to 1e-6 g N m-2 h-1), the dissolved N2O profile shows the same depth decay, and `SURF_N_FLUX` is episodic (1,632 of 3,252) rather than uniformly wrong. `SUBS_N_FLUX` (drainage) has the largest relative error and is the one nitrogen column worth a second look, though it depends directly on the water fluxes that are already known to diverge.

**That this stream needed no exclusions is itself evidence**: the three defects found so far (`issue-085`, `issue-086`, `issue-088`) are specific mistakes, not a systemic problem with how ecosys-ng maps the editor ladder.

Machine-readable reports: `audit/manifest/outcompare-heat-hourly-2026-09-21.json`, `outcompare-nitrogen-hourly-2026-09-21.json`.

## Addendum 2026-09-22: DAILY water stream added (42 snapshot columns), obtained with no production run

`issue-091` blocks all production runs, so this used `run-014`'s outputs already on disk. `outcompare.py` now detects cadence from the legacy header itself (`outsh.f` streams carry a `HOUR` column, `outsd.f` daily streams do not) and keys daily streams on day of year.

**135 matched days, `candidate_only=0`, calendar cross-check 135/135 agree.** Six annual-cumulative flux columns are excluded with an `issue-092` citation rather than compared, plus `WTR_13`/`ICE_13` as `issue-085` class. 42 snapshot columns compared.

### The depth gradient reproduces at daily cadence

```
ICE_12..ICE_6   max err 1e-17 .. 5.0e-13     0 exceedances
ICE_5                      5.9e-08           2
ICE_4                      1.1e-01           6
ICE_3                      1.3e-01          13
ICE_2                      1.9e-01          29
ICE_1                      3.2e-01          65      (surface)
```

Seven of twelve daily ice layers agree to round-off with **zero** exceedances. Same structure the hourly stream showed, now independently at a different cadence and through a different writer (`outsd.f` rather than `outsh.f`).

### Corroboration for the `issue-086` rename

`SURF_WTR` max abs error **5.08e-3** with only 74 of 135 exceedances, and `SURF_ICE` max **5.85e-5** with **3**. These are the two quantities whose *hourly* counterparts were published as `surface_excess_*_depth` in metres until this session renamed them to the volumetric fractions they carry. The daily stream, which already used the correct names, agrees with the oracle well -- independent evidence that the quantity was right all along and only the hourly label was wrong.

### Two candidate findings, recorded but NOT claimed

Neither is filed as a defect yet; both need their value producer read before anyone acts.

1. **`PSI_SURF` is a large outlier**: max abs error **2.178e+4**, MAE **7.675e+3**, bias **-7.675e+3**, all 135 days exceeding, against `PSI_2`-`PSI_10` whose max errors run from 1.22 down to 0.012. The oracle writes `PSISM(0,NY,NX)` **alone** (`outsd.f:160`) while the layer columns are `PSISM(k)+PSISO(k)` (`:148-157`) -- matric only at the surface, matric plus osmotic below. A magnitude near 1e4 MPa is also physically extreme for a water potential. Candidate causes, in the order the contract wants them checked: an osmotic term included on the candidate side where the oracle has none, or a unit mismatch. `PSI_1` is also elevated (max 390.2, MAE 17.2) against `PSI_2`'s 1.22, consistent with the surface-concentrated pattern rather than being separate.
2. **`SURF_ELEV` and `ACTV_LYR` look like a paired sign or mapping issue.** Their biases are near-exactly equal and opposite -- `+2.68165e-2` against `-2.68200e-2` -- with near-identical max errors (`8.321e-2`, `8.295e-2`). That symmetry is unlikely to be two independent physical differences. Oracle `:161-165` writes `SURF_ELEV = -CDPTH(NU-1)+DLYR(3,0)`, `ACTV_LYR = -(DPTHA-CDPTH(NU-1)+DLYR(3,0))`, `WTR_TBL = -(DPTHT-CDPTH(NU-1))`; the candidate names are `active_surface_depth`, `active_layer_depth_below_surface`, `water_table_depth_below_surface`. Magnitudes are small (~0.027 m), so this is low-severity, but the symmetry is worth resolving rather than averaging away.

### Storage and water-table columns

`WATER` (the `UVOLW` snapshot, correctly bound in the daily stream per `issue-092`) has max **235.7 mm**, MAE **107.3**, bias **+102.5**, all days exceeding -- yet day 1 agrees to 0.5% (oracle 805.77 against candidate 801.72). So the two profiles start together and separate, which is consistent with the `WTR_1`-`WTR_10` high bias rather than an independent storage defect. `WTR_TBL` max 0.926 m, MAE 0.373.

Machine-readable report: `audit/manifest/outcompare-water-daily-2026-09-22.json`.

### Candidate 1 (`PSI_SURF`) RESOLVED 2026-09-22: a downstream symptom, NOT a defect -- do not file it

Both of my own hypotheses for it are refuted, and the resolution matters because it stops someone chasing a spurious defect.

**Hypothesis A -- "the candidate includes an osmotic term the oracle omits" -- WRONG.** The oracle writes `PSISM(0,NY,NX)` alone (`outsd.f:160`) and ecosys-ng's daily stream writes `surface_matric_potential_megapascal` (`soil/diagnostics/daily_output.zig:326`, emitted `:392`), fed from `surface_litter_water_environment_state.matric_water_potential_megapascal` (`ecosys_ng.zig:1952`). **Both are matric-only.** The layer columns are matric-plus-osmotic on both sides (`outsd.f:148-157`; `daily_output.zig:325`). The naming and the pairing are correct.

**Hypothesis B -- "ecosys-ng is missing the oracle's floor" -- ALSO WRONG.** The oracle clamps the sub-wilting branch with `AMAX1(PSISX,...)` (`hour1.f:4387`), and `PSISX` is defined at `starts.f:78`:

```fortran
DATA PSIPS,PSIHY,PSISX/-0.5E-03,-1.5E+04,-1.5E+12/
```

so `PSISX = -1.5e+12` MPa. ecosys-ng's retention curve carries `minimum_water_potential_megapascal = -1.5e12` -- **the identical value, faithfully ported**. Neither side's floor was active in the sampled days, so the clamp explains nothing here.

**What it actually is.** The raw values, sampled on the correct columns (`PSI_SURF` is oracle field 49; the candidate's is index 51, `surface_water_potential[MPa]` -- an earlier ad hoc check of mine read index 52, `active_surface_depth[m]`, and produced nonsense positives):

| day | oracle `PSI_SURF` (MPa) | ecosys-ng (MPa) |
|---|---|---|
| 1 | -7.464 | -2.1109077184563387e2 |
| 5 | -1.295 | -2.1109077184563387e2 |
| 20 | -0.01076 | -2.167245975419449e3 |
| 60 | -0.005278 | -2.1688935953890094e4 |
| 100 | -85.02 | -2.1109077184563387e2 |
| 130 | -0.004694 | -2.1109077184563387e2 |

The litter retention curve is exponential in log water content (`hour1.f:4386-4397`; `surface/litter_water_environment.zig:72-82` via `curve.waterPotentialMpa(retained_water_fraction)`), so a modest difference in litter **water content** is amplified into an orders-of-magnitude difference in **potential**. And a litter water divergence is already independently established: `WTR_1` bias **+0.2585 m3 m-3** (`run-014`), `issue-087`'s ~47-day snow persistence over the litter, and the tillage residue-incorporation step that empties the litter by 1000x.

So `PSI_SURF` is a **downstream symptom of the litter/surface water divergence**, on the most sensitive diagnostic available. It is the wrong place to attack; the litter water content is the right place, and that is already tracked by `issue-087` and `issue-024`.

**One observation kept, not escalated**: `-2.1109077184563387e2` repeats **bit-for-bit** on days 1, 5, 100 and 130 -- distant days with different weather. That means the candidate's litter retained-water *fraction* is pinned to a recurring value on those days, which `surface/litter_water_environment.zig:69` computes as `min(water_retention_capacity_m3, litter_water_m3) / dry_litter_volume_m3`. A recurring exact value points at the `water_retention_capacity_m3` branch binding (i.e. litter at capacity), not at a stuck carrier. Worth a look if anyone diagnoses `issue-087`, since it is a direct readout of litter wetness, but it is not itself evidence of a defect.

**Candidate 2 (`SURF_ELEV`/`ACTV_LYR` paired sign symmetry) remains open and unexamined.**

### Candidate 2 (`SURF_ELEV`/`ACTV_LYR`) RESOLVED 2026-09-22: the formulas are faithful; one shared INPUT differs

Also not a defect in the output layer, and the resolution names a specific quantity.

**The formulas are exact.** `soil/diagnostics/daily_output.zig:400-408` reproduces `outsd.f:161-165` term for term, and even quotes the source expressions in its own comment at `:396-397`:

```zig
values[i] = -inputs.mineral_soil_surface_depth_m + inputs.surface_litter_thickness_m;              // SURF_ELEV
values[i] = -(inputs.active_layer_bottom_depth_m - inputs.mineral_soil_surface_depth_m
              + inputs.surface_litter_thickness_m);                                                // ACTV_LYR
values[i] = -(inputs.water_table_depth_m - inputs.mineral_soil_surface_depth_m);                   // WTR_TBL
```

against

```fortran
K=48  -CDPTH(NU-1)+DLYR(3,0)
K=49  -(DPTHA-CDPTH(NU-1)+DLYR(3,0))
K=50  -(DPTHT-CDPTH(NU-1))
```

So the sign/mapping hypothesis is refuted: the signs, the ordering and the litter term are all correct.

**What the symmetry actually means.** `surface_litter_thickness_m` enters `SURF_ELEV` with coefficient **+1** and `ACTV_LYR` with **-1**. A single difference `d` in that one input therefore produces `+d` in one column and `-d` in the other -- which is precisely the observed `+2.68165e-2` against `-2.68200e-2`, with near-identical max errors (`8.321e-2`, `8.295e-2`). The two columns are not two findings; they are **one input difference seen twice, with opposite sign**.

**Identified quantity**: ecosys-ng's **surface litter thickness differs from the oracle's by about 0.027 m** (mean), up to ~0.083 m. `WTR_TBL` carries no litter term, which is why its error (MAE 0.373 m) has an unrelated structure and is not explained by this.

That routes back to the same place everything else on this surface does: litter state. `issue-087` (snow persisting ~47 days over the litter), the tillage residue-incorporation step that empties the litter, and `WTR_1`'s `+0.2585 m3 m-3` bias are all the same neighbourhood. **Litter thickness is a new, concrete, low-noise handle on it** -- a geometry scalar rather than a solver-coupled quantity, so it should be considerably easier to diagnose than the water content itself.

### Both candidates resolved -- what it adds up to

Neither is an output-layer defect, and in both cases the output code proved faithful to the source. `run-014`'s surviving output-layer defects remain exactly `issue-085`, `issue-086`, `issue-088` and `issue-092`. What the two resolutions add is convergence: the surface/litter region now accounts for the ice gradient, the liquid bias, the snow persistence, the surface matric potential and the litter thickness -- five independent readouts of one underlying divergence rather than five problems.
