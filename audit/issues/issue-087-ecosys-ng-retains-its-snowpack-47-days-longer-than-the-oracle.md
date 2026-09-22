# Issue 087 -- ecosys-ng retains its snowpack ~47 days longer than the oracle; spring snowmelt does not complete

Status: **OPEN, CONFIRMED against the legacy oracle, cause not yet diagnosed (filed 2026-09-21, adversarial Claude/Pi session).** This is a genuine physical-state divergence, not an output defect: the output expression was verified term-for-term faithful before the divergence was attributed to the model. It is the largest single unexplained divergence found in `run-014`'s first oracle comparison, and it plausibly sits upstream of several separately-tracked surface divergences.

## The finding

Ottawa production deck, simulated year 1998, hourly water stream slot 6 (`SNOWPACK`, snowpack water equivalent in mm). Oracle and candidate over the 3,252 hours both cover:

| cumulative hour | ~date | oracle (mm) | ecosys-ng (mm) |
|---|---|---|---|
| 1 | 1 Jan | 0.000 | 0.800 |
| 500 | 21 Jan | 100.469 | 101.724 |
| 1000 | 11 Feb | 129.377 | 125.202 |
| 1500 | 3 Mar | 101.850 | 110.233 |
| 1800 | 16 Mar | 95.311 | 107.193 |
| 2000 | 24 Mar | 123.508 | 133.521 |
| 2100 | 28 Mar | 37.242 | 120.596 |
| 2200 | 1 Apr | **0.000** | 96.296 |
| 2300 | 5 Apr | 0.000 | 84.153 |
| 2400 | 9 Apr | 0.000 | 68.383 |
| 2500 | 14 Apr | 0.000 | 44.951 |
| 2600 | 18 Apr | 0.000 | 17.545 |
| 3000 | 5 May | 0.000 | 5.003 |

**Last hour with more than 0.1 mm of snow water equivalent: oracle 2,132 (~30 March); ecosys-ng 3,251 (~16 May).** A difference of 1,119 hours, about 47 days. ecosys-ng still has snow at the run's frontier.

Whole-series statistics from `run-014`: mean absolute error 16.78 mm, bias **+14.23 mm** (candidate higher), max absolute error 111.61 mm, and the triage rule is exceeded in all 3,252 hours.

## Through winter the two agree; the divergence is in the MELT

This is the part that makes the finding tractable. From hour ~500 to ~2000 the two snowpacks track each other to within roughly 10% and share the same accumulation events and the same order of magnitude -- 100.5 vs 101.7, 129.4 vs 125.2, 101.9 vs 110.2, 95.3 vs 107.2, 123.5 vs 133.5. Accumulation is therefore broadly right, and the snow model is not wrong in some gross, always-on way.

The two series separate abruptly during the **late-March melt**: between hours 2,000 and 2,200 the oracle sheds its entire ~123 mm pack, while the candidate sheds only ~37 mm over the same window and then declines slowly for another six weeks. So the defect is in **ablation** -- melt energy, its partition, or the discharge of meltwater -- and not in snowfall, interception or densification.

## The output binding is faithful, checked before blaming the model

Verified term-for-term, so the divergence is in the state and not in how it is reported:

```
legacy    outsh.f:123-124
          AMAX1(0.0,(VOLSS(NY,NX)+VOLIS(NY,NX)*DENSI+VOLWS(NY,NX))
                *1000.0/AREA(3,NU(NY,NX),NY,NX))

ecosys-ng soil/water/output.zig:138
          @max(0.0, (inputs.surface_snow_volume_m3
                     + inputs.surface_ice_volume_m3 * inputs.ice_density_megagrams_per_m3
                     + inputs.surface_liquid_water_m3)
                * 1000.0 / inputs.local_surface_area_m2)
```

Same three terms, the same single density scaling applied to the ice term only, the same `*1000/area`, the same clamp at zero. Units agree (mm both sides). This matters because the neighbouring slot 4 in the very same group *is* a wrong binding (`issue-086`) -- so the check was necessary rather than a formality.

## Why this may be upstream of other tracked divergences

A snowpack that persists ~47 days too long into spring keeps the surface insulated, cold and wet, and suppresses surface exchange over exactly the period where `run-014` measures the rest of its surface divergence:

- `WTR_1` bias **+0.2585 m3 m-3**, candidate systematically wetter at the surface, decaying with depth (`run-014`).
- `ICE_1` the worst-agreeing ice layer (1,585 exceedances) while `ICE_8`-`ICE_12` agree to machine precision.
- Suppressed soil CO2 and O2 fluxes in the candidate.

This is a **hypothesis about direction, not a proven cause**, and it must not be recorded as one. The surface water and ice divergences are already present well before the melt window, so a persistent snowpack cannot be their sole cause. What is defensible: the two phenomena are in the same place at the same time, and a 47-day snow-persistence error is large enough that it cannot be a downstream symptom of a small surface-layer discrepancy -- the causal arrow more likely runs the other way, or both share a cause.

## Relationship to issue-024

`issue-024` round 11 established that the legacy **top soil layer** takes a snow-free freeze-thaw path with an explicit kinetic ceiling (`watsub.f:2802-2823`, `XNPR=1/30`, freezing capped at `XNPSRX=1/(NPH*200)`), which ecosys-ng ports for the **litter** layer only, and that ecosys-ng's coupled solve commits the *unconstrained equilibrium* phase partition (quantified there as a 29.35x overshoot in a matched-state kernel test; the litter analogue `EXEC-002` records 19.17x).

That is a **freezing**-side finding, and this issue is a **melting**-side one, so they are not the same defect. But they are the same *class*: an energy-to-phase-change conversion at the surface whose rate ecosys-ng and the oracle disagree about. Anyone diagnosing this should read `issue-024` round 11 first, and should check whether the snow phase kernel (`soil/water/snow_phase_change.zig`) has the same unconstrained-equilibrium character that `issue-024` identified in the soil phase kernel.

## Diagnosis budget: 0 of 3 experiments spent

No experiment has been run against this issue. Recommended first three, cheapest first, none needing a production run:

1. **Read-only**: compare the legacy snowpack ablation path against `soil/water/snow_phase_change.zig` and the snow energy stage. Establish whether ecosys-ng applies any rate limit to snowmelt phase conversion and whether the oracle does. `watsub.f`'s snow blocks and `hour1.f`'s snow surface energy are the starting points.
2. **Read-only**: check meltwater *discharge*. The pack could be melting at the right rate while the liquid fails to leave the pack -- `VOLWS` is one of the three summed terms, so a pack that converts snow to retained liquid without discharging it would show as persistent `SNOWPACK` even with correct melt energy. `watsub.f:3683-3685`'s litter terminus (`FLQR`) and its ecosys-ng counterpart are directly relevant, and `issue-083` already established that this terminus has **no in-solver counterpart**.
3. **Matched-state kernel test**, no production run: drive both snow phase kernels from one snowpack state and one energy input and compare the converted mass, in the style of `issue-024` round 11's `enthalpy_balance.zig` test.

Experiment 2 is flagged as the most promising: `issue-083` independently established that the oracle's donor-bounded surface discharge leg has no ecosys-ng counterpart, and a missing discharge path would produce exactly this signature -- correct accumulation, correct winter tracking, and a pack that will not drain in spring.

## Evidence and reproduction

Full per-column statistics and provenance: `audit/runs/run-014-first-legacy-oracle-output-comparison-2026-09-21.md`, machine-readable in `audit/manifest/outcompare-water-hourly-2026-09-21.json`. Oracle artifact and its limitations: `issue-084`.

```
uv run ecosys-audit/scripts/outcompare.py \
  --oracle <oracle>/01998f25wh1 \
  --candidate <deck>/runottawa_output_files/modelled_outputs/water/*soil_or_eco*f25wh1.txt \
  --stream water_hourly
```

Carried limitation, which applies to this issue as much as to `run-014`: the oracle is a derived artifact with reconstructed inputs built with GNU rather than the makefile's Intel target, and neither run is complete. A 47-day melt-out difference is far outside anything a compiler or a reconstructed-input difference plausibly explains, but the caveat travels with the number.
