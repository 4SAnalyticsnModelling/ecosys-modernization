# Issue 092 -- daily output flux columns are ANNUAL CUMULATIVE totals in the oracle and PER-DAY values in ecosys-ng

Status: **OPEN, CONFIRMED, systematic across the daily output streams (filed 2026-09-22, adversarial Claude/Pi session).** Not a single-column mistake: every daily column fed by a legacy `U*` annual accumulator reports a different quantity in ecosys-ng. Directly against the "outputs comparable to the legacy oracle" release criterion, and it is invisible to a spot check of day 1 because the two agree there by construction.

Found using the outputs already on disk, with no production run -- which matters because `issue-091` currently blocks all runs.

## The finding

Daily water stream (`f25wd1`), slot 1 (`PRECN` / `rainfall`), same cell, same simulated days:

| day of year | oracle `PRECN` (mm) | ecosys-ng `rainfall` (mm) |
|---|---|---|
| 1 | 6.600 | 6.673 |
| 2 | 6.600 | 0.040 |
| 3 | 6.600 | 0.064 |
| 5 | 27.20 | 20.637 |
| 10 | 91.40 | 0.050 |
| 20 | 106.10 | 0.049 |
| 40 | 135.00 | 0.019 |
| 60 | 164.60 | 5.337 |
| 90 | 280.00 | 12.164 |
| 120 | 335.30 | 0.815 |

The oracle column is **monotonically non-decreasing**. ecosys-ng's fluctuates with the weather. They are not the same quantity: one is a running total, the other a daily increment.

Note day 1 agrees to ~1% (6.600 against 6.673). **A comparison that sampled only the first day would pass this column and conclude the stream was fine.** That is the trap worth recording.

## Why, from the source

`f77src/day.f:80` states it in its own comment, and the gate is explicit:

```fortran
C     RESET ANNUAL FLUX ACCUMULATORS AT START OF ANNUAL CYCLE
      IF((ALAT(NY,NX).GE.0.0.AND.I.EQ.1)
     2.OR.(ALAT(NY,NX).LT.0.0.AND.I.EQ.1))THEN
      ...
      URAIN(NY,NX)=0.0        ! :100
      UEVAP(NY,NX)=0.0        ! :101
      URUN(NY,NX)=0.0         ! :102
      USEDOU(NY,NX)=0.0       ! :103
      UVOLO(NY,NX)=0.0        ! :104
```

`I.EQ.1` is the first day of the year, so these are **annual** accumulators. `redist.f:4407` (`URAIN=URAIN+WI`) adds to them through the year, and `outsd.f:114-118` writes them straight out:

```fortran
K=1  1000.0*URAIN(NY,NX)/AREA(...)     ! PRECN
K=2  1000.0*UEVAP(NY,NX)/AREA(...)     ! ET
K=3  1000.0*URUN(NY,NX)/TAREA          ! RUNOFF
K=5  1000.0*UVOLO(NY,NX)/TAREA         ! DISCHG
```

## The distinction that makes this precise: storage columns are FINE

Not every daily column is affected, and conflating them would overstate the defect. Slot 4 is the counter-example:

```fortran
K=4  1000.0*UVOLW(NY,NX)/AREA(...)     ! WATER
```

`UVOLW` is **not** in the annual reset block. It is zeroed **hourly** at `hour1.f:2412` and re-accumulated over the layers each hour (`redist.f:5475`, `:5635`, `:6682`), so it is a **storage snapshot**, not a running total. ecosys-ng's `soil_water_storage[mm]` is therefore the right quantity for that slot, and the daily stream binds it correctly -- which independently corroborates `issue-086`'s finding that only the **hourly** slot 4 is misbound.

So the rule is: **legacy daily columns fed by an annually-reset `U*` accumulator are cumulative; columns fed by an hourly-reset accumulator are snapshots.** The defect is confined to the former.

## Scope

Confirmed affected in the daily water stream: `PRECN`, `ET`, `RUNOFF`, `DISCHG`. By the same mechanism, `TILE_DRG` and `SEDIMENT` (`USEDOU`) are near-certainly affected, and the `U*` accumulators zeroed alongside them at `day.f:89-106` -- `UORGF`, `UXCSN`, `UCOP`, `UDOCQ`, `UDOCD`, `UDICQ`, `UDICD`, `UVOLY`, `UIONOU`, plus `ZCNET`/`ZHNET`/`ZONET` and `TNBP` -- feed the daily **carbon, nitrogen and phosphorus** streams, so the same defect very likely runs through all of them.

**Not verified here**: the per-column mapping for the daily carbon/nitrogen/phosphorus/energy streams. Only the daily water stream was compared. Do not assume the count without checking each.

Otherwise the daily water stream maps cleanly: 50 oracle data columns against 48 in ecosys-ng, differing only by `WTR_13` and `ICE_13` (layers beyond the 12-layer runtime profile, the `issue-085` class). Units verified from `outsd.f:114-125` -- `1000*U*/AREA` gives mm, `THETWZ(k)` is dimensionless, and `SNOWPACK` here is `1000*DPTHS`, snow **depth** in mm rather than the water equivalent the hourly stream's `SNOWPACK` reports. Same header name, different quantity between cadences; worth not conflating.

## Recommended disposition, not applied

This needs a decision rather than a reflex fix, and the decision belongs to a reviewer:

1. **Emit cumulative** for the affected daily columns, matching the oracle exactly and making the stream comparable. Cheapest route to criterion 1 and what "outputs comparable" plainly asks for.
2. **Keep per-day and record it as an approved intentional difference**, on the grounds that a per-day flux is the more useful diagnostic. That is defensible, but then the columns must be **renamed** so nobody reads them as the legacy quantity, and the comparison harness must exclude them with a citation rather than reporting a spurious divergence.

What must not happen is the current state: same slot, same name, silently different accumulation window. Whichever is chosen, a regression test should pin the accumulation window against `day.f:84`'s `I.EQ.1` reset.

`outcompare.py` has deliberately **not** been extended to the daily streams yet, because doing so before this is decided would bake in a wrong comparison.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/day.f   --lines 64-106
uv run ecosys-audit/scripts/f77query.py show f77src/outsd.f --lines 112-125
uv run ecosys-audit/scripts/f77query.py grep URAIN
```

Then compare column 1 of the oracle's `01998f25wd1` against `rainfall[mm]` in ecosys-ng's `*_f25wd1.txt` across several days, not just day 1.
