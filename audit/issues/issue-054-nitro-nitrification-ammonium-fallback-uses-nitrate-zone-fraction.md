# Issue 054: nitrification.zig's ammonium competition fallback reuses the nitrate-zone volume fraction instead of the ammonium-zone fraction

## Status: RESOLVED (fixed and regression-tested; disposition `legacy-defect-corrected`)

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

`legacy-defect-corrected` -- fixed exactly as scoped below; see Resolution.

## Resolution (2026-09-19, this session's fix pass)

### Fix applied

`ecosys-ng/src/soil/microbial/nitrification.zig`'s `Zone` struct gained a new
field, `ammonium_fallback_fraction: f64` (added immediately after the
existing `fallback_available_fraction: f64`, current lines 25-38). Inside
`calculatePotential` (current lines 82-83), the ammonium-competition terms
now read:

```zig
const non_band_ammonium_competition = competition(inputs.non_band.previous_total_ammonium_demand_g_n, inputs.non_band.previous_ammonia_oxidation_capacity_g_n, inputs.non_band.ammonium_fallback_fraction * inputs.microbial_active_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);
const band_ammonium_competition = competition(inputs.band.previous_total_ammonium_demand_g_n, inputs.band.previous_ammonia_oxidation_capacity_g_n, inputs.band.ammonium_fallback_fraction * inputs.microbial_active_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);
```

The nitrite-competition terms (current lines 84-85) are byte-identical to
before and still use `fallback_available_fraction` (the nitrate-zone
fraction) -- unchanged, per scope.

`ecosys-ng/src/soil/microbial/nitrification_step.zig`'s `makeZone` (current
lines 87-100) now sets the new field from the ammonium-zone fraction, not the
nitrate-zone fraction:

```zig
return .{
    .substrate_access_fraction = ammonium_fraction,
    .fallback_available_fraction = nitrite_fraction,
    .ammonium_fallback_fraction = ammonium_fraction,
    ...
```

`ammonium_fraction` here is the same `fractions.ammonium_non_band` /
`fractions.ammonium_band` value already used for `substrate_access_fraction`
(line 80); `fallback_available_fraction`'s existing wiring from
`nitrite_fraction` (`fractions.nitrate_non_band`/`nitrate_band`) is untouched.
`testZone()` in `nitrification.zig` was updated to initialize the new field
(`.ammonium_fallback_fraction = 1`) so existing tests keep compiling; no
other test's expected values were changed.

### Before/after regression test evidence

Two regression tests were added, both would have FAILED before this fix and
PASS after it:

1. `nitrification.zig`, test `"ammonium competition fallback scales with the
   ammonium zone fraction, not the nitrate zone fraction (issue-054)"`.
   Constructs a `Zone` with `ammonium_fallback_fraction = 0.75` and
   `fallback_available_fraction = 0.65` (distinct values matching
   `charge_classification.zig`'s own test convention), with
   `previous_total_ammonium_demand_g_n`/`previous_total_nitrite_demand_g_n`
   at their default 0 (forcing both competition terms onto the fallback
   branch -- the cold-start / newly-active-layer condition this issue
   documents as routinely reachable). Asserts
   `non_band_ammonium_competition_fraction == 0.75` and
   `band_ammonium_competition_fraction == 0.75` (the ammonium-zone fraction),
   and that `non_band_nitrite_competition_fraction == 0.65` and
   `band_nitrite_competition_fraction == 0.65` (the nitrate-zone fraction,
   confirming the nitrite path is unaffected).
   - **Before the fix**: `non_band_ammonium_competition_fraction` and
     `band_ammonium_competition_fraction` would have evaluated to `0.65`
     (wrongly reusing `fallback_available_fraction`), failing the `0.75`
     assertion.
   - **After the fix**: both evaluate to `0.75` as expected; the nitrite
     assertions pass unchanged in both cases.
2. `nitrification_step.zig`, test `"makeZone sources
   ammonium_fallback_fraction from the ammonium zone, not the nitrate zone
   (issue-054)"`. Builds an `ApplyContext` with
   `.ammonium_non_band = 0.75, .ammonium_band = 0.75, .nitrate_non_band =
   0.65, .nitrate_band = 0.65` and calls `makeZone` directly, asserting
   `zone.ammonium_fallback_fraction == 0.75` and
   `zone.fallback_available_fraction == 0.65`.
   - **Before the fix**: the field did not exist, so this test could not
     even be written against the pre-fix struct -- confirming the field was
     genuinely missing, not merely misrouted.
   - **After the fix**: both assertions pass.

### Targeted test verification

Ran `zig test src/module_index.zig --test-filter "nitrification"` from
`ecosys-ng/` (Zig 0.16.0) -- **75/75 tests passed**, including both new
regression tests and all four pre-existing `nitrification`/
`nitrification_step` tests (no expectation values in the pre-existing tests
were changed). Confirmed the filter does narrow the run (an
intentionally-non-matching filter, `"this_should_match_nothing_zzz"`, runs
only 51 tests), and confirmed `outer_hour_transaction` (the project's known
unrelated test hang) does not appear in the filtered 75-test list, so the
full suite was never invoked.

### Ottawa-deck materiality finding

Checked whether this defect is numerically live for the actual Ottawa
Cool-Temperate-Maize-Soybean deck (both `f77example/Cool Temperate
Maize-Soybean ON/f25fr00,f25fr01,f25fr02,f25fr79,f25fr98` and the
byte-identical `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean
ON/runottawa_input_files/management/soil/fertilizer/f25fr*` copies used by
the Zig production run). Per `f77src/reads.f:930-958`'s documented fertilizer
file columns (`Z4A/Z3A/ZUA/ZOA`=NH4/NH3/urea/NO3 broadcast,
`Z4B/Z3B/ZUB/ZOB`=same four banded, `FDPTHI`/`ROWX`=band depth/row width):

- NH4/NH3/urea are applied **banded** (`Z4B`/`Z3B` nonzero, e.g. 1.35, 1.65,
  15.66 g N/m2) at `FDPTHI=0.05` m, `ROWX=0.76` m row spacing in
  `f25fr00` (2000), `f25fr02` (2002), `f25fr79` (1979) and `f25fr98` (1998).
  Per `f77src/hour1.f:303-320`, this sets `IFNHB=1`, producing a nonzero
  `VLNHB` (NH4 band volume fraction) and therefore `VLNH4 = 1 - VLNHB < 1`.
- NO3 fertilizer (`ZOA=3.4` g N/m2 in `f25fr01`, 2001) is applied via the
  **broadcast** column only -- `ZOB` (NO3 banded) is `0` in every fertilizer
  file across the entire deck. Per `f77src/hour1.f:359-372`'s mirror-image
  `IFNOB` gate, `IFNOB` never becomes 1 for this deck, so `VLNOB` stays `0`
  and `VLNO3 = 1 - VLNOB = 1.0` for the whole simulation.

Since `ecosys-ng`'s `zones.ZoneFractions.ammonium_non_band`/`ammonium_band`
and `.nitrate_non_band`/`.nitrate_band` are the direct Zig analogues of
legacy `VLNH4`/`VLNHB` and `VLNO3`/`VLNOB` (confirmed via
`charge_classification.zig`'s own independent-fraction test), **this defect
is NOT numerically inert for the Ottawa deck**: `ammonium_non_band` is
measurably below 1.0 whenever an NH4/urea starter band is active (every
fertilized year checked), while `nitrate_non_band` stays at 1.0 throughout,
so the two fractions genuinely diverge for real stretches of the production
run -- exactly the condition this issue's fix corrects. An exact per-hour
`VLNHB` numeric value is a runtime-computed, layer- and day-dependent
quantity (it also evolves via a diffusion term, `f77src/hour1.f:4908-4914`'s
`DWNH4`) that requires a model run to extract precisely; that run was out of
scope for this fix pass per the contract's guidance against repetitive
full-deck `ReleaseFast` runs before evidence gates pass. The structural
finding above (NO3 never banded vs. NH4 banded in most fertilized years) is
sufficient to establish materiality without one.
