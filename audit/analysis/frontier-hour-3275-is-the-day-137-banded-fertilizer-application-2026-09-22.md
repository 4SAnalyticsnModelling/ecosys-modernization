# The frontier hour is the day-137 banded fertilizer application, and the run has exercised no plant growth at all, 2026-09-22

**Source: the `n100b` run's own `combined.log` (the `issue-100` probe run, ReleaseSafe, reached hour 3,275 and terminated on `HourlyCellConservationFailure`).** Everything below is read out of that log or out of the deck files it consumed. Nothing here is a new experiment.

## 1. The calendar: the frontier sits exactly on one management event

The legacy deck's fertilizer schedule, `f77example/Cool Temperate Maize-Soybean ON/f25fr98`, has **three** lines, not one:

| line | date | day of year | notable fields |
|---|---|---|---|
| `:3` | `15041998` | **105** | field 12 = `360.0` (the lime application) |
| `:1` | `16051998` | **136** | field 4 = `13.8` |
| `:2` | `17051998` | **137** | field 5 = `1.65`, field 10 = `5.0`, fields 20-21 = `0.05`, `0.76` |

Line `:2` is the one both `issue-099` and `issue-100` are about: `1.65` is `Z4B` banded NH4 (`hour1.f:231`), `5.0` is the phosphate, and `0.05`/`0.76` are the band depth and row spacing that give this deck's band fraction.

Under the run's own `(day - 1) * 24 + hour` convention the census's recorded application hours land exactly on the first two lines:

```
fertilizer_application entries=2 first_hour=2508 last_hour=3252
  hour 2508 = (105-1)*24 + 12  -> day 105 hour 12   (the lime)
  hour 3252 = (136-1)*24 + 12  -> day 136 hour 12   (the 13.8 line)
```

and the failing hour is on the third:

```
  hour 3275 = (137-1)*24 + 11  -> day 137 hour 11
```

So **the frontier is the day-137 banded NH4 + phosphate application**, and the run has never survived it. That single management event is what `issue-099` (phosphorus, a 100% loss of the 5.0 g P, now fixed) and `issue-100` (nitrogen, a fixed 0.0676655386 g loss per affected cell, open) both sit on.

### One unresolved hour, stated rather than smoothed over

The two recorded applications both fire at **hour 12** of their day. On that pattern the day-137 application should fire at hour **3,276**, not 3,275. But `issue-099`'s own instrumentation observed `fert_preflight: hour=3275 cell=0 phosphorus_g_p=5e0` -- the 5.0 g phosphate of line `:2` -- at hour **3,275** exactly, and the phosphorus residual at hour 3,275 equalled its `external_inputs` of `5.0004` to fifteen digits. Those two cannot both be right about the hour.

Also unexplained: `entries=2` when the deck has three lines. Either the day-137 event does not reach the census instrument because the run dies inside that hour, or the census counter and the failure log's hour counter differ by one (the driver publishes `executed_weather_hours.* + 1` as the hour in some diagnostics and the raw counter in others).

**This is a one-hour bookkeeping discrepancy between two diagnostics, not a science claim, and it is not resolved here.** It does not affect the identification of the event, which is corroborated three independent ways: the date arithmetic, the 5.0 g P magnitude, and the band geometry.

### A claim in `issue-100` that this corrects

`issue-100` states "the failing hour is the banded NH4 application hour, in the application layer." **The day and the event are right; "the application hour" is not established** -- the census puts the last *recorded* application at hour 3,252, twenty-three hours earlier, and the hour-3,275 fertilizer preflight comes from a different run's probe. The correct statement is that hour 3,275 falls on day 137, the banded application's date.

## 2. The stage execution census: 12 of 19 instrumented stages never ran

Quoted verbatim, including the census's own liveness statement:

```
stage execution census: 12 of 19 INSTRUMENTED stages never executed across 3276 simulated hour(s); 1 of 20 stages not yet instrumented
  census is LIVE (positive control fired), so every zero below is a real finding about the model, not a dead instrument.
  never executed (instrumented, ran zero times -- this is the finding):
    plant_pre_emergence
    plant_emergence_occurred
    canopy_photosynthesis_occurred
    root_water_uptake
    symbiotic_nitrogen_fixation
    second_plant_species
    harvest_reproductive_organs
    harvest_branch_stalk_and_reserve
    tillage_aboveground_application
    day_of_year_reset
    scene_transition
    forcing_repeat_transition
  executed:
    plant_emergence_refresh        entries=3275 first_hour=1 last_hour=3275
    canopy_carboxylation           entries=3275 first_hour=1 last_hour=3275
    canopy_energy_balance          entries=3275 first_hour=1 last_hour=3275
    nonsymbiotic_nitrogen_fixation entries=3275 first_hour=1 last_hour=3275
    tillage_soil_application       entries=2    first_hour=2532 last_hour=3252
    fertilizer_application         entries=2    first_hour=2508 last_hour=3252
    census_positive_control        entries=3275 first_hour=1 last_hour=3275
  NOT YET INSTRUMENTED (execution unknown -- absence of a record here is NOT evidence):
    root_uptake_geometry
```

### Most of those zeros are the calendar, not a defect

The census's own banner says every zero "is a real finding about the model." That is true of the instrument but must not be read as twelve defects. **Maize is planted on day 137 and the run stops on day 137 at hour 11.** At that instant there is no emerged crop, the growing season has not started, and the year has not rolled over. On that basis these zeros are *expected*:

- `plant_emergence_occurred`, `canopy_photosynthesis_occurred`, `root_water_uptake` -- pre-emergence.
- `plant_pre_emergence` -- no crop exists before the day-137 planting.
- `symbiotic_nitrogen_fixation` -- 1998 is the maize year of a maize-soybean rotation; `nonsymbiotic_nitrogen_fixation` did run, every hour.
- `harvest_reproductive_organs`, `harvest_branch_stalk_and_reserve` -- autumn.
- `day_of_year_reset`, `scene_transition`, `forcing_repeat_transition` -- all year-boundary transitions; the run covers 136 days of one year.
- `second_plant_species` -- the runscript header declares five plant species, and only one is active this early.

`tillage_aboveground_application` is not calendar-explained here and was not checked against `f25til98`; `tillage_soil_application` did fire twice.

**`day_of_year_reset` is the one I cannot classify.** If it is an annual rollover, never firing across 136 days is correct. If it is a *daily* reset, it should have fired ~136 times and never firing is a defect. The name is ambiguous and I did not read the stage. **Unresolved.**

### The genuine tension in the executed column

Four stages fired on **all 3,275 hours** while their corresponding event never occurred:

| fired every hour | never fired |
|---|---|
| `plant_emergence_refresh` (3,275) | `plant_emergence_occurred` (0) |
| `canopy_carboxylation` (3,275) | `canopy_photosynthesis_occurred` (0) |
| `canopy_energy_balance` (3,275) | -- no canopy exists yet |

Carboxylation and a canopy energy balance running 3,275 consecutive times with no emerged plant needs an explanation. **The most likely one is instrument placement, not science**: this session already found `hourly_heat_water_solute.zig:6948` gating a trace on `executed_weather_hours.* < 8` and then firing unconditionally inside that window, which I initially misread as solver distress. A stage marker placed at the top of a function that always runs will report 3,275 entries whether or not the modelled process did anything. **Not verified either way.**

## 3. What this actually means for the four release criteria

This is the part that matters, and it is a statement about the *scope of the evidence*, not a new defect.

- **Criterion 1 (outputs legacy-Fortran comparable): unverifiable for all plant processes.** A run that stops pre-emergence on day 137 of year 1 of 30 produces no grain yield, no LAI trajectory, no canopy flux, no harvest. There is nothing to compare for any of it.
- **Criterion 2 (no science gap): unverifiable for all plant processes, for the same reason.** The soil-side coverage in the `audit/features/` dossiers is real source-audit coverage; it is not runtime evidence.
- **Criterion 3 (significantly more performant): the measured ratio is for soil-only physics.** The 1.72-2.37x *slower* figure from `run-021` was measured over hours in which no plant growth, photosynthesis or root uptake executed in **either** model. That does not make the figure wrong, and it does not make it better than reported -- it makes it **unrepresentative of the full 262,920-hour horizon**, where plant processes are a large share of the work. Any release claim about performance has to say which regime it was measured in.
- **Criterion 4 (repo sync): unaffected.**

The frontier is 3,275 of 262,920 hours, **1.25%**, and all of it is pre-emergence.

## Limitations

Single run, no repeat; every figure is quoted from that run's log or the deck, and the only arithmetic I performed is the day/hour conversion shown above. The classification of which zeros are "calendar-explained" is **my reasoning from the planting date, not a traced execution condition** -- I did not read the gating condition of any of the twelve stages, so each classification is a hypothesis with a stated basis, and `day_of_year_reset` and `tillage_aboveground_application` are explicitly unclassified. The "instrument placement" explanation for the four every-hour stages is likewise unverified. The one-hour discrepancy between the census's `last_hour=3252` and the observed hour-3,275 fertilizer preflight is unresolved. `check_gate.py` owns gate status and nothing here changes it.
