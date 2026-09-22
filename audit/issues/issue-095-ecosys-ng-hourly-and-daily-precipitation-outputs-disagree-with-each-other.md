# Issue 095 -- ecosys-ng's hourly and daily precipitation outputs disagree with each other by 232 mm (2.3x), while the oracle's two agree exactly

Status: **LARGELY SUPERSEDED BY EXISTING REGISTERED WORK; two of my claims here are WRONG and withdrawn. The measured 232 mm column gap is real, but the framing and two conclusions are not. See the correction below and `issue-097`.**

> ### CORRECTION, same day, after consulting the reference documentation
>
> Three items, in descending order of how wrong I was. All references are to the reference
> `docs/` tree, which is absent from this repository (`issue-097`).
>
> **1. WITHDRAWN -- "no output slot publishes the legacy-comparable precipitation quantity".**
> False. `discrepancy_register.md:40163-40165` records that daily-heat `PRECN` (`= TRAI`,
> **daily** reset, `day.f:74`) matches modern `total_precipitation` to **rel 3.35e-16**, and
> concludes: *"the precipitation science is exact and the divergence was 100% output
> semantics."* A comparable column exists and agrees to machine precision. I compared the two
> wrong columns and inferred a missing quantity from it.
>
> **2. WITHDRAWN -- the `SOL_RADN` concern.** I reported 1,447 of 3,275 hours differing and
> called it "systematic rather than noise" and undiagnosed. `discrepancy_register.md:8707`
> records `SOL_RADN` at 2.4e-7 relative as agreeing **"to the writer's seven-digit floor"** --
> it is the `E16.7E3` output format's precision, not a physical difference. My comparison rule
> (`rtol = 1e-6`) is simply tighter than the format can express. Nothing to diagnose.
>
> **3. The hourly `PREC` deficit is already registered, and characterised more sharply than
> here.** `discrepancy_register.md:8699-8712`: earliest divergence 1998 day 1 hour 16, and the
> isolating evidence is that the column "agrees **exactly** on all 16 dry hours and fails on
> all 8 wet hours, **always with modern at zero**", classified as "suspected translation defect
> in weather ingestion or hour alignment, not a physics difference". **My "omits snowfall"
> explanation does not fit "modern at zero on wet hours" and is probably wrong** -- a snowfall
> omission would leave rain-only hours agreeing, not zero out wet hours. The register's own
> note that "a suppressed precipitation input would also bias the water balance, so this should
> be checked before the water-stream" analysis is exactly the connection `issue-094` needed.
>
> **What survives:** the measurement itself -- ecosys-ng's hourly stream sums to 179.300 mm
> and its daily-water stream to 411.07 mm over the same window, against the oracle's 351.600
> on both. The two ecosys-ng columns do disagree by 231.77 mm, and the daily one does add
> ground condensation and canopy input (`ecosys_ng.zig:3658-3659`) that `URAIN` excludes. The
> register's separate note that "`ET` does NOT improve... which independently confirms that ET
> carries a real magnitude gap on top of the semantics -- see the condensation defect"
> indicates the condensation term is already a tracked defect under that name.
>
> **Net**: this issue should be read as a corroborating measurement of two already-registered
> defects (the hourly ingestion defect and the condensation defect), not as a new finding. The
> arithmetic below is sound; the conclusions marked WITHDRAWN above are not.

Discovered while checking `issue-094`'s secondary observation, which had assumed the daily figure was the reliable one. It is not safe to assume either.

## The measurement

Both streams, same run (`run019`), same simulated period, summed over every matched key:

| stream | column | oracle | ecosys-ng |
|---|---|---|---|
| hourly `f25eh1` (3,275 h) | `PREC` / `rain_and_irrigation[mm]` | **351.600** | **179.300** |
| daily `f25wd1` (136 d) | `PRECN` / `rainfall[mm]` (candidate running-summed) | **351.60** | **411.07** |
| internal agreement | | **exact** | **off by 231.77 mm (2.29x)** |

The oracle's two independently produced columns agree to the three decimals printed. That is a strong cross-check that `PREC` (`outsh.f`, `(PRECR+PRECW)*1000/AREA`) and `PRECN` (`outsd.f:114`, `1000*URAIN/AREA`, with `URAIN=URAIN+WI` at `redist.f:4407`) are **the same physical quantity** in the legacy, and it independently validates the `--cumulate-candidate` running-sum method introduced for `issue-092`: applied to the oracle's own reset window it reproduces the oracle's own annual accumulator exactly.

ecosys-ng's two columns do not agree. Summing 3,275 hourly values gives 179.300 mm; summing 136 daily values gives 411.07 mm. Both are meant to be total precipitation over the same ~136 days.

`PREC` also differs from the oracle on **260 of 3,275 hours**, with a maximum single-hour difference of **4.600 mm** -- so this is not a rounding or accumulation artefact confined to one stream's bookkeeping; the hourly series itself departs from the oracle on specific hours.

## Why this is not explained away by the obvious candidates

- **Not a units problem.** Both sides declare mm and the oracle's own two columns agree in mm.
- **Not the `issue-092` accumulation-window defect.** That defect is about cumulative-against-per-day and is exactly what the running sum corrects for; the correction is validated above against the oracle. The 231.77 mm gap is between two *ecosys-ng* columns and survives it.
- **Not a window mismatch.** The hourly comparison covers 3,275 h (136.46 d) against the daily's 136 d, i.e. the hourly window is slightly *longer*, so it should if anything report *more*, not 232 mm less.
- **Possibly a naming/content mismatch**, and this is the most likely benign explanation, but it is still a defect: if the hourly `rain_and_irrigation` excludes something the daily `rainfall` includes (snowfall, snowmelt reaching the surface, or irrigation), then the two columns are different quantities published under names that imply the hourly is the *broader* of the two. The legacy's counterparts are the same quantity, so a divergence here means ecosys-ng is not slot-comparable on at least one of the two.

## RESOLVED, same day: BOTH columns are misbound, in OPPOSITE directions

The two columns have two different producers, and neither matches its legacy counterpart.

**What the legacy publishes.** Both legacy columns are the *same* quantity, which is exactly why they agree at 351.600:

```fortran
! redist.f:4405-4407 -- the daily accumulator
WI = (PRECQ(NY,NX) + PRECI(NY,NX)) * XNFH        ! precipitation + surface irrigation
URAIN(NY,NX) = URAIN(NY,NX) + WI                  ! -> outsd.f:114 PRECN
! redist.f:4422 -- the hourly carriers
! PRECA,PRECW = rain+irrigation, SNOWFALL (m3 h-1)  -> outsh.f PREC = (PRECA+PRECW)*1000/AREA
```

So the legacy quantity is **total precipitation (rain + snowfall) plus surface irrigation, with no condensation**. Note `PRECU`, subsurface irrigation, is deliberately routed elsewhere -- into `UVOLO` at `redist.f:4413` -- and so is *not* part of `URAIN`.

**What ecosys-ng publishes.**

| column | producer | contents | against legacy |
|---|---|---|---|
| hourly `rain_and_irrigation` | `ecosys_ng.zig:1177`, `atmospheric_state.rainfall_m[cell] * canopy_cell_area_m2[cell]` | rain (and irrigation) **only** | **omits snowfall** -> 172.30 mm too low |
| daily `rainfall` | `ecosys_ng.zig:3658-3659`, `atmospheric_state.precipitation_m[cell] * area + ground_surface_condensation_m3_per_h[cell] + canopy_atmospheric_input_m3` | precipitation **plus ground condensation plus canopy atmospheric input** | **adds two terms `URAIN` excludes** -> 59.47 mm too high |

The two producers use two different atmospheric fields -- `rainfall_m` against `precipitation_m` -- and the daily one then adds condensation on top. The comment at `:3655-3657` states the intent plainly ("This legacy precipitation/condensation carrier already includes ground condensation; include canopy and standing-dead condensation on the same boundary side"), so the daily value is a deliberately-constructed *boundary-ledger* input term. It is correct for closing a water budget and **wrong for the `PRECN` output slot**, which must be `URAIN`.

**The three numbers are quantitatively coherent**, which is what confirms the diagnosis rather than merely fitting it:

```
179.30  ecosys-ng hourly   = rain only
351.60  ORACLE, both       = rain + snowfall + surface irrigation
411.07  ecosys-ng daily    = the above + ground condensation + canopy input
```

and `351.60 - 179.30 = 172.30 mm`, which is a plausible January-to-mid-May snowfall water equivalent for Ottawa and is precisely the term the hourly column omits. The oracle's value sits between the two candidates, exactly as a correct middle term should.

### Consequence: this is an output-binding defect, NOT an input defect

The model is very likely being driven with the right water; it is *reporting* it through two slots that each measure something else. That is materially different from the forcing mismatch `issue-094` suspected, and it means:

- **The 172.30 mm "less rain" reading is an artefact** of the hourly slot omitting snowfall. It is not evidence that ecosys-ng receives less precipitation.
- **`issue-094`'s water-balance arithmetic must be redone** once a correct precipitation column exists. Its central findings -- artificial drainage 3.91 mm against 213.51 mm, and 186.21 mm more storage gain -- do not depend on the precipitation column at all and are unaffected.
- This joins `issue-086` and `issue-092` as an output-slot binding defect, and it is the same *class* as `issue-086`: a slot carrying a real, correctly-computed quantity that is not the quantity the legacy slot publishes.

### Fix sketch, not applied

Publish `URAIN`'s analogue in both slots: rain + irrigation + snowfall water equivalent, excluding ground/canopy condensation and excluding subsurface irrigation. The daily ledger's `rainfall_m3` should keep its present composition -- it is the boundary-closure term and `ecosys_ng.zig:1425` legitimately needs it that way -- so the output slot needs its **own** accumulator rather than reusing the ledger field that `:1931` currently reads. Not applied here because `issue-091` blocks production validation and this touches an output path that the conservation ledger also consumes.

### Still open

Whether the 260 differing hours cluster in time (a partition or phase defect) or scatter (a threshold defect). `outcompare.py --trace PREC` will show it. This is a smaller question now that the aggregate is explained, but a clustered pattern would indicate the rain/snow partition threshold itself differs, which the aggregate cannot distinguish from a pure omission.

## Why `issue-094`'s conclusion is ROBUST to the answer either way

This matters, because `issue-094` cited the daily figure and inferred ecosys-ng received *more* rain. That inference was wrong-signed if the hourly column is the correct one. The conclusion survives regardless:

| if the correct input is... | ecosys-ng's rain vs oracle | ecosys-ng's storage gain vs oracle | unexplained |
|---|---|---|---|
| hourly, 179.30 mm | **172.30 mm LESS** | 186.21 mm MORE | ~358 mm |
| daily, 411.07 mm | 59.47 mm MORE | 186.21 mm MORE | ~127 mm |

ecosys-ng gains 186 mm more storage than the oracle either way, and its artificial drainage is 3.91 mm against 213.51 mm either way. If the hourly column is the right one the picture is **worse**, not better: the profile would be accumulating 186 mm more water from 172 mm less input. So `issue-094`'s root-cause finding stands and this issue only sharpens it. `issue-094`'s secondary observation about "17% more precipitation" is corrected by this issue and should be read here instead.

## Secondary, recorded not yet diagnosed: SOL_RADN differs on 1,447 of 3,275 hours

Same hourly comparison: `SOL_RADN` sums to 432,458.376 on the oracle against 433,036.809 in ecosys-ng, a difference of 578.433 (**0.13%**), but spread over **1,447 differing hours** with a maximum single-hour difference of **38.456 W m-2** and MAE 0.177 W m-2. The aggregate is small, but a difference on 44% of hours is systematic rather than noise and is more consistent with a solar-geometry, time-centering or partition difference than with a forcing mismatch.

**This also corrects the standing session claim that input equivalence was proven.** What was proven is narrower than it was stated to be:

| forcing | max abs difference | verdict |
|---|---|---|
| `WIND` | **0.000000e+00** | bit-identical |
| `AIR_TEMP` | 2.309e-14 | equivalent |
| `HUM` | 4.970e-07 | equivalent for these purposes |
| `SOL_RADN` | 3.846e+01 | **NOT equivalent** -- 54 exceedances, 1,447 differing hours; undiagnosed |
| `PREC` | 4.600e+00 | **column not comparable** -- 218 exceedances, 260 differing hours, but now explained as the snowfall omission above, so it is NOT evidence of an input mismatch |

Only wind and air temperature were ever held to the bit-level standard. Radiation and precipitation were not checked until now. Precipitation turned out to be an output-binding defect rather than a forcing difference, so the honest statement is narrower than "both fail": **`SOL_RADN` is an unexplained difference on 44% of hours, and precipitation is untested as an input because no output slot currently publishes the comparable quantity.** Either way, no output comparison in this project should be described as resting on proven input equivalence -- three of the five forcing columns are either unverified or not comparable as published.

## Reproduction

```
uv run ecosys-audit/scripts/outcompare.py --stream heat_hourly \
  --oracle    <scratch>/oracle-ottawa/ottawa_run/01998f25eh1 \
  --candidate <scratch>/run019deck/runottawa_output_files/modelled_outputs/energy/...f25eh1.txt \
  --trace PREC --trace SOL_RADN
uv run ecosys-audit/scripts/outcompare.py --stream water_daily \
  --oracle <...>/01998f25wd1 --candidate <...>/...f25wd1.txt \
  --cumulate-candidate PRECN --trace PRECN
```

Sum the `oracle` and `candidate` fields of each `signed_error_trace` in the `--json` report.

**Tool limitations, quoted as required.** `outcompare.py` states it "does not prove either run reached its required end time; completion is a separate mandatory proof and neither side has it" -- the hourly comparison covers 3,275 of the oracle's 6,875 available hours and the daily 136 of 286 days, so nothing here speaks to the rest of the record. It "applies no unit conversion", so the mm and W m-2 readings rest on the `outsh.f`/`outsd.f` citations above. The default rule `abs(candidate-oracle) <= 1e-12 + 1e-6*abs(oracle)` is "a triage rule, not a reviewed scientific acceptance threshold", so the exceedance counts flag divergence rather than failing an agreed criterion -- but the 231.77 mm internal gap and the 172.30 mm `PREC` difference are far outside any plausible threshold. No number here comes from a model run performed in this session.
