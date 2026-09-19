# Issue 049: domain-boundary snow drift is dead code in legacy WATSUB but wired live in Zig

## Impact/severity

Moderate, scope-dependent. Affects mass/energy/solute conservation and output
comparison at any lateral grid-edge cell whose site-file boundary is "open"
for runoff (`RCHQE`/`RCHQW`/`RCHQS`/`RCHQN` > 0) and topographically downhill,
when wind blows snow toward that edge. Silent under decks where every lateral
boundary is closed for snow-bearing periods; **not established to be silent
for the in-scope Ottawa production deck** (see below).

## First bad time/cell/process

Not run-diagnosed (this pass is static source audit only, per project
constraint; no build/execution performed). This is a structural code-path
divergence identified by direct source comparison, not an observed output
mismatch. Any hour with nonzero wind, nonzero top-layer snow, and an
open+downhill lateral boundary in the deck's site file would be first-affected.

## Reference and Zig source anchors

Legacy `f77src/watsub.f` (sha256
`8606E2EA96E52EE8109CF0EF78B6B49ABE0683E68BAA41FFACBEBAF1FE49DA95`):

- `:3868-4128` -- **interior** (cell-to-cell, not domain-boundary) snow drift
  is active code: `QSX=1.0E-07*UA*XNPHX`, `QSM/QWM/QIM`, `QST`, then the
  `DO 4310 N=1,2 / DO 4305 NN=1,2` loop computes `QS1/QW1/QI1/HQS1` for every
  interior E/S/W/N face. This range is preserved correctly in Zig (see
  feature-018 item 10) and is not this issue's subject.
- `:5675-5720`, banner "BOUNDARY SNOW REDISTRIBUTION FROM SNOWPACK
  (DISABLED)" -- the domain-boundary counterpart (crossing a grid edge to
  outside the modeled landscape) is **entirely commented out** by the
  original legacy authors. The only live statements in this block
  unconditionally zero every boundary snow-transfer quantity regardless of
  wind, slope, or the `RCHQF`/`IRCHG` boundary-openness test that the
  otherwise-parallel boundary **runoff** block (`:5556-5667`, active,
  non-commented) does use:
  ```
        QS1(N,NN,M5,M4)=0.0
        QW1(N,NN,M5,M4)=0.0
        QI1(N,NN,M5,M4)=0.0
        HQS1(N,NN,M5,M4)=0.0
        QSTN(M,N,NN,M5,M4)=0.0
        IFLBMS(M,N,NN,M5,M4)=0
  ```
  The entire physically-motivated commented-out alternative (elevation
  comparison `ALTS1`/`ALTS2`, `QSM(N2,N1)*FSLOPE*RCHQF`, etc., `:5695-5717`)
  is dead reference text only. **In every legacy production run, snow cannot
  leave the modeled domain through a lateral boundary; it can only leave via
  the active bottom/vertical paths or remain internal.**

Zig `ecosys-ng/src/soil/water/snow_drift_routing.zig` (sha256
`D0B0BAE11DA3D963A4B0B5C7156CE54CDE2DD9DCF76D24EE0CCAFAAAE6A2F264`),
`produceAndRoute` (`:160-416`): the file's own doc comment (`:155-159`) cites
`WATSUB 3876--4100` (the active interior range) as its authority, but the
function's `eligibleDirection` helper (`:418-427`) also grants eligibility to
an open **domain boundary** face:
```
    return isOpen(direction, cell, inputs.boundaries) and isDownhill(direction, cell, inputs.downhill);
```
and the function books a real, tested, mass/energy/solute-conserving export
to `PhysicalResult.boundary_*` fields (`:48-56`) and to the landscape boundary
ledger (`:392-401`) when that happens -- see the passing test "open QSX drift
books physical and all-element boundary activity" (`:711-775`), which
positively exercises this exact path and asserts `boundary_water_equivalent_m3
> 0`.

This is wired into the real production hourly loop, not just exercised by
unit tests: `ecosys-ng/src/stages/hourly_heat_water_solute.zig`
(sha256 `D648C471DA68B8FDE681CD741636EB8F301AE68CEBC44F9DE467EC504475A13D`),
`advanceSnowDrift` (`:5449-5474`), passes
```
    .boundaries = .{
        .east_open = context.surface_erosion.east_boundary_open,
        .west_open = context.surface_erosion.west_boundary_open,
        .south_open = context.surface_erosion.south_boundary_open,
        .north_open = context.surface_erosion.north_boundary_open,
    },
```
and `ecosys-ng/src/stages/hourly_process_driver.zig`
(sha256 `AA346D425C9BEB4CD129765FB6CB7E526D902AB4C275B484798651CAC059E9CB`),
`refreshSurfaceBoundaryOpenFlags` (`:42-64`), sets those exact same flags from
`site_by_cell[cell].surface_runoff_boundary_fraction[dir] > 0` combined with
the topographic downhill gate -- i.e. **the identical mask the legacy model
uses only for the active runoff/erosion boundary paths** (`watsub.f:5556-
5667`, faithfully reproduced; the file's own header comment states "Snow
drift and runoff share the same immutable site boundary mask"). Nothing in
the production wiring keeps snow drift's boundary eligibility permanently
closed the way the legacy source does.

This is not merely a dormant/test-only capability: the site-file field this
depends on, `surface_runoff_boundary_fraction` (`state/site.zig:37`,
READI record order N/E/S/W), is confirmed nonzero on at least one real parsed
site fixture in this repository (`state/site.zig` parser test, `:229`:
`[0, 1, 1, 0]` -- east and south open). Whether the in-scope Ottawa
production deck's actual site file has any lateral boundary fraction nonzero
at a topographically-downhill, grid-edge cell has **not been checked this
pass** (would require reading the specific site input file, out of this
static-audit range) -- that is the open question this issue tracks.

## Falsifiable cause

Zig's snow-drift boundary eligibility was implemented by reusing the runoff/
erosion boundary-openness mask under the stated rationale that "snow drift
and runoff share the same immutable site boundary mask" -- but the legacy
reference does **not** treat them as shared: it deliberately, explicitly
disables the boundary snow-drift path (leaving only its dead commented-out
skeleton) while leaving the structurally parallel boundary runoff path fully
active with that mask. If the Ottawa (or any other in-scope) deck has a
nonzero, topographically-open lateral boundary fraction during any
snow-covered, windy hour, Zig will export mass/heat/solutes across that
boundary that the legacy model structurally cannot, producing a real,
attributable output divergence at that boundary cell (and, via mass
conservation, at its neighbors) that is not an approved feature and has no
feature-register entry.

## Minimal input/state to test

Site file's `surface_runoff_boundary_fraction` for a grid-edge, topographically
-downhill cell; nonzero top-layer snow at that cell; nonzero wind. A minimal
reproducer: a 1-2 cell strip identical to `snow_drift_routing.zig`'s own
"open QSX drift books physical and all-element boundary activity" test
(`:711-775`) but replaying the exact Ottawa site boundary fractions instead of
a synthetic fixture, to see whether `boundary_open` ever evaluates true for a
snow-bearing hour in the actual deck.

## Before/after results

Not measured this pass (static source audit only; no build/run permitted for
this pass per project constraint).

## Suggested next action (bounded, not a reopening of any other issue)

1. Check the Ottawa (and any other in-scope) site file's
   `surface_runoff_boundary_fraction` values at grid-edge cells against the
   topographic downhill gate (`hourly_process_driver.zig:31-36`) to establish
   whether this path is ever live for the current production deck's actual
   geometry -- this alone may show the divergence is currently dormant.
2. If live: decide and record a scope disposition -- either (a) gate Zig's
   `produceAndRoute` boundary eligibility permanently closed for snow drift
   specifically (matching the legacy dead-code reality exactly), or (b)
   register this as an explicit, reviewed `replaced-by-approved-feature`
   scope decision (physically-motivated: legacy's omission looks like an
   unfinished feature, not a deliberate physical choice, since the commented-
   out skeleton shows the original authors intended to implement it) with its
   own feature-register entry and a documented mass-balance envelope.
3. Either way, this needs an explicit disposition and is not resolved by this
   audit pass alone.

## Affected evidence invalidated

None directly (no prior evidence asserted this path was exercised or
verified). Flags feature-018's coverage claim for `watsub.f:3737-4370` as
incomplete without this issue's resolution.

## Independent review

Not yet done.

## Final disposition

`unresolved` -- requires (a) a check of whether this path is live for the
in-scope deck's actual site-file boundary configuration, and (b) an explicit
scope decision (close the gap vs. register as an approved feature) with
review, before this can be marked `preserved`, `replaced-by-approved-feature`,
or `legacy-defect-corrected`.
