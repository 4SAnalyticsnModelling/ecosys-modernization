# Issue 090 -- fertilizer band geometry is a static runscript constant in ecosys-ng; the oracle derives it per application from the fertilizer file

Status: **OPEN, CONFIRMED SCIENCE GAP, and it is the current production blocker (filed 2026-09-21/22, adversarial Claude/Pi session).** Exposed by `run-018` after the hour-3,253 chain was cleared: the run now fails at **hour 3,276** (day 137, 17 May, hour 12) with `MissingFertilizerRecipientWaterVolume`. This is not a guard-domain artefact -- the guard is correct, and it is refusing to dissolve fertilizer into a recipient with zero water because ecosys-ng never gave the band any volume.

## The failure

```
error: hourly science failed: execution=1 scenario=1 scenario_repeat=1 scene=1
  scene_hour=3276 total_hour=3276 year=1998 day_of_year=137 month=5 day=17 hour=12
  error=MissingFertilizerRecipientWaterVolume
```

Raised by `soil/nutrients/fertilizer_dissolution.zig:387-390`:

```zig
fn requireRecipientVolume(amount_mol_n: f64, volume_m3: f64) !void {
    if (amount_mol_n > 0 and volume_m3 <= 0)
        return error.MissingFertilizerRecipientWaterVolume;
}
```

called at `:316-341` for each band and non-band recipient, where the band recipients are `water_volume_m3 * fractions.ammonium_band` and `water_volume_m3 * fractions.nitrate_band`. **The guard is right**: dissolving a positive amount of fertilizer into zero solvent has no defined concentration. The defect is upstream, in the band fraction being zero.

## The deck really does request a banded application

`ecosys-ng-prod-examples/.../management/soil/fertilizer/f25fr98`, third record:

```
17051998  0 0 0 0 1.65 0 0 0 0 5.0 0 0 0 0 0 0 0 0 0 0.05 0.76 1 0 0
```

Dated **17 May 1998 = day 137**, exactly the failing day, with trailing geometry fields `0.05` and `0.76` -- a 0.05 m band in 0.76 m rows, which is standard maize row spacing. The two earlier records (15 April, 16 May) are the two applications the census already shows as executed (`fertilizer_application entries=2 first_hour=2508 last_hour=3252`); this is the third and it is the first **banded** one.

## Where ecosys-ng gets its band fractions, and why they are zero

Statically, from one runscript record. `driver/runscript.zig:369-377`:

```zig
.initial_ammonium_band_fraction  = ...,
.initial_nitrate_band_fraction   = ...,
.initial_phosphate_band_fraction = ...,
.initial_h2po4_fraction          = ...,
.initial_ammonium_band_row_spacing_m = ...,
...
```

and the deck's record is:

```
plant_nutrients,0,0,0,1,1,1,1
```

so **all three band fractions are 0**. Those values are then used directly as the zone fractions (`ecosys_ng.zig:10318-10323`, `:11057-11060`, `:11196-11199`):

```zig
.ammonium_non_band = 1 - nutrient_zones.initial_ammonium_band_fraction,
.ammonium_band     = nutrient_zones.initial_ammonium_band_fraction,
```

Nothing derives them from a fertilizer application's own band geometry. So `ammonium_band = 0` for the whole run, `ammonium_band_water = water_volume_m3 * 0 = 0`, and the first banded application cannot dissolve.

## What the oracle does instead -- the actual gap

The legacy model computes band geometry **dynamically, per day, from the fertilizer file**, and then grows the band as it diffuses:

- `hour1.f:296` -- the variable's own comment: `ROWN=width of NH4 band row from fertilizer file (m)`.
- `hour1.f:306` -- `ROWN(NY,NX)=ROWI(I,NY,NX)`, set from the fertilizer file's per-day row-spacing input, indexed by day `I`.
- `hour1.f:310` -- `WDNHB(L,NY,NX)=AMIN1(WBNDX,ROWN(NY,NX))`, the band width per layer.
- `hour1.f:316` -- **the band volume fraction itself**: `VLNHB(L,NY,NX)=AMIN1(0.9999,WDNHB(L,NY,NX)/ROWN(NY,NX)...)`, i.e. band width divided by row spacing. For this deck that is `0.05/0.76 = 0.0658`, not zero.
- `hour1.f:4897` -- the banded path is gated `IF(IFNHB(NY,NX).EQ.1.AND.ROWN(NY,NX).GT.0.0)`, so the oracle explicitly expects `ROWN > 0` whenever a band is active.
- `hour1.f:4910` -- `WDNHB(L,NY,NX)=AMIN1(ROWN(NY,NX),WDNHB(L,NY,NX)+DWNH4)`, the band **widens over time** toward the full row spacing as the fertilizer diffuses laterally.
- `reads.f:774` -- `ROWN,ROWO,ROWP=row spacing for band NH4, NO3 and PO4`; `reads.f:788` initializes them to 0, which is why a deck with no banded application legitimately has zero.

So the oracle's band fraction is a **state variable driven by each application's geometry and evolving with diffusion**, while ecosys-ng's is a **constant read once from the runscript**. On a deck that never bands, the two agree trivially (both zero) -- which is why this never fired before hour 3,276, and why `issue-065`'s thirteenth addendum could correctly conclude that "this deck's phosphate band is confirmed never active". It becomes a hard failure the moment the deck bands anything.

## Scope of the gap

Three distinct pieces are missing, in increasing size:

1. **The per-application band fraction** (`hour1.f:306`, `:310`, `:316`): read the band width and row spacing from the fertilizer record and set the zone fractions from `width/row_spacing`. This alone would unblock hour 3,276.
2. **Band widening with diffusion** (`hour1.f:4910`, `DWNH4`): the band is not static once created; it grows toward the row spacing. Omitting it means banded nutrients stay artificially concentrated.
3. **The `IFNHB` activation flag** and its `ROWN > 0` gate (`hour1.f:4897`, `redist.f:9496`), which is how the oracle decides whether the banded path runs at all.

Do **not** "fix" this by setting the deck's `plant_nutrients` band fractions to nonzero constants. That would paper over the gap with a hand-tuned input, would be wrong for any other deck, and would still omit items 2 and 3. The deck's `f25fr98` already carries the correct geometry; the model should read it.

Also do not relax `requireRecipientVolume`. It is correct and it is the only reason this surfaced as a clean error rather than as a division by zero or a silently wrong concentration.

## Relationship to other records

- `run-018` -- the run that exposed this, after `issue-089`'s fix cleared hour 3,253. Frontier 3,252 -> 3,275 accepted.
- `issue-065` (thirteenth addendum) -- correctly established that this deck's phosphate band was never active *up to hour 2,894*. That finding is not contradicted; the deck simply bands later, on 17 May.
- `issue-085`/`issue-086`/`issue-088` -- the output-semantics findings from `run-014`. Unrelated, but note that a band fraction stuck at zero would also make any banded-zone output column identically zero, so this gap is invisible in output comparison.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/hour1.f --lines 296-320
uv run ecosys-audit/scripts/f77query.py grep ROWN
Get-Content "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa_input_files/management/soil/fertilizer/f25fr98"
Select-String -Path "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa" -Pattern plant_nutrients
```
