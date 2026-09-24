# run-027 -- fixture deck stops at hour 3,162; the recorded frontier depends on two audit-era deck edits (2026-09-23)

Task `20260923-231724-7fa23089` (issue-100 probe re-gate to hour 3,276). **Operator error, recorded rather than discarded.**

## What ran

- Binary: ReleaseSafe build of HEAD `6944efe` plus the issue-100 re-gate (probes gated on `diagnostic_nitrogen_trace_target_hour = 3276`, and a new `fertilizer_dispatch` probe). Build receipt `audit/runs/issue-100-n100e-build/receipt.json` (exit 0, 908.9 s). exe SHA256 prefix `24C04885821572F6`.
- Deck: staged from `ecosys-ng/src/validation/testdata/ottawa/`, **not** from the required deck `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/` (`PROJECT_CONTRACT.md:14`). All 78 staged files match `testdata/ottawa/PROVENANCE.json` SHA256 (checked file by file).
- First launch `audit/runs/issue-100-n100e-run/`: `launch_error` WinError 2, 0.012 s. The relative `./ecosys_ng.exe` is not resolved against `--cwd` by `run_logged.py` on Windows, so it did not execute. Use an absolute exe path.
- Second launch `audit/runs/issue-100-n100e-run2/`: exit 1 after 1,981.6 s. stderr SHA256 `4AE77832A2E68973DB9D184887804DCACF4D5A89308DDE625810633A25DBD8A6`.

## Result

- Terminal error `SoilWaterSolverStagnated`. Census: `census_positive_control entries=3161 first_hour=1 last_hour=3161`, `across 3162 simulated hour(s)`, `fertilizer_application entries=1 first_hour=2508 last_hour=2508`.
- The hour-3,276 probes never fired, so this run says nothing about issue-100's prediction.

## Why it differs from the recorded 3,275 frontier

After removing `TEMP_DIAGNOSTIC` lines, the first differing log line against run-025 (`audit/runs/run-025-n100d-raw/combined.log`) is line 0: run-025 logs `runtime max_nonlinear_iterations=200` and this run logs `=100`. A file-by-file hash diff of the fixture deck against the required deck finds exactly two differences (of 78 files):

| File | Commit | Change |
|---|---|---|
| `runottawa` `runtime` record | `9253d3b` (issue-015) | `max_nonlinear_iterations` 100 -> 200 |
| `runottawa_input_files/parameters/soil_chemistry_reaction_parameters.txt` | `5add7de` (issue-007) | `soil_ammonium_extract_multiplier` 0.01 -> 0.1, cited to `starte.f:189` |

So the fixture is the pre-audit original (`PROVENANCE.json` source `../examples_ng-prod`), and every recorded frontier from issue-015 onward was produced on the edited deck.

## Gate relevance (a finding, not a verdict)

- Gate 1 input equivalence has to state which deck is the release deck and justify both edits. The issue-007 edit is oracle-cited. The issue-015 edit is a solver-ceiling configuration change on a contract-protected input ("Preserve inputs"), made to clear a frontier. It is not a translation fix, and it needs either an explicit authorization record or a science-policy decision.
- The fixture's `PROVENANCE.json` and the required deck now disagree. Anything that treats the fixture as "the Ottawa inputs" is testing a different configuration from production.
- The original deck's frontier is 3,161 accepted hours, failing at hour 3,162 on soil water. That is different from the edited deck's nitrogen-closure failure at 3,276. It is consistent with issue-015's claim that the ceiling change is load-bearing, but here it is one measurement, not a mechanism.

Queued, not acted on: reconcile the fixture/prod-deck divergence and check for an authorization record of `9253d3b`'s deck edit.
