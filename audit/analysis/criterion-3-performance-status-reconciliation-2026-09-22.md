# Criterion 3 (performance) -- status reconciled against the reference measurement record, 2026-09-22

Written because criterion 3 ("significantly more performant than the legacy Fortran") had **zero measurement** across every round of this session, and I had been attributing that to `issue-091`'s Defender block. That attribution was wrong in an important way, and the reference documentation's own account of the blockers is **stale in three respects**.

Sources are in the read-only reference tree, absent from this repository (`issue-097`): `tools/production_performance_reference.json` and `docs/solver_performance_measurement.md`.

## What the qualification record actually demands

```json
{
  "id": "strict-releasesafe-throughput-pending-v3",
  "status": "unqualified",
  "qualification_requirement": "Replace this record only with a frozen threshold derived from
     a passing strict-production ReleaseSafe run using the current solver/conservation
     contract and archived raw evidence.",
  "minimum_serial_median_simulated_cell_hours_per_second": null,
  "interpretation": "No strict-production performance baseline is currently qualified.
     Production performance and release gates must fail closed. The historical 36-second
     loose-tolerance run is not admissible."
}
```

Two things I had not registered:

1. **The metric is `simulated_cell_hours_per_second`, serial median.** Not wall time for the whole deck. That is measurable over any bounded window.
2. **The required build is `ReleaseSafe`, not `ReleaseFast`.** The record's own id says so. Every build attempt I made this session, and every workaround recorded in `issue-091`, targeted **ReleaseFast**. **I never tried ReleaseSafe**, despite having established that the Defender detection follows the binary's *content* -- which is exactly what a different optimisation mode changes. `issue-091`'s claim that "all three non-privileged workarounds" were tested is therefore **overstated**, and is corrected there.

## Three stale blockers in `docs/solver_performance_measurement.md`

The document's central conclusion is *"we cannot yet time a fully converged run, because a fully converged run does not currently complete a single day."* All three supports for that have since been fixed.

| the document says | today's tree |
|---|---|
| The deck ships `runtime,4,1,1e-8,1e3,...`, i.e. `absolute_tolerance = 1e3`, so "the scaled residual is under 1 on the first iteration and `solve` returns at `iteration = 0`" -- the 36 s figure is "36 s with the convergence check effectively disabled" | The deck ships **`runtime,4,1,1e-8,1e-11,100,0.5`** (`src/validation/testdata/ottawa/runottawa:6`) and `...,1e-11,200,0.5` in `ecosys-ng-prod-examples`. `absolute_tolerance = 1e-11` -- **five orders tighter than the 1e-6 the document tested** and fourteen tighter than the 1e3 it measured |
| "Finding 3: at 1e-6 the model does not currently run" -- aborts on simulated day 1 with `heat mass balance lost: deviation_per_m2=1.1588e-1 tolerance_per_m2=1e-6` | This session's `run013`-`run019` reach **hour 3,275 (136 simulated days)** at `1e-11` before failing, and on unrelated errors. The day-1 `HeatMassBalanceLost` abort does not reproduce |
| "in `soil_water_solver.solve` the secant/Aitken/Anderson candidates are only attempted when `iteration + 1 == options.max_iterations`... Acceleration that runs once, at the end, cannot accelerate anything" | `soil/water/solver_solve.zig` now arbitrates Anderson on three independent triggers -- `stagnation_requires_anderson:1074`, `forecast_requires_anderson:1078` (using `remaining_updates = options.max_iterations - iteration:1077`) and `progress_requires_anderson:1089` -- plus a mandatory Newton retry. Not last-iteration-only |

So the document's recommended order ("1. Fix the heat mass balance defect so a tight-tolerance run can complete a day") is **already satisfied**. Its `cdb.exe` profiling note may still hold; not checked.

## What this changes

**Criterion 3 is now achievable, and was not when that document was written.** The chain it describes -- loose tolerance masking convergence, strict tolerance aborting on day 1, acceleration wired to fire only once -- is gone. A strict-tolerance run now covers 136 simulated days.

What remains between here and a *qualified* baseline:

1. **A readable optimised binary.** `ReleaseSafe` is building as of this writing; it is both the required mode and an untested Defender workaround. If it is readable, `issue-091` ceases to block criterion 3.
2. **A "passing" strict-production run.** The record demands a *passing* run, and the deck still stops at hour 3,275 of 262,920 (1.25%). So a frozen qualification threshold is not yet obtainable.
3. **A legacy denominator.** "Significantly more performant *than the legacy Fortran*" needs the Fortran throughput over the same span. The Fortran oracle has been built and run to completion in prior work, so this is obtainable.

**The honest intermediate deliverable**, available without (2): measure `simulated_cell_hours_per_second` for both models over the *same bounded window* (e.g. hours 1-3,000, which both complete) and report the ratio as an **indicative throughput comparison, explicitly not the frozen qualification threshold**. That is a real number for a criterion that currently has none, and it does not require converting a `BLOCKED` gate to `PASS` -- the qualification record stays `unqualified` and the gate stays failed closed until (2) is met.

## Limitations

Every number attributed to the reference documents is quoted from them and **not independently reproduced here**; they are a snapshot of 2026-09-10 or earlier and this note exists precisely because such snapshots go stale. The three "today's tree" column entries **are** verified against the current source at the cited lines. No performance measurement has been taken yet -- this note establishes that one is now possible, nothing more. `check_gate.py` owns gate status; nothing here changes it, and `tools/production_release_gate.ps1`, which would actually decide release readiness, is absent from this repository (`issue-097`).
