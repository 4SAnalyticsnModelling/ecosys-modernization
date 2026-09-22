# Issue 088 -- hourly energy-stream precipitation column omits snowfall and adds irrigation; the legacy column is rain + snowfall

Status: **OPEN, CONFIRMED (filed 2026-09-21, adversarial Claude/Pi session).** A deck-selected production output column reports a different *set* of water inputs than the oracle's corresponding column, differing in **both** directions. Found by `run-014`'s comparison harness in the hourly energy stream, where the neighbouring columns are pure weather forcing and agree to machine precision -- which is what made a 218-hour disagreement in this one stand out as a semantics problem rather than a physics one.

Same class as `issue-086`. Third distinct output-semantics defect surfaced by the oracle comparison.

## The defect

Hourly energy/heat stream (`f25eh1`, `fouts.f` `N=25`), slot 5, `PREC`:

| side | value written | contents | citation |
|---|---|---|---|
| legacy | `(PRECR(NY,NX)+PRECW(NY,NX))*1000.0/AREA(3,NU(NY,NX),NY,NX)` | **rain + snowfall**, no irrigation | `outsh.f:254-255` |
| ecosys-ng | `(inputs.rainfall_m3 + inputs.irrigation_m3) * 1000.0 / area` | **rain + irrigation**, no snowfall | `soil/heat/output.zig:95` and `:135`, name at `soil/diagnostics/output_catalog.zig` (`rain_and_irrigation`, mm) |

`PRECR` and `PRECW` are settled by four independent legacy comments, so this is not an inference from variable names:

- `trnsfr.f:332` -- `PRECW,PRECR=snow,rain (m3 t-1)`
- `trnsfrs.f:421` -- `PRECW,PRECR=snow,rain from hour1.f (m3 t-1)`
- `redist.f:4422` -- `PRECA,PRECW=rain+irrigation,snowfall (m3 h-1)`
- `watsub.f:448` -- `PRECA,PRECW=rainfall+irrigation,snowfall (water equiv)`

The last two are the decisive pair: legacy keeps **`PRECA`** for rain+irrigation and **`PRECR`** for rain alone. `outsh.f:254` deliberately uses `PRECR`, not `PRECA`, so the legacy column excludes irrigation by construction, and it adds `PRECW` so it includes snowfall.

So the two columns differ twice over: **ecosys-ng omits snowfall and includes irrigation; the oracle includes snowfall and omits irrigation.**

## Measured signature, and why it is convincing

From `run-014` over 3,252 matched hours (1 Jan - 16 May 1998), the four neighbouring forcing columns in the same group are effectively identical:

| column | max abs err | exceedances of `1e-12 + 1e-6*|oracle|` |
|---|---|---|
| `WIND` | **0.000000e+00** | **0** |
| `AIR_TEMP` | 2.309e-14 | **0** |
| `HUM` | 4.970e-07 | **0** |
| `SOL_RADN` | 3.846e+01 | 54 |
| **`PREC`** | **4.600e+00** | **218** |

`WIND` is **bit-identical** in every one of the 3,252 hours and `AIR_TEMP` agrees to round-off. The two runs are therefore driven by the same weather record, which removes input inequivalence as an explanation and makes the `PREC` disagreement a definition problem rather than a forcing problem.

218 differing hours out of 3,252 is about 6.7%, a plausible snowfall frequency for an Ottawa January-May window, and the **bias is negative** (`-5.298e-2` mm, candidate lower) -- the direction expected if the candidate is dropping snowfall from the sum. Max single-hour difference 4.6 mm.

## Why it matters

- The column is deck-selected and live, so it is in production output.
- "Total precipitation" is one of the most commonly consumed diagnostics in a model like this. A column that silently omits snowfall in a cold-climate deck is wrong in exactly the season the deck is most interesting.
- It corrupts water-balance checks built on output files: an analyst closing a budget from these columns would find precipitation short by the winter snowfall and long by any irrigation.
- It also interacts with `issue-087` (snowpack retained ~47 days too long). Snowfall is the snowpack's only input, and it is missing from the one output column that would let anyone audit it. Anyone diagnosing `issue-087` from output files alone would be unable to see the pack's forcing.

## `SOL_RADN` is a separate, weaker observation, recorded but not claimed

`SOL_RADN` exceeds the triage rule in 54 of 3,252 hours with a max of 38.5 W m-2, against zero exceedances for wind, air temperature and humidity. First exceedance is hour 464 with oracle `1.350` against candidate `1.587` W m-2 -- small absolute values, consistent with near-sunrise/sunset hours where a small difference in solar geometry or in the partition of incoming radiation produces a large relative difference on a tiny number. Legacy is `RAD(NY,NX)*277.8` (`outsh.f:250`), i.e. MJ m-2 h-1 -> W m-2.

**Not filed as a defect.** 54 of 3,252 hours with small absolute magnitudes is not enough evidence, and it may be an entirely legitimate difference in how the two derive shortwave at low sun angles. It is recorded here so that the next pass does not have to rediscover the number, and because it is a *forcing* column and therefore deserves eventual explanation. Do not quote it as a finding without checking whether the exceedances cluster at low sun angle.

## Recommended fix, not applied

Decide the intended semantics and make the name and the value agree, then pin it with a regression test citing `outsh.f:254-255`:

- **For oracle comparability** (the stated release criterion), slot 5 should be rain + snowfall, excluding irrigation, exactly matching `PRECR+PRECW`, and be named `precipitation`.
- If ecosys-ng prefers to publish rain + irrigation, that is a defensible different diagnostic, but it then needs its **own** slot and a feature-register entry, and slot 5 still has to carry the legacy quantity.

Not applied in this pass: it changes a production output column's contents, which invalidates comparison evidence for that column, and it should land together with `issue-086`'s slot-4 fix as one scoped output-semantics change with tests, rather than being appended to a comparison pass.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/outsh.f --lines 250-256
uv run ecosys-audit/scripts/f77query.py grep PRECW
uv run ecosys-audit/scripts/outcompare.py \
  --oracle <oracle>/01998f25eh1 \
  --candidate <deck>/runottawa_output_files/modelled_outputs/heat_energy/*soil_or_eco*f25eh1.txt \
  --stream heat_hourly
```

Oracle provenance and its limitations: `issue-084`. Full per-column statistics: `run-014` and `audit/manifest/outcompare-heat-hourly-2026-09-21.json`.
