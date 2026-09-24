# Issue 108 -- hour 3,289: carbon (-2.15e-6 g) and Ca/Na/K (+9.2e-8, +2.9e-10, +1.5e-10) closure failures once root geometry is defined

Status: **OPEN** (frontier; exposed by the issue-105 fix, run-036).

- Evidence: `audit/runs/issue-105-fix-run/stderr.log` (SHA256 `3108D56D...`) and `audit/runs/run-036-issue-105-root-geometry-fix-clears-the-error-and-exposes-conservation-at-3289-2026-09-24.md`.
- The cations are positive (storage gained more than was booked) and sit entirely in soil layer 2. The carbon row is negative and has no layer split printed.
- Hypothesis (untested): the first-ever root gas and solute exchange in layer 2 books no, or incomplete, boundary or internal terms. Candidates are root CO2/O2 exchange in `plant_root_gas_transport` (carbon) and a root or rhizosphere cation path (Ca/Na/K). The legacy counterpart is the `uptake.f` gas-exchange blocks at `:2040-2140`.
- Next: decompose the existing post-NITRO trace for hour 3,289 from the run-036 log (no new run). Localize the carbon step to a stage interval, then probe that stage.
