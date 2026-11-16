# issue-129 — AcceptedTopsoilVaporPoreOverfill: producer/consumer tolerance inconsistency (cycle 00011, D-30)

## Terminal failure (two independent bit-exact reproductions)
Scout lane carbon8 and forensic lane v129b (v15-deck resume @8400, ship
lineage): 363 lane-days clean (D-27/D-28 walls passed), then
`error: AcceptedTopsoilVaporPoreOverfill` at wh 17115 (scene 2, 1999 d349,
hour 3), cell 0, inside the accepted topsoil-vapor update
(`postPhasePreHeat`), on a day with a 208-event soil-phase stagnation storm
(same bounded-publication family as the 8479/8480 freezing kink).
Precedents: cycle-10 gated runs logged ZERO soil-phase stagnations; v15/v16
authorities died at 8480 before storm season.

## P129TRIP receipt (lane v129b, ship + probes)
```
hour=17115 cell=0 mcap=6.23224676761516e-3 mliq=1.5467812243392808e-3
mliq_next=1.5467812243392808e-3  (vapor update contributed EXACTLY 0)
mice=4.296571903868254e-3 macap=1.2183590485857751e-4
mair_raw=-7.462077830644454e-13  mac_air_raw=1.0578046515788188e-4
tol=1.6354082672473738e-14  t=272.005 K
```
Hours 17110-17114: matrix air rides 0..1e-6 m3 then EXACTLY 0.0 — the storm
parks the topsoil at pore capacity; the trip hour crosses by 7.46e-13 m3,
BEFORE any vapor exchange, i.e. the state as published by the phase solver.

## Root cause
- Soil phase publish and precipitation ingress both ACCEPT over-capacity
  states up to `poreCapacityRoundoffToleranceM3 = max(1e-12, 64*eps*max(1,scale))`
  (phase_solver.zig:2482, precipitation.zig:428; documented + unit-tested) and
  clamp the air slot to zero — legacy `VOLP2 = AMAX1(0.0, VOLA1-VOLW2-VOLI2)`
  (watsub.f:2824) makes an over-full layer self-stabilizing: saturated layer
  takes zero vapor flux (`VP1=VPGV` branch), hydrology drains it next step.
- The topsoil-vapor pore guard instead used `water_volume_m3 + relative*caps`
  = 1.635e-14 — **61x tighter than its own producer** — so a state that was
  legal at the publisher became fatal downstream.

## Fix D-30
`topsoilPoreOverfillToleranceM3(matrix_cap, macro_cap)` = EXACT producer
predicate `max(1e-12, 64*eps*max(1, caps))`. Guard now fires only on
corruption BEYOND producer provenance; healthy hours bit-identical; no gate,
tolerance struct or physics moved; conservation validators unchanged.
(NOT `waterVolume()`-scaled: that applies 1e-12 RELATIVE to the full pore
capacity — 8 orders looser at scale, opposite direction, no precedent site.)

## Receipts
- Discriminated test `issue-129 topsoil vapor pore guard matches the producer
  tolerance, not leakage` (hourly_heat_water_solute.zig; test-EXECUTABLE root):
  NEUTER -> 1 fail, restore -> rc=0.
- Lane v129b (forensics): audit/runs/ottawa/cycle11-v129b-20261114.
- Lane v129c (D-30 validation, full campaign from 8400): must pass wh 17115
  and continue — receipt appended on completion.
- Authority: v17 campaign (p17, no D-30) will hit this hour ~2026-11-18; that
  death is the authority receipt for issue-129. v18 relaunch carries D-30.
