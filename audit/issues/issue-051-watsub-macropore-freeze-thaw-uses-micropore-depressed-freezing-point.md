# Issue 051: macropore freeze-thaw eligibility gate uses pure-water 273.15 K but its own driving-force formula relaxes toward the micropore's matric-depressed `TFREEZ` -- faithfully reproduced in Zig, undocumented either side

## Impact/severity

Medium -- a genuine legacy internal inconsistency (the macropore block's own
gate and its own formula disagree on the target temperature), independently
confirmed to be **bit-for-bit reproduced** in the current Zig production
code path, with no citing comment, no dedicated test of this specific
asymmetry, and no feature-register/issue entry on either side. This sits
directly in the freeze-thaw physics area the project treats as high-scrutiny
(Dall'Amico feature, `feature-001`). Not yet quantified against a specific
run; flagged per the "N parallel blocks, one outlier" pattern that has
produced 3 confirmed real findings already in this exact file
(`issue-048`, `issue-049`, `issue-050`).

## First bad time/cell/process

Not applicable this pass -- static source read only, no build/run/binary
execution performed (session-wide read-only constraint). Any soil layer with
nonzero macropore ice or water content and a nonzero micropore matric+osmotic
potential (`PSISM1+PSISO != 0`, i.e. almost every unsaturated layer) is a
candidate cell/hour.

## Reference and Zig source anchors

Legacy `f77src/watsub.f` (sha256
`8606E2EA96E52EE8109CF0EF78B6B49ABE0683E68BAA41FFACBEBAF1FE49DA95`) computes
`TFREEZ` once, from the **micropore's own** matric+osmotic potential
(`PSISV1=PSISM1(N3,N2,N1)+PSISO(N3,N2,N1)`, set at `:6359`):

```
:6399  TFREEZ=-9.0959E+04/(PSISV1-333.0)
```

Two structurally parallel freeze-thaw blocks follow, sharing this one
`TFREEZ` value:

- **Micropore** (`:6400-6418`): eligibility gate compares `TK1` against
  `TFREEZ` (`:6400-6403`); the driving-force formula
  (`HFLFM1=VHCP1*(TFREEZ-TK1)/(1.0+6.2913E-03*TFREEZ)`, `:6404-6405`) also
  uses `TFREEZ`. Gate and formula agree -- internally consistent, and
  physically correct: micropore water is held by the layer's own matric
  potential, so its freezing point really is depressed.
- **Macropore** (`:6430-6446`): eligibility gate compares `TK1` against
  **`273.15`**, the pure-water freezing point (`:6430-6433`) -- appropriate,
  since macropore water is free/gravitational, not capillary-bound, so it
  should not inherit the micropore's matric depression. But the driving-force
  formula immediately inside reuses the **same `TFREEZ`** computed at
  `:6399` for the micropore, not `273.15`:

```
:6434  VHCP1HX=4.19*VOLWH2(N3,N2,N1)+1.9274*VOLIH2(N3,N2,N1)
:6435  HFLFH1=VHCP1HX*(TFREEZ-TK1(N3,N2,N1))
:6436 2/(1.0+6.2913E-03*TFREEZ)
```

So the macropore block's own gate and its own formula disagree: entry is
decided at `273.15`, but the amount of latent heat/mass exchanged relaxes the
macropore ice/water toward the micropore's depressed `TFREEZ` instead.
Magnitude is not negligible: at a micropore matric+osmotic potential of
`-1 MPa`, `TFREEZ=-90959/(-1-333)=272.33 K` (~0.8 K below `273.15`); at
`-3 MPa` (plausible in a dry layer), `TFREEZ~270.71 K` (~2.4 K below). Since
this offset enters linearly into `HFLFH1`'s numerator, it directly biases the
computed macropore freeze/thaw latent heat and the resulting `WFLFLH`
water-ice conversion, in dry (very negative matric potential) layers most of
all -- exactly the freeze-thaw regime this project's Dall'Amico feature
already treats as scientifically sensitive.

Zig `ecosys-ng/src/soil/water/phase_change.zig` (sha256
`88A54A1A58972393ECEBEE71960A920A3A1724DCC2494E49B7EBC62121E461CC`),
function `freezeThaw` (`:286-302`):

```
:290  const freezing_temperature = -parameters.freezing_potential_numerator_k_megapascal / (potential_megapascal - parameters.latent_heat_of_fusion_megajoules_per_m3);
:291  const threshold_temperature = if (macropore) parameters.pure_water_freezing_temperature_k else freezing_temperature;
:292  if (!((temperature_k < threshold_temperature and liquid_m3 > 0) or (temperature_k > threshold_temperature and ice_m3 > 0))) return .{ ... };
:293  const unlimited_heat = capacity_megajoules_per_k * (freezing_temperature - temperature_k) / (1.0 + parameters.heat_capacity_temperature_feedback_per_k * freezing_temperature);
```

`threshold_temperature` (the gate, line 291) correctly branches on
`macropore`, matching legacy's `273.15`-vs-`TFREEZ` gate split. But
`unlimited_heat` (line 293, the actual driving-force formula) always uses
`freezing_temperature` -- the depressed value -- regardless of the
`macropore` flag. This exactly mirrors the legacy inconsistency, statement
for statement.

Call site `ecosys-ng/src/soil/water/phase_solver.zig` (sha256
`9EDA9CD994559FDC6DE189FD8565192BCE41266AAAD6282BFD7A66BC9E82C300`),
`:1514-1521` (`matrixFreezeThaw`) and `:1535-1543` (`macroporeFreezeThaw`),
confirms this is not merely a latent code path: **both calls pass the same
`matric_plus_osmotic_potential_megapascal` variable** -- there is no
separate, zeroed, or pure-water-adjusted potential threaded to the macropore
call. Production genuinely computes the macropore path with the micropore's
depressed potential feeding its `freezing_temperature`.

No comment in `phase_change.zig` or `phase_solver.zig` cites this specific
gate-vs-formula asymmetry, and no test in `solver_tests.zig` exercises a case
where `threshold_temperature` and the value driving `unlimited_heat` diverge
for the macropore path specifically (the existing tests use a fixed
`potential_megapascal` that happens to also be the value passed to both
calls, so a test asserting "macropore relaxes to 273.15" would fail if run,
but none currently attempts to).

## Falsifiable cause

The macropore block's driving-force formula (`HFLFH1`/`unlimited_heat`)
should relax macropore temperature toward `273.15` (the same physical
constant its own eligibility gate uses), not toward the micropore's
matric-depressed `TFREEZ`/`freezing_temperature`. As written, both legacy
and Zig compute a macropore latent-heat exchange consistent with a freezing
point that does not match the condition under which the block was entered.
This is falsifiable by re-deriving the formula with `273.15` substituted for
`TFREEZ` in the macropore-only path and comparing the resulting `HFLFH`/
`WFLFLH` (or `liquid_water_change_m3`) against the current formula's output
at a matched state with nonzero micropore matric depression -- they will
differ by an amount proportional to `(TFREEZ-273.15)`.

## Minimal input/state to test

A single soil layer with: `TK1` (or `temperature_k`) crossing `273.15` from
above or below; nonzero `VOLWH2`/`VOLIH2` (or `liquid_m3`/`ice_m3` for the
macropore call); and a micropore matric+osmotic potential meaningfully
negative (e.g. `-1` to `-3 MPa`, well within normal unsaturated range) so
`TFREEZ` diverges measurably from `273.15`. Compare `HFLFH`/`WFLFLH` (legacy)
or `macro_freeze.latent_heat_megajoules`/`liquid_water_change_m3` (Zig)
computed with the current formula (`TFREEZ`) against the same inputs with
the reference temperature forced to `273.15`.

## Before/after results

Not run this pass (static source audit only, per this session's read-only
constraint). The magnitude estimate above (`~0.8-2.4 K` reference-temperature
offset at plausible unsaturated matric potentials, entering linearly into the
latent-heat numerator) is analytic, not measured from a live run.

## Suggested next action

Independent review to decide disposition: either (a) confirm this is a
genuine, currently-live legacy defect faithfully-but-unintentionally
preserved in Zig, and correct the Zig-side formula to relax the macropore
path toward `pure_water_freezing_temperature_k` (a `legacy-defect-corrected`
candidate, matching this project's stated preference for correcting
demonstrated legacy defects rather than reproducing them silently); or (b)
find evidence this is an intentional legacy simplification (e.g. macropore
water in the immediate vicinity of the matrix is assumed to partially
equilibrate with matrix matric potential) and document it explicitly with a
citation and a test, the way `feature-001`'s Dall'Amico addendum documents
its own micropore/macropore asymmetry. Either way, a matched-state kernel
test (per the contract's attribution-order requirement) should be added
before this is closed. Not fixed this pass -- this session's constraint is
read-only, static-analysis-only.

## Affected evidence invalidated

None directly -- no prior traceability row or feature-dossier item
previously asserted `preserved`/exact-match for this specific macropore
freeze-thaw formula (the existing `feature-001` Dall'Amico addendum documents
the gate asymmetry as "deliberate... verified faithful" but does not appear
to have traced the formula-side reuse of `TFREEZ` specifically -- worth a
follow-up cross-check of that addendum's own claim, not done this pass).

## Independent review

Not yet done.

## Final disposition

`unresolved` -- confirmed as a real internal inconsistency in the legacy
source, confirmed as bit-for-bit faithfully reproduced (not corrected, not
diverged) in the current Zig production call path, and confirmed undocumented
on both sides. Blocks neither compilation nor an existing test; does not by
itself block a gate, but should be resolved (fixed-and-tested, or explicitly
accepted-and-documented) before `FEAT-018`/`FEAT-001` can be treated as fully
reviewed for freeze-thaw physics.
