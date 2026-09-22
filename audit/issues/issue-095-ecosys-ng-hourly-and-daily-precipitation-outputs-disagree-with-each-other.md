# Issue 095 -- ecosys-ng's hourly and daily precipitation outputs disagree with each other by 232 mm (2.3x), while the oracle's two agree exactly

Status: **OPEN, CONFIRMED, INTERNAL INCONSISTENCY IN ECOSYS-NG (filed 2026-09-22, adversarial Claude/Pi session).** Found run-free from outputs on disk while `issue-091` blocks runs. At most one of the two columns can be correct, so this is a defect regardless of which comparison one prefers -- no reading of the oracle is needed to establish that.

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

## What must be determined

1. **Which column, if either, is the true precipitation input to the model.** This is the question that matters, because it decides whether ecosys-ng is being driven with the same water as the oracle at all.
2. Whether `rain_and_irrigation` and `rainfall` are bound to different runtime quantities, and if so which legacy variable each is the analogue of.
3. Whether the 260 differing hours cluster in time (a partition or phase defect) or scatter (a threshold defect). Not yet checked; `outcompare.py --trace PREC` will show it.

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
| `SOL_RADN` | 3.846e+01 | **NOT equivalent** -- 54 exceedances, 1,447 differing hours |
| `PREC` | 4.600e+00 | **NOT equivalent** -- 218 exceedances, 260 differing hours |

Only wind and air temperature were ever held to the bit-level standard. Radiation and precipitation were not checked until now, and both fail. No output comparison in this project should be described as resting on proven input equivalence.

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
