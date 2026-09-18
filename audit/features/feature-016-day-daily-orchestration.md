# Feature ID: FEAT-016-DAY-DAILY-ORCHESTRATION

Status: PARTIALLY_ASSESSED (source-audit; `day.f` is 424 lines, full-file read, ~75-80% traced to a specific live Zig site, remainder unverified not flagged as gaps)

## Scope and provenance

Legacy source: `f77src/day.f` (sha256 `B24D33C817D694B4809D59D62617D39F9FC80E59CE9989EF88C15DE3A965548A`), once-per-simulated-day reinitialization/orchestration driver, called before the hourly loop. Computes: output-filename date string; daily min/max weather-accumulator reset; year-boundary annual flux/harvest rollover; solar daylength; hourly-disaggregation parameters; climate-change modifiers; tillage soil-mixing fraction `XCORP`; automatic-irrigation trigger and 24-hour depth schedule.

### 1. Solar daylength geometry -- `preserved`

`day.f:206-219` (`DECLIN`/`AZI`/`DEC`/`DYLN`, `TWILGT=0.06976`). Zig: `ecosys-ng/src/atmosphere/solar_daylength.zig` (sha256 `7C4E54F5BCA847236F4E903712218D54BB789F39C531AF54333F190E66A09740`), `hours`/`update` (`:24-119`), self-documented "Pure `day.f:207--218` daylength geometry." All constants match exactly (`0.06976`, `1.7453e-2`, `0.9863`, `-23.47`), including polar-day/night branches and the `I==366->XI=365.5` leap substitution.

### 2. Hourly radiation-scaling parameter `RMAX` -- `preserved`

`day.f:248-257` (`RMAX=SRAD/(DYLN*0.658)`). Zig: `daily_weather_disaggregation.zig:143-158`, citing `day.f:251` directly, `0.658` constant matches.

### 3. Annual C/N/P + harvest rollover -- `preserved` (already-corrected cadence defect)

`day.f:84-197`. **Standing-lesson check applied**: `plant/accounting/annual_flux_rollover.zig` is explicitly self-labeled a superseded, unbound oracle, narrating a documented defect `PLANT-CADENCE-001` (running the carry every day instead of year-end) as "fixed." Traced the actual live call site rather than trusting the comment: production owner is `ecosys-ng/src/plant/accounting/daily_flux.zig` (sha256 `C4031DC54A67400D4E5A2754DBD3EBDCC4AE8D633C125485B49653D722680951`), `State.closeYearAfterOutput`/`closeYearHarvestSaltAfterOutput` (`:422,689`), invoked from `ecosys_ng.zig:2761-2763` gated on `completed_day_of_year == daysInYear(...)` -- runs once per year, matching the Fortran's intent. Regression coverage verifies single-invocation-per-year (`daily_flux.zig:775,813-819`).

### 4. Seasonal climate-change modifiers -- `preserved`

`day.f:292-322` (`N=1,12` loop, step/incremental modes). Zig: `climate_change.zig` (sha256 `D1FBFC7B50ACFDA09E6EC34C8EE62EA066DE219A95EC5E079CDEDC3C91C5B80A`), `advanceDay`/`fromTarget` (`:31-48,137-151`), matches term-for-term including the `exp(log(x)/LYRC)` CO2 geometric-increment form.

**Apparent gap, verified false**: `options.seasonal_weather_changes` is a 4-entry array, not 12 -- looked like dropped resolution against `day.f`'s 12-slot loop. Traced the legacy INPUT side (`reads.f:83-124`): the option file only ever reads 4 seasonal records (`DO 25 N=1,4`, "Dec-Feb/Mar-May/Jun-Aug/Sep-Nov"), and slots 5-12 are filled by a cascading copy explicitly commented `"OPTION FOR ANNUAL CHANGES IN MONTHLY WEATHER NOT USED"` -- legacy's own 12-slot loop only ever carries 4 real values. Zig's `seasonIndex` (day cutoffs 59/151/243/334) reproduces the same quartering. **Not a translation omission -- matches legacy's actually-used behavior.**

### 5. Tillage soil-mixing fraction `XCORP` -- `preserved`

`day.f:328-360`. Zig: `ecosys-ng/src/management/disturbance_schedule.zig` (sha256 `2D4FDB49719D70B3FE24466B86A39900D0A6A7DEF9A94BA9AD1D641E820F7FC6`, `:73-79`), formula matches; the Fortran's outer `AMIN1(1.0,...)` clamp is omitted but mathematically redundant given the documented `ITILL` domain (ratio always <=1) -- not a functional divergence.

### 6. Automatic irrigation trigger and hourly depth -- `preserved`

`day.f:385-420`. Zig: `ecosys-ng/src/management/irrigation_management_dispatch.zig` (sha256 `98DA15A19A645EBBB52B13FBE9A250BE88E6BEDC81E086A69F88DCF36C7D9072`), `planAutomatedDay` (`:61-135`), explicit citation, term-for-term match including the dual trigger union and even-hour-window division. Tests exercise both triggered and leap-day-skip cases.

## Not covered this pass (unverified, NOT flagged as gaps)

`CDATE` output-filename date-string formatter (`day.f:44-61`) and daily weather min/max accumulator reset (`TRAD,TAMX,TAMN,HUDX,HUDN,TWIND,TRAI,TSMX,TSMN`, `:66-78`) -- no clear Zig counterpart located this pass (output-formatting/reporting-only bookkeeping not exhaustively searched).

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file read, ~75-80% depth-traced). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Six items `preserved` (one an already-corrected cadence defect with a recorded tag). **No open gaps found in this file.**
