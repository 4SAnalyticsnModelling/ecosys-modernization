# Issue 106 -- executable-root test 71 expects substep ladder {1,20,32,64}; code gives {4,20,32,64}

Status: **OPEN** (found in run-034, `audit/runs/issue-104-exe-root-full2/stderr-snapshot-before-stop.log`).

- Test: `stages/hourly_heat_water_solute.zig:10555` `fixed external hour recovery escalates through the full chain and stops on hard defects`. It asserts `expectEqualSlices(..., &.{ 1, 20, 32, 64 }, ...)` and observes `{ 4, 20, 32, 64 }`.
- History: the test dates from `514dd68` (initial import). `99234f1` "Implement Fortran wthr.f NFH=4 universal substep baseline (issue-024)" later raised the baseline. The test is in the executable root, which did not compile or run (issue-104), so it was never reconciled.
- Question: is NFH=4 the verified legacy baseline (`wthr.f`)? If yes, the expectation is stale and should cite `wthr.f`. If no, `99234f1` is the defect. Decide from legacy (f77query) before touching either. Do not relax the test to pass.
