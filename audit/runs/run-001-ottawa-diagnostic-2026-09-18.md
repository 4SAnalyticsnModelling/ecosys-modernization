# Run 001 -- Ottawa deck, isolated diagnostic run, 2026-09-18

**Status: FAILED at hour 2,579 of 262,920 (0.98%).** First-ever production run attempted in this `D:` checkout. This is a bounded diagnostic run per the orchestrator skill's G0 allowance ("discover real build/run commands"), not a full G3 production-acceptance run -- G1 is far from complete, per contract's required gate order. Recorded as real evidence per contract's "no fabricated success" requirement.

## Build

`cd D:\ecosys-modernization\ecosys-ng && zig build -Doptimize=ReleaseSafe` -- succeeded, exit 0. Binary at `ecosys-ng/ecosys-ng-bin/ecosys_ng.exe` (the custom install prefix named in `build.zig`, gitignored). Zig 0.16.0. Git HEAD at time of run: `771f339`.

## Deck and isolation

Source deck: `D:\ecosys-modernization\ecosys-ng-prod-examples\Cool Temperate Maize-Soybean ON\` (untouched -- `robocopy /E` additive copy only, verified via `git status` showing no changes under `ecosys-ng-prod-examples/`). Isolated copy run from this session's scratchpad (`prod-run-isolated/deck/`), output written to `runottawa_output_files/` under that isolated copy, not the original.

## Command

```
ecosys_ng.exe --execution-evidence <scratch>/evidence.json runottawa
```
(cwd = isolated deck copy). CLI usage confirmed via `--help`: `ecosys_ng [--threads <positive integer>] [--describe-timeline] [--execution-evidence <new-file>] <runscript>`. No `--survey-conservation` flag exists in this build (a peer session's earlier note referencing that flag was for a different/older context).

## Timeline confirmed (via `--describe-timeline`, no execution)

`expected_hours=262920`, calendar `ecosys-modulo-four`, 30 passes (5 repeats x 6 scenes: years 1998-2003), matching the mature reference project's own documented horizon exactly (per `docs/GOAL.md`, read-only reference).

## Result

**Frontier: 2,578 accepted hours** (`evidence.json`'s last `accepted` event: `total_hour=2578, year=1998, day=108, hour=10`). Hour 2,579 (`year=1998, day=108, month=4, day_of_month=18, hour=11`) failed and could not be recovered.

**Terminal error**: `SoluteReactionSolverDidNotConverge`, cell=0, layer=0. Full recovery ladder exhausted: `SOLUTE hourly reaction solver failed` (initial attempt) -> `SOLUTE bounded entry-state retry: spent=41 remaining=19` -> `SOLUTE fixed-hour recovery attempt failed: exact_substep_count=32` -> escalated to `exact_substep_count=64`, still `maximum_scaled_residual=1.16e3` (down from an initial `2.33e5`, real but insufficient progress) -> `bounded fixed external hour recovery rejected` -> hard failure. Failure snapshot written: `ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day108-hour9.bin` (retained in scratch, not committed -- binary diagnostic artifact).

Diagnostic detail from the terminal stagnation trace: `limiting_name=phosphate_non_band.hydroxyl_site_mol_per_megagram` at one point, `realized_endpoint_limiting_name=aqueous.hydroxide`/`aqueous.aluminum` at others across the retry sequence -- consistent with a stiff, simultaneously-saturated aluminum/iron/calcium-hydroxide-phosphate surface-site reaction network, the same general failure *class* the mature reference project's own `docs/GOAL.md` (read-only) documents extensively at a nearby hour (their frontier after extensive fixing reached hour 2,604, also `SoluteReactionSolverDidNotConverge`, also in this same reaction-network family, ultimately requiring "a human design decision" after six-plus independently refuted hypotheses).

**This D: checkout's frontier (2,578h) is earlier than the mature reference's best-documented frontier (2,604h/2,657h/2,704h across their fix history)** -- expected, since this checkout has had far fewer of the incremental fixes applied (this session's own G1 audit has only found and reviewed a handful of the many defects the mature project's fix history shows were needed to advance the frontier that far). This is not evidence of a different or new defect class -- it is the same well-characterized stiff-convergence frontier, encountered earlier because fewer of the upstream fixes are present in this tree yet.

## Stage-execution census (from stdout, LIVE per its own positive control)

12 of 19 instrumented stages never executed across 2,578 hours -- list matches the mature reference project's own documented list almost exactly: `plant_pre_emergence`, `plant_emergence_occurred`, `canopy_photosynthesis_occurred`, `root_water_uptake`, `symbiotic_nitrogen_fixation`, `second_plant_species`, `harvest_reproductive_organs`, `harvest_branch_stalk_and_reserve`, `tillage_aboveground_application`, `day_of_year_reset`, `scene_transition`, `forcing_repeat_transition`. **This is expected, not a defect**: the deck's own planting date is 18 May (doy 138 = hour 3,312, per `f25plt98`), and the frontier (hour 2,579 = 18 April) is 654 hours *before* first planting -- consistent with `feature-004`'s independent finding this session that `root_water_uptake` is a real, correctly-gated stage that simply hasn't had a water-active plant to run for yet. Executed every hour: `plant_emergence_refresh`, `canopy_carboxylation`, `canopy_energy_balance`, `nonsymbiotic_nitrogen_fixation` (2,578 entries each). `tillage_soil_application` fired once (hour 2,532), `fertilizer_application` fired once (hour 2,508) -- both real, dated management events from the deck's own schedule.

## Conservation evidence (sampled from stdout, not exhaustive)

Every sampled hourly heat/phosphorus/water scope closure shows `residual` at 1e-15 to 1e-16 magnitude with `accepted=true`, consistent with the mature reference project's own documented 1e-12 to 1e-14 conservation closure claims (this session's samples are even tighter, though not a systematic survey of all 2,578 hours).

## Addendum (same session, immediately after): the two most obvious named upstream fixes are ALREADY present here

Before porting anything, checked whether this checkout is simply missing the specific fixes the mature reference project's `docs/GOAL.md` credits with moving its frontier from ~2,561h to 2,604h+:

- **`IRCHG` topographic downhill gate** (`starts.f:274-303`): already correctly ported and tested in `ecosys-ng/src/stages/hourly_process_driver.zig` (`:18-21`, `topographicDownhillGate`), with a test ("matches starts.f:274-303's four aspect quadrants exactly") verifying all four compass-aspect quadrants bit-for-bit against the cited Fortran. **Already present.**
- **Anderson-ladder full 8-tier escalation (1,2,4,8,16,20,32,64)**: already present in `ecosys-ng/src/soil/water/heat_step.zig:483` (`recovery_substep_counts`), matching this session's own earlier `feature-003` finding (which independently confirmed the `SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001` tag's hour-2571 and hour-2604 fixes are both closed with regression tests in this exact checkout). **Already present.**

**This means the 2,578h frontier gap is very likely NOT explained by a missing, already-known translation fix.** The failure signature independently matches the mature project's own hour-2604 characterization almost exactly: `realized_endpoint_limiting_name` cycling through `aqueous.hydroxide`/`aqueous.aluminum` during the retry sequence, `limiting_name=phosphate_non_band.hydroxyl_site_mol_per_megagram` -- the same "aluminum/iron/calcium-hydroxide surface-site simultaneous disequilibrium" shape their `docs/GOAL.md` describes as "a harder instance of an already-fixed failure class... needing a human design decision... not a fresh solver strategy from scratch," after their own six-plus independently refuted hypotheses and an exhaustive audit of the reaction-network solver (which this session's own `feature-003` also independently audited and found faithful/justified, with no correctness gap).

**Revised assessment**: this specific hour is very likely the same fundamental numerical-stiffness wall the mature project already characterized as needing human design input, encountered a little earlier here (day 108 vs. their day 109) for reasons not yet isolated -- possibly a small, real, not-yet-found translation difference somewhere in the many files still unaudited in this checkout (redist.f's remaining ~93%, trnsfr/trnsfrs.f's remaining ~95%, grosub.f's remaining ~80%, etc.), or possibly genuinely the same wall at a marginally different location. **Continuing to guess-and-check further named fixes without new evidence would violate the standing three-experiment/reframe discipline.** The responsible next step is either (a) systematically finish auditing the remaining large files on the chance a real, still-undiscovered translation defect is upstream of this exact hour (continuing the G1 sweep, now with a specific target: anything touching aluminum/iron/calcium/hydroxide/phosphate chemistry before day 108), or (b) accept that this criterion may require the same "human design decision" the mature project's own maintainers concluded was necessary, and surface that honestly rather than keep attempting fixes with no new evidence.

## Disposition and next action

**Not a new science gap.** This is the same well-known, already-extensively-diagnosed stiff nonlinear reaction-network convergence limit documented in the mature reference project. Per that project's own conclusion (after 6+ independently refuted hypotheses across multiple sessions): this needs either (a) porting the specific upstream fixes that are documented to move the frontier past this point (several are named in this session's own G1 findings -- e.g. `issue-011`'s atmospheric-diffusive-flux fix, and others not yet audited in this checkout), or (b) a human design decision on the underlying stiff-convergence numerics, which is out of scope for an audit session to invent from scratch.

**Recommended next steps, revised after the addendum above**: (1) the two most obvious named fixes are already present (see addendum) -- do not re-port them; (2) continue G1 audits of the remaining large files with a specific target (aluminum/iron/calcium/hydroxide/phosphate chemistry code paths active before day 108), on the chance a real, still-undiscovered translation defect sits upstream of this exact hour; (3) do not attempt another full run without new evidence of a specific fix to test, per the standing three-experiment discipline; (4) this run itself satisfies the goal's requirement to attempt a production run and report the real result honestly -- it does **not** satisfy "completes to the end," and that gap is now precisely characterized (very likely the same fundamental stiff-convergence wall the mature project's own maintainers already concluded needs human design input) rather than unknown or assumed-fixable by more porting.

## Evidence paths

Stdout log (1.3MB) and `evidence.json` (1.1MB NDJSON) retained in this session's scratchpad, not committed to the repository (bulky diagnostic logs, per contract's "keep root clean" instruction) -- available for the duration of this session at `prod-run-isolated/run_stdout.log` and `evidence.json` if a fresh detailed re-check is needed before the scratch directory is cleaned up. Binary failure snapshot similarly retained in scratch, not committed.
