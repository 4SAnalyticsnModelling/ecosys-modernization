# run-013 -- fresh-from-hour-1 validation of the issue-083/issue-078 relief fixes: REGRESSION, source reverted

Date: 2026-09-21. Lane: editor (Claude Code), adversarial Claude/Pi session. One heavy run at a time was respected: `Get-Process` for `ecosys_ng`/`ecosys_x`/`ecosys_oracle` returned nothing before launch, and the reviewer lane was explicitly told not to build or run while this was going.

## Result, stated first

**FAILED at hour 2,973 of 262,920 with `SoilWaterSolverStagnated`. This is a REGRESSION of 280 hours against the documented pre-change frontier of hour 3,253 (`RuntimeSoilPoreCapacityExceeded`, `issue-078`).** The two source fixes under test were therefore **reverted**; all diagnostic evidence and the issue records were kept. The tree is back to the frontier it had before this round.

The hypothesis under test was that the two fixes together would clear hour 3,253. They did not, and they made the frontier worse. That is the honest outcome and it is recorded here rather than being framed as partial success.

## What was under test

Commit `9db403d` (since reverted in the source files, retained in history):

1. `soil/profile/runtime_material_refresh.zig` -- entry-guard domain corrected from "must fit the previous hour's pore capacity" to "must fit the layer's own bulk volume" (`MATRIX-ENTRY-OVERFILL-DOMAIN-002`).
2. `soil/water/solver_residual.zig` -- the vertical mechanical excess-relief term applied donor-bounded only, no longer inheriting the Darcy term's recipient clamp, plus the per-cell trial ceiling moved after the prepass and taken from `@max(base, target)` (`MECHANICAL-RELIEF-DONOR-BOUND-ONLY-001`).

Pre-run evidence, all real: full suite `zig test src/module_index.zig` = **4376 passed, 1 skipped, 0 failed, exit 0** (baseline 4375 + 1 new test, reconciles exactly); `zig build -Doptimize=ReleaseFast` exit 0; the new regression test was confirmed **discriminating** (fails with the clamp restored, reporting relief `0` instead of `-0.04`).

## Exact configuration

- Binary: `ecosys_ng.exe`, SHA-256 `9C5F040D76502B4048EAC147D89DDDB9EC96E0406904EFD143FF796E957B9D90`, built from the `9db403d` source state with `zig build -Doptimize=ReleaseFast`, Zig 0.16.0.
- Deck: `robocopy /E` of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/` into a scratchpad copy, `/XD runottawa_output_files`, with an empty `runottawa_output_files/` recreated. The tracked deck was never written to.
- Invocation: `ecosys_ng.exe runottawa`, cwd = the scratch deck copy, stderr and stdout redirected to files. Fresh from hour 1; no checkpoint.
- Wall clock to failure: roughly 40 minutes; ~1.1-1.3 s per hour early on.

## Failure record

```
error: hourly science failed: execution=1 scenario=1 scenario_repeat=1 scene=1
  scene_hour=2973 total_hour=2973 year=1998 day_of_year=124 month=5 day=4 hour=21
  error=SoilWaterSolverStagnated
```

The complete retry ladder was exhausted, every attempt failing at its **first** substep:

| `exact_substep_count` | `time_step_hours` | iteration | `limiting_cell` | `state_m3` | `residual_m3` | `scaled_residual` |
|---|---|---|---|---|---|---|
| 4 | 2.5e-1 | 5 | 4 | 2.5310893e-2 | 1.9228830e-6 | 7.594e3 |
| 20 | 5e-2 | 6 | 4 | 2.5310579e-2 | 1.6050910e-7 | 6.339e2 |
| 32 | 3.125e-2 | 8 | 0 | 7.3960700e-3 | 4.5298075e-10 | 6.116e0 |
| 64 | 1.5625e-2 | 6 | 3 | 2.5065218e-2 | 2.2725222e-9 | 9.063e0 |

`limiting_domain=matrix` in every case, `anderson_steps=0` throughout.

**The diagnostic shape that matters**: the *absolute* residuals are minute (1.9e-6 down to 4.5e-10) while the *scaled* residual is enormous (7,594 down to 6.1). That is a scaling blow-up on a nearly-converged state, not a large physical imbalance -- the signature of a state pushed to the edge of its own domain, where the matric-potential/conductivity relation is extreme.

Conservation was accepted every day right up to the failure (water ~1.9e-14, heat ~3.5e-13, carbon ~3.3e-13, nitrogen ~1.8e-14 at day 94), so nothing was leaking; the run died on convergence, not on a balance defect.

## Attribution, and its honest limit

The only difference from the configuration that previously reached hour 3,253 is the three source files above, so the regression is attributable to this round's changes with high confidence. **It is not isolated**: no control run was made with change 1 alone or change 2 alone, so which of the two is responsible -- or whether it is their interaction -- is inference, not measurement. Anyone resuming should not treat the attribution below as established.

**Leading hypothesis, consistent with every observation but not yet tested.** `issue-083` records a known, deliberately-unported third leg of the oracle's relief system: `watsub.f:3683-3685`'s top-soil-layer-to-surface-litter discharge, which is also donor-bounded with no recipient clamp. ecosys-ng's solver has no litter face -- independently confirmed this round at `transport/hydrology.zig:484`, where vertical faces are built with the shallower layer as `source_cell` and `layer+1` as `destination_cell`, ascending, so **layer 0 is never a vertical-face destination and therefore has no in-solver relief outlet at all**.

Porting the layer-to-layer leg (change 2) without that terminus turns the column into a one-way pump: each substep moves excess upward into layer 0, which can shed it nowhere, so water accumulates at the top of the profile. Two observations fit this and are hard to explain otherwise:

- The failure is **441 hours after** the only tillage event in the run (below), i.e. a slow accumulation rather than an immediate post-tillage abort.
- `limiting_cell` is 4, then 4, then **0**, then 3 -- the topmost layer appears as the limiting cell, and the whole failure is matrix-domain.

The implication is that the oracle's three relief legs are a **system**: porting the layer-to-layer leg in isolation is worse than not porting it, because the unported terminus is what keeps the top of the column from filling. This is the most reusable finding of the round.

## Incidental correction to issue-078's tillage timing

The stage census reports **one** tillage event in this run:

```
tillage_soil_application entries=1 first_hour=2532 last_hour=2532
fertilizer_application  entries=1 first_hour=2508 last_hour=2508
```

`issue-078`'s dynamic-diagnosis pass records tillage firing "at exactly hour 3,252". Hour 2,532 is day 106 and hour 3,252 is day 136, so the deck evidently has **more than one** tillage day and `issue-078`'s frontier follows the **second** one, which this run never reached. Do not read `issue-078`'s "hour 3,252" and this record's "hour 2,532" as a contradiction, and do not "correct" either one to match the other without checking the deck's management file for both days.

Worth noting on its own: the run passed hour 2,532's tillage and its following hour without any capacity abort.

## Disposition and next action

- Source reverted: `git checkout 9db403d~1 -- <the three files>`, verified by an empty `git diff 9db403d~1 -- ecosys-ng/src`. The new regression test went with the revert, since it pins behavior that no longer exists.
- `issue-083` stays **OPEN** with its diagnosis intact. The diagnosis is not weakened by this run: the oracle asymmetry at all three face types was verified line by line, and the recipient clamp demonstrably zeroes the relief (measured `0` instead of `-0.04` in a unit test). What is refuted is the *sufficiency and safety of porting leg two alone*.
- **Next bounded action**: do not retry change 2 by itself. Either port the litter terminus (`watsub.f:3683-3685`) in the same change so the column has an outlet, or leave both unported. If the terminus is attempted, it needs its own conservation evidence at the litter boundary before any production run, because it moves water across a ledger boundary that the layer-to-layer leg does not touch.
- Diagnosis budget: this spent `issue-078`'s third and final experiment and the first of `issue-083`'s. A second identical failure with this signature and no new evidence must not be run.
