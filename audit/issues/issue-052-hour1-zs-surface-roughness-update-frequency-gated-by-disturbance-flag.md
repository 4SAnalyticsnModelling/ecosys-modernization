# Issue 052: legacy `ZS` ground/snow/water surface roughness is only recomputed on a rare disturbance/restart event, but Zig recomputes it from live state every hour -- revises `feature-006` item 2 from `preserved`

## Impact/severity

Medium-to-high, pending materiality review. `ZS` feeds directly into the
canopy zero-plane displacement/roughness/Richardson-number/boundary-layer
resistance chain (`feature-006` item 3, `hour1.f:4821-4874`, cited by its own
header comment as also consumed by `watsub.f` and `uptake.f`), the ponded
surface-water storage capacity `VOLWD`/`VOLWG` (`hour1.f:2373-2377`), and the
runoff-velocity roughness comparison in `watsub.f:825`. A frequency mismatch
in when this quantity updates therefore has a plausible path into the
canopy/root energy-balance chain this session has already been tracing
(`issue-024`'s THERMAL_PAIRED context, `feature-004`'s `uptake.f` canopy
energy body) -- flagged here as a concrete lead, not re-litigated.

## First bad time/cell/process

Not applicable this pass -- static source read only, no build/run/binary
execution performed (this task's explicit read-only constraint). Candidate
cells/hours: any grid cell that accumulates a first snow layer
(`VHCPW(1,NY,NX).GT.VHCPWX(NY,NX)`) at some hour strictly after
initialization, with no tillage/erosion/redistribution/restart event firing
that same cell's `IFLGS` flag in the same or an intervening hour.

## Reference and Zig source anchors

Legacy `f77src/hour1.f` (sha256
`BC5F02433C47E31ABFBB04128D2F1C2764029E50AB18B3BD1FF812DA4C2DA859`): the `ZS`
assignment cited by `feature-006` item 2 --

```
:2367  IF(BKDS(NU(NY,NX),NY,NX).LT.ZERO
:2368 2.OR.VHCPW(1,NY,NX).GT.VHCPWX(NY,NX))THEN
:2369  ZS(NY,NX)=ZSW
:2370  ELSE
:2371  ZS(NY,NX)=ZSX
:2372  ENDIF
```

sits entirely inside a disturbance-gated block:

```
:1900  IF(IFLGS(NY,NX).NE.0)THEN
  ... (:1901-2386, litter/soil physical-property resets)
:2367-2372  (the ZS branch above)
  ...
:2385  C     IFLGS=reset disturbance flag
:2387  IFLGS(NY,NX)=0
:2388  ENDIF
```

`grep`-confirmed across `f77src/*.f`: `ZS(NY,NX)=` is assigned **only** at
these two lines in the whole codebase. `IFLGS(NY,NX)` is set nonzero **only**
at `starts.f:388` (once, at simulation start), `redist.f:8524,11056,11428` /
`redist_utf8.f:8524,11056,11428` (inside `REDISTRIBUTE POND, SOIL MATERIAL`,
gated on `FX.GT.ZERO`, i.e. an active erosion/sedimentation redistribution
event for that layer/hour), and `routs.f:44` (checkpoint-restart
re-initialization). It is reset to `0` immediately after use at
`hour1.f:2387`. There is no path by which ordinary within-season snow
accumulation or melt, absent one of those three trigger types, causes `ZS` to
be re-evaluated. `ZS` is consumed downstream at `hour1.f:2373-2377` (`VOLWD`/
`VOLWG`), `hour1.f:4838,4851` (`ZE`/`ZR`, `feature-006` item 3), and
`watsub.f:825`.

Zig `ecosys-ng/src/surface/aerodynamics.zig` (sha256
`ED1F0702E9DCFBB62540C11068685EAC83F7F473EC8C3CCFD8656C42B4734A4C`),
`sourceGroundSurfaceRoughnessHeightM` (`:120-...`) reproduces the branch
formula correctly (already covered by `feature-006` item 2's existing test).
But the call site, `ecosys-ng/src/stages/hourly_process_driver.zig:408-417`,
invokes it **unconditionally inside a plain per-cell hourly loop**
(`for (0..context.grid.cell_count) |cell| { ... }`), passing that hour's
**current** `bulk_density_megagrams_per_m3` and **current**
`heat_capacity_megajoules_per_k` for the first snow layer -- with no
disturbance-flag-equivalent gate. Confirmed by reading the surrounding driver
code directly, not by trusting a comment.

## Falsifiable cause

Legacy's `ZS` is a "sticky" quantity: set once at simulation start (or reset
after a disturbance/erosion/restart event) and then held fixed through
ordinary within-season snow accumulation and melt, because its only
assignment site is nested inside the `IFLGS`-gated block. Zig recomputes the
same quantity from live snow/bulk-density state every hour, unconditionally.
This is falsifiable: construct a two-hour sequence where hour N has no snow
(`VHCPW(1)<=VHCPWX`) and hour N+1 accumulates a first snow layer
(`VHCPW(1)>VHCPWX`), with `IFLGS` not set in either hour (no tillage/erosion/
restart). Legacy's `ZS` at hour N+1 will equal its hour-N (pre-snow) value;
Zig's `ZS` at hour N+1 will switch to `ZSW`. The two diverge whenever this
sequence occurs without a coincident disturbance event -- which, per the
`grep` above, is the common case for ordinary winter snow onset.

## Minimal input/state to test

A single grid cell/soil column run through `hour1`-equivalent logic for two
consecutive hours with: no tillage/erosion/checkpoint-restart event in either
hour; `BKDS(NU)` positive (not a permanent water body) in both hours; first
snow layer heat capacity below `VHCPWX` in hour N and above it in hour N+1.
Compare legacy's retained `ZS` value at hour N+1 against Zig's freshly
computed value for the same state.

## Before/after results

Not run this pass (static source audit only, per this task's explicit
read-only constraint: no `zig build`, no binary execution). This is a
structural/control-flow finding from direct source reading on both sides, not
a measured numerical result.

## Suggested next action

Independent review/coordinator judgment is needed on disposition, because
either direction requires a scientific-scope decision, not just a code fix:

- If Zig's continuous per-hour `ZS` recompute is judged an **improvement**
  (tracking real transient snow cover more faithfully than legacy's
  disturbance-gated staleness), it should be filed as an explicit approved
  feature (`replaced-by-approved-feature` or `legacy-defect-corrected`) with
  its own feature-register entry, a matched-state kernel test demonstrating
  the two-hour divergence scenario above, and a documented scientific envelope
  per the contract's "improved production physics" comparison track --
  not left as an undocumented, silently-differing update cadence.
- If exact translation parity is instead required here, Zig's call site
  (`hourly_process_driver.zig:408-417`) would need an `IFLGS`-equivalent gate
  (disturbance/erosion/restart-triggered recompute only) rather than an
  unconditional per-hour recompute.

Either way, `feature-006` item 2's disposition is revised below from
`preserved` to `unresolved` pending that review; the existing bit-for-bit
formula test remains valid and is not itself in question.

## Affected evidence invalidated

`audit/features/feature-006-hour1-canopy-surface-physics.md` item 2
("Water/snow surface roughness `ZS`") -- disposition downgraded from
`preserved` to `unresolved` this pass; see that dossier's addendum for the
correction. The formula-level bit-for-bit match that item 2 originally
verified (branch predicate and constants) remains correct and is not
retracted -- only the *update-frequency* claim (implicitly assumed identical
by treating the formula match as sufficient) is now flagged as unverified/
likely divergent.

## Independent review

Not yet done.

## Final disposition

`unresolved` -- confirmed control-flow divergence in update cadence between
legacy (disturbance/restart-gated, effectively static most of the run) and
Zig (unconditional per-hour recompute from live state) for the same source
quantity `ZS`/`ground_surface_roughness_height_m`. Requires reviewer/
coordinator scientific judgment on which cadence is authoritative before this
can be closed as either an approved improvement or a translation defect to
fix. Materiality (how much this actually moves canopy/surface energy-balance
outputs in a real production run) is not assessed this pass.
