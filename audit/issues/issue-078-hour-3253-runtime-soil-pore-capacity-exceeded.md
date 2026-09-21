# Issue 078 -- hour 3,253 `RuntimeSoilPoreCapacityExceeded` (new frontier exposed by issue-024's committed universal `NFH=4` baseline fix)

Status: OPEN, FRESH DISCOVERY RECORD ONLY -- NOT YET DIAGNOSED (2026-09-21). This issue is filed per explicit task instruction not to diagnose or fix this frontier in the same pass that implemented and committed issue-024's universal `NFH=4` baseline fix. That fix prevents hour 2,894's collapse and clears hour 2,895 (the frontier issue-024/issue-068/issue-077 shared), and the run then proceeds 358 hours further than any prior attempt in this session before hitting this new, distinct failure.
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979; `ecosys_ng.exe` (committed universal-NFH=4-baseline binary) SHA-256 `70066EB2558392985B934E6014BC02150BD78E303EEC79CC0919C693458A7DB9`.
Source finding: `audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md`'s "Diagnostic experiment (2026-09-21, non-committed)" section (first observed this exact failure) and its "Committed fix (2026-09-21)" section (reproduced bit-for-bit with the real, committed binary).

Failure signature and first bad time/location/process:
Fresh-from-hour-1 `ReleaseFast` run (isolated deck copy, `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON`/`runottawa`, no checkpoint/resume, single-threaded), with the committed universal-`NFH=4`-baseline fix in place, runs cleanly through hour 3,252 (`census_positive_control entries=3252 first_hour=1 last_hour=3252`) and fails at hour 3,253:

```
error: runtime soil entry pore capacity exceeded: cell=0 layer=1 index=1
  previous_matrix_capacity_m3=7.670613113153217e-3
  refreshed_matrix_capacity_m3=7.654774304374367e-3
  matrix_occupied_m3=8.535563021092726e-3
  previous_matrix_excess_m3=8.649499079395094e-4
  macropore_capacity_m3=3.1018702069747965e-6
  macropore_occupied_m3=0e0
  macropore_excess_m3=-3.1018702069747965e-6
error: RuntimeSoilPoreCapacityExceeded
```

Reproduced bit-for-bit identically across two independent runs this session: the original diagnostic experiment (uncommitted, since-reverted-then-recommitted code) and the fresh validation run against the real, committed binary. Both runs' `census_positive_control` report the identical `last_hour=3252`, and the terminal error's numeric fields are identical between the two runs.

This is a **different failure signature and different location** from every prior frontier in the issue-024/issue-068/issue-077 chain:
- Different error type: `RuntimeSoilPoreCapacityExceeded`, not `SoilPhaseSolverStagnated` (issue-068's chronic frontier) or any of the `DRY_CARRIER`-family collapse signatures.
- Different layer: `layer=1` (the second soil layer, index 1), not `layer=0` (cell 0's top layer, the site of every prior hour-2894/2895 investigation in this chain).
- Different mechanism, as named by the error itself: `matrix_occupied_m3` (8.535563021092726e-3) exceeds `refreshed_matrix_capacity_m3` (7.654774304374367e-3) by `8.649499079395094e-4` (0.865e-3 m3, roughly 11% over capacity) -- water occupying more volume than the layer's own pore space allows after a capacity refresh, not a Newton/Anderson convergence failure.

Scientific/output impact: not yet assessed. This is the new frontier exposed once the hour-2,894/2,895 collapse (which previously terminated every run at that point) is prevented; it represents genuine further progress (358 more hours simulated than any prior attempt), but blocks continuation past hour 3,253 until diagnosed. Given `layer=1` and a pore-capacity/matrix-occupancy imbalance, this may be mechanistically related to this issue's own still-open root cause (chronically elevated water content in the top 1-2 layers, rounds 1-7) migrating one layer deeper, to whatever process refreshes `matrix_capacity_m3` (likely a relayering/erosion or retention-parameter update between hours, given the "previous" vs "refreshed" capacity distinction in the error's own field names) -- not yet confirmed.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: isolated deck copy of `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON` (robocopy `/E`, excluding `runottawa_output_files/`), committed `ecosys_ng.exe` (hash above) copied alongside, `ecosys_ng.exe --execution-evidence <path> --threads 1 runottawa`, fresh-from-hour-1, no checkpoint/resume.
Input/state provenance: same Ottawa deck used throughout this session's issue-024/issue-068/issue-077 chain.
Hypothesis: none yet ranked/tested. Per the `ecosys-divergence-diagnosis` skill's ranked-cause order, candidates to check first: (1) whether `refreshed_matrix_capacity_m3` < `previous_matrix_capacity_m3` (confirmed true from the error's own fields: 7.6548e-3 < 7.6706e-3, a small ~0.2% shrinkage) reflects a legitimate physical process (e.g. relayering, freeze-thaw-driven pore-space change, or a retention-parameter update) versus a translation defect in whatever computes the "refreshed" capacity; (2) whether `matrix_occupied_m3`'s growth to 8.5356e-3 -- already above even the PREVIOUS (larger) capacity of 7.6706e-3 -- traces back to the same chronically-elevated-water-content mechanism this issue's rounds 1-7 already describe for layer 0, now appearing one layer deeper because the universal `NFH=4` fix changed the trajectory enough to let water accumulate past hour 2,894 without collapsing; (3) whether the pore-capacity check itself (wherever `RuntimeSoilPoreCapacityExceeded` is raised) has an off-by-one or stale-capacity-snapshot defect, given the error explicitly distinguishes a "previous" and "refreshed" capacity for the same layer at the same instant.
Stop/resource budget: fresh issue, 0 of the contract's 3-experiment diagnosis budget spent yet.

## Experiments
(none yet -- this issue documents the discovery only, per this task's explicit instruction not to diagnose it in the same pass that implemented the universal `NFH=4` baseline fix)

## Resolution
Cause and focused patch: not yet determined; no diagnosis attempted.
Before/after results: n/a.
Regression added and actually executed: none yet.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN, fresh discovery**. Recommended next action for whoever picks this up: locate the exact call site that raises `RuntimeSoilPoreCapacityExceeded` (likely in a soil-entry/pore-capacity validation routine adjacent to the relayering or retention-parameter-refresh code, given the "previous"/"refreshed" capacity distinction in the error's own field names), read it against the equivalent Fortran mechanism (if any -- this may be a Zig-only runtime safety check with no direct Fortran counterpart, in which case the question becomes why the *occupancy* grew past capacity in the first place, not whether the check itself is a mistranslation), and determine whether this connects to this issue's own still-open chronic-elevated-water root cause now manifesting one layer deeper thanks to the universal `NFH=4` fix's changed trajectory past hour 2,894.
