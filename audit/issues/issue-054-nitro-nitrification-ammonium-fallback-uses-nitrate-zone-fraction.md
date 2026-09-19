# Issue 054: nitrification.zig's ammonium competition fallback reuses the nitrate-zone volume fraction instead of the ammonium-zone fraction

## Status: OPEN (unresolved -- needs reviewer judgment on numerical impact, not yet fixed)

## Impact / severity

Low-to-moderate, narrow, cold-start-and-thereafter-conditional. Affects the
non-band/band split of the *fallback* competition fraction used by NH3
oxidizers (ammonia oxidation) whenever a layer's aggregate previous-hour NH4
demand is negligible (first simulated hour for every layer; any layer that
just became active, e.g. via thaw, water-table rise, or new litter addition).
Does not affect any hour where warm per-population demand history already
exists (the dominant, non-fallback branch of the same formula), and is
completely inert when the deck's NH4 and NO3 band/non-band volume fractions
happen to coincide (e.g. no band fertilizer applied, or a deck without
independently-banded NH4 vs NO3 placements).

## First bad location

`f77src/nitro.f:1088-1097` (NH3-oxidizer NH4 competition, `N=1` branch) versus
`f77src/nitro.f:1209-1218` (NO2-oxidizer's own NO2 competition, `N=2` branch),
compared against `ecosys-ng/src/soil/microbial/nitrification_step.zig`'s
`makeZone` (lines ~78-100) and `ecosys-ng/src/soil/microbial/nitrification.zig`'s
`calculatePotential` (lines 81-84).

## Reference (legacy) behavior

Two *different* source fractions are used as the fallback (`RNH4Y<=ZEROS` /
`RNO2Y<=ZEROS`) competition weight for two different populations:

```fortran
C     NH3 OXIDIZERS' OWN NH4 fallback (nitro.f:1088-1091)
IF(RNH4Y(L,NY,NX).GT.ZEROS(NY,NX))THEN
FNH4=AMAX1(FMN,RVMX4(N,K,L,NY,NX)/RNH4Y(L,NY,NX))
ELSE
FNH4=AMAX1(FMN,FNH4S(L,NY,NX)*FOMA(N,K))
ENDIF
```

```fortran
C     NO2 OXIDIZERS' OWN NO2 fallback (nitro.f:1209-1212)
IF(RNO2Y(L,NY,NX).GT.ZEROS(NY,NX))THEN
FNO2=AMAX1(FMN,RVMX2(N,K,L,NY,NX)/RNO2Y(L,NY,NX))
ELSE
FNO2=AMAX1(FMN,FOMN(N,K)*FNO3S(L,NY,NX))
ENDIF
```

`FNH4S(L,NY,NX)` (fraction of soil volume in the NH4 non-band zone) and
`FNO3S(L,NY,NX)` (fraction of soil volume in the NO3 non-band zone, to which
`FNO2S` is aliased at `nitro.f:338`) are independently-set band-geometry
fractions -- they are not the same value in a deck with independently placed
NH4 and NO3 fertilizer bands. The NH3-oxidizer's own NH4 fallback must use
`FNH4S`; the NO2-oxidizer's own NO2 fallback must use `FNO3S`
(`=FNO2S`). These are genuinely two different legacy fractions for two
different roles, confirmed by direct re-read (not inferred from a comment).

## Current Zig behavior

`nitrification_step.zig`'s `makeZone(context, layer, unit, water_m3, band)`
builds one `reaction.Zone` per band/non-band call, shared by *both* the
ammonia-oxidation and nitrite-oxidation math inside the single
`calculatePotential` call:

```zig
const ammonium_fraction = if (band) fractions.ammonium_band else fractions.ammonium_non_band;
const nitrite_fraction = if (band) fractions.nitrate_band else fractions.nitrate_non_band;
...
return .{
    .substrate_access_fraction = ammonium_fraction,
    .fallback_available_fraction = nitrite_fraction,   // <- always the nitrate-zone fraction
    ...
};
```

`nitrification.zig`'s `calculatePotential` then uses `fallback_available_fraction`
for *both* competition fallbacks:

```zig
const non_band_ammonium_competition = competition(..., inputs.non_band.fallback_available_fraction * inputs.microbial_active_fraction, ...);
const non_band_nitrite_competition  = competition(..., inputs.microbial_active_fraction * inputs.non_band.fallback_available_fraction, ...);
```

The nitrite-oxidizer's own fallback is correct (matches `FOMN(N,K)*FNO3S(L)`,
since `nitrite_fraction` is sourced from `fractions.nitrate_non_band/band`).
The ammonia-oxidizer's own fallback is wrong: it is multiplied by
`nitrite_fraction` (the NO3/NO2-zone fraction) instead of `ammonium_fraction`
(the NH4-zone fraction, `FNH4S`-equivalent), which is available in the same
`Zone` struct as `substrate_access_fraction` but not plumbed into the
fallback competition term.

Confirmed the two fields are genuinely independent at runtime, not aliases:
`ecosys-ng/src/soil/solute/charge_classification.zig`'s own test uses
`.ammonium_non_band = 0.75, ..., .nitrate_non_band = 0.65` -- distinct values
by construction.

## Reachability

`inputs.non_band.previous_total_ammonium_demand_g_n` /
`previous_total_band_ammonium_demand_g_n` (the `RNH4Y`/`RNHBY` analogue) are
initialized to zero and are only nonzero once a prior hour has recorded
aggregate demand for that layer (`ecosys-ng/src/soil/nutrients/reactive_nitrogen_state.zig`,
updated via `ecosys-ng/src/soil/nutrients/competition_history.zig`). This
means the fallback branch is taken at minimum on hour 1 of every run, for
every layer, and again whenever a layer's aggregate ammonium demand history
resets (new litter layer, newly thawed/rewetted layer, etc.) -- a real,
routinely-reachable condition, not a purely theoretical one.

## Why this is not yet fixed / needs a reviewer

Numerical impact depends entirely on how different `ammonium_non_band` and
`nitrate_non_band` (and their band counterparts) are in the actual production
deck(s) in scope, which was not measured this pass (this was a read-only,
static-analysis-only pass per the assignment; no build/run was performed).
If the Ottawa deck's fertilizer bands do not independently separate NH4 vs
NO3 placement, this defect may be numerically inert for that specific deck
while still being a latent translation defect for any deck that does. Per
contract, this needs the numerical-impact account (before/after) that a fix
requires, which is out of scope for a static pass.

## Suggested fix (not applied)

Give `reaction.Zone` a separate `ammonium_fallback_fraction` field (set from
`ammonium_fraction`, i.e. `fractions.ammonium_non_band`/`ammonium_band`) and
use it in `non_band_ammonium_competition`/`band_ammonium_competition` in
place of `fallback_available_fraction`, leaving the nitrite competition's use
of `fallback_available_fraction` (nitrate-zone) unchanged.

## Disposition

`unresolved` -- confirmed defect in the fallback-only branch, reachable at
minimum on cold start for every layer; magnitude and production impact not
yet quantified. Needs reviewer judgment and, if confirmed materially
impactful, a fix with a regression test and numerical-impact account per
contract's "what closes an issue."
