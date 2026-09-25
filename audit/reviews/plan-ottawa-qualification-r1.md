# Ottawa execution-plan review — R1

Reviewed against the source spec, with permitted read-only spot-checks. D1–D8 are accepted. No commands, builds, or tests were run.

## BLOCKER

1. **§4 P2.4/P3 — Coverage is mistaken for scientific verification.** `gcov` does not automatically provide exact logical-statement coverage; optimized attribution and continuations need reconciliation. Auditing executed-but-untraced statements leaves mapped incorrect translations untouched. `tracecov.py:300–303` says mapping does not establish correctness. **Fix:** validate compiler-to-statement mapping; audit every Ottawa-relevant pathway, binding, initialization, coupling, and Zig-only replacement with semantic evidence and independent review. Resolve ambiguous coverage and approve exclusions explicitly.

2. **§4 P4.3–5 — Replay can promote contaminated or stale state.** “Nearest daily checkpoint” can follow a survey breach or precede changes affecting its entire trajectory. A clean window cannot revalidate that prefix. `conservation_survey.zig:15–22` labels downstream results contaminated. **Fix:** bind checkpoints/frontiers to source, deck, configuration, schema, and accepted prefix; separate diagnostic checkpoints. Revalidate from the earliest affected point, including hour zero when necessary. Require strict local → extended → frontier replay before promotion (spec §§22–23/32).

3. **§4 P2/P4; §5 — Full runs precede integration readiness.** P2 budgets an unexplained full Zig “dump self-check”; P4 starts with a full survey, while its G2 gate is assessed only afterward. This reverses spec §19’s readiness gate and replaces serial failure runs with potentially unlimited survey runs. **Fix:** make P2 checks bounded; move G2 initialization, coupling, output, solver, safety, conservation, and short-replay checks before P4. Bound campaign count, elapsed hours, and repeated signatures; require extended replay success before another full campaign.

## MAJOR

4. **§4 P0/P2/P3 — Baseline precedes deck adjudication.** Timing, dumps, and coverage precede D6’s accepted deck/ceilings; reversal invalidates expensive evidence. **Fix:** discover Git state and preserve dirty work rather than assuming `main` stays at `fd07795`; adjudicate D6 and establish equivalent inputs before reference runs, or mark evidence provisional and budget replacement.

5. **§4 P2.1/3/7 — Oracle and restart checks are underspecified.** A curated f64 vector cannot establish complete restart equivalence, including counters, lagged state, output accumulators, and discrete identities. `manifest.zig:29–38` includes execution/scenario/scene counters; `:56–63` binds checkpoints to an output tree. `--restart <day>` is ambiguous across repeats. **Fix:** define composite time keys, units, shapes, integer identities, sampling boundary, and material-state inventory. Add isolated output-tree resume handling; compare all material persistent state and output continuity across day/year/scene boundaries, with corruption/missing-state negative tests.

6. **§4 P5–P7 — Qualification lacks objectively complete evidence.** “Completes,” “balances,” and “outputs pass” lack mandatory inventories and validators. Existing `outcompare.py` disclaims completion proof; `compare_outputs.py` accepts normalized data, not arbitrary raw files. **Fix:** implement/test all required raw adapters, expected horizon and key inventories, missing/duplicate/nonfinite rejection, event/seasonal/cumulative rules, and independent local/global balance checks including active salts. Require sentinel activity/positive controls; zero recorded breaches alone can pass an unwired instrument (`conservation_survey.zig:63–69`).

7. **§4 P6/P7; §5 — D4 cannot pass as budgeted.** Only one uninstrumented baseline timing is scheduled before P6 demands its median; even P7 adds only one. Instrumented/gcov runs are not equivalent timing repeats. P6 depends on future P7 acceptance, while performance patches can invalidate P5 evidence. **Fix:** freeze one integrated candidate before final qualification, restart, and three-per-side benchmark repeats; specify warmup, equal cores/outputs/checkpoint policy, quiet machine, and spread. Reuse eligible runs explicitly and serialize expensive jobs despite early profiling permission.

8. **§2/§4 P1 — Workflow migration is incomplete.** Retiring Pi and replacing the handoff leaves existing AGENTS/skills/hooks pointing at the old protocol. One happy-path/killed-pane test does not establish safe dispatch or review binding. **Fix:** inventory and migrate these entry points atomically; test stale results, duplicate delivery, permission blocks, child-process cleanup, concurrent dispatch, and source changes after review. Preserve targeted independent source/raw-evidence access for SAGE (spec §8).

9. **§0/§4 P0.3/G0 — Claimed facts need correction.** Re-running `tracecov.py` reports stale hashes; it does not clear them. `check_gate.py G0` is invalid: the CLI requires `--gate <JSON>`. “Exactly one defect per run” confuses the first fatal event with root causes. **Fix:** re-review changed mappings before refreshing hashes; register actual commands and Ottawa gate schemas; label unsupported historical statistics provisional.

## MINOR

10. **§2/§6/§8 — Cost controls are incomplete.** Most roles lack token/time budgets; mandatory SAGE reviews may exceed its routing target. Checkpoint storage is unbudgeted. **Fix:** assign ceilings and escalation, measure test costs, budget storage preserving cited evidence, and report cost per verified advancement.

REVISE
