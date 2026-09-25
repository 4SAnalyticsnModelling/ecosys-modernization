# Current ecosys audit checkpoint

Operational checkpoint, updated 2026-09-24 at closure of task `20260924-132727-40bac6ee` (issue-108 carbon-sign FIX; Pi PASS, `audit/reviews/20260924-132727-40bac6ee-r1.json`). Previous task `20260924-122218-1d2477d6` CLOSED, Pi PASS; committed `00f5df3`.

**Autonomy mode: lead-driven.** The lead runs `begin/seal`, then `herdr_cycle.py peer`, `checkpoint/close`, then `herdr_cycle.py next`. Do not also run `ensure`. See `ecosys-audit/WORKFLOW.md` "Two autonomy modes". The user asked (2026-09-23) for Pi to collaborate on every task until project end, via this reviewer cycle. Older claims remain evidence to verify, not fresh passes. Commits are local only: the user said never push, which conflicts with "keep online in sync" (flagged to the user).

## Candidate

Outer Git HEAD `00f5df3`, plus this task's edit to `soil/diagnostics/daily_gas_flux.zig`. TEMP probes are logging only (target hour 3,289). Obtain source/input hashes before any gate claim. Never commit `audit/runs/*-deck/`.

## Gates

No gate is promoted. Release remains NOT_ASSESSED / not production-ready. Criteria: `audit/release/v1-release-contract-and-gate-matrix-transcribed-2026-09-23.md`. Horizon 262,920 accepted hours / 30 passes.

**Frontier (run-038, required deck): 3,288 accepted, failing on attempted hour 3,289** on Ca +9.19e-8, Na +2.9e-10, K +1.5e-10 (all layer 2). Carbon closes after the issue-108 sign fix. The release transcription still says 3,274/3,275.

**Deck finding (run-027):** the frontier depends on two audit-era edits to the protected deck: `9253d3b` (runtime ceiling 100->200, issue-015) and `5add7de` (oracle-cited `starte.f:189`). The PROVENANCE-exact fixture `ecosys-ng/src/validation/testdata/ottawa/` stops at hour 3,162 (`SoilWaterSolverStagnated`). Gate 1 must name the release deck and justify both edits; the 100->200 edit may need a user science-policy decision.

Engineering validation needs four roots x three modes plus cross-platform compiles; every test figure here is one root, one mode. **Second test root (`src/ecosys_ng.zig`): compiles as of run-034; 107/115 OK, test 71 FAIL (issue-106), test 109 hangs (issue-107), 110-115 not run. NOT passing.** Argv: registry `commands.zig_executable_root_tests`.

## Active work

Lead: Claude `editor` (w3:p2). Pi `reviewer` (w3:p4) writes only under `audit/reviews/`.

- **issue-100** (hour-3,276 N closure): **resolved in production by two legacy-cited fixes**. Band activation now redistributes all `hour1.f:322-334` (NH4: XN4/XNB, ZNH4S/B, ZNH3S/B) and `:376-384` (NO3: ZNO3S/B, ZNO2S/B) state onto the new zone fractions. ISSUE-090 had ported only the geometry. Chain of evidence: run-028 (the ledger is exact) -> analysis decomposition -> run-029 (exchange re-base 99.2%) -> run-030 (exchange fix, residual -5.19e-4) -> run-031 (aqueous fix, hour 3,276 accepted). Suite 4385/1/0. The pre-registered run-031 prediction that 3,276 would still fail was REFUTED favorably. Records: `audit/runs/run-028*` to `run-031*`.
  - Open: the NITRO/uptake ±0.00933 g N transient (cancels within the hour); TEMP_DIAGNOSTIC probe cleanup.
- **issue-103**: FIXED in production (run-033). The duplicate chemistry-stage NO3/PO4 band growth was removed; prepareHour is the single `hour1.f:4888-5155` growth. Module suite 4385/1/0; ISSUE-103 structural test 4/4 (exe root, filtered). Record: `audit/runs/run-033-issue-103-duplicate-band-growth-removed-frontier-moves-to-3289-2026-09-24.md`.
- **issue-105**: FIXED (run-036). Root geometry is now defined for every layer per `uptake.f:526-538`. Suite 4387/1/0.
- **issue-108 (frontier, hour 3,289)**: carbon FIXED (run-038). `daily_gas_flux.combinedHourIncrement` subtracted atmosphere->root exchange; legacy adds it (`redist.f:6530,6568,6573-6574`). Suite 4387/1/0. **Open: Ca/Na/K layer-2 positive residuals** (unchanged by the fix). Records: run-037, run-038, `audit/issues/issue-108-*.md`.
- **issue-104**: compile defect FIXED (run-034); the root still fails via issue-106/107. Record: `audit/runs/run-034-issue-104-executable-test-root-compiles-107-of-115-pass-2026-09-24.md`.
- **issue-106**: test 71 expects ladder {1,20,32,64} vs {4,...} after `99234f1` (wthr.f NFH=4). Adjudicate from legacy; do not relax.
- **issue-107**: test 109 `OutputTree` spins (non-reentrant `lockActiveRunLog`, `run_support.zig:322-331`); isolate with a filter.
- **issue-099**: phosphate activation still open (PO4 band activation is not in `activateBandFromApplication`; compare `hour1.f:390+`).
- **issue-093**: litter-carbon composition. **issue-097**: reference-doc import unresolved (do not copy 1,043 files).
- **issue-101/102**: CLOSED (Pi PASS).
- Queued: fixture/prod-deck divergence and an authorization record for the `9253d3b` deck edit.

Rejected approaches: inferring execution order from log position; treating externally killed processes as regressions; compiling during a D: fault; unit checks as production evidence; reading probes gated on an accepted hour as failing-hour evidence; staging runs from the testdata fixture; a relative exe path under `run_logged.py` (use absolute); an existing `--out` directory (`run_logged.py` refuses it with WinError 183).

## Next action

issue-108 cations: Ca/Na/K in layer 2 gain storage without booking once layer-2 root geometry exists. Probe the layer-2 cation census terms and the root salt exchange (`plant_root_salt_exchange.zig`, `roots.salt_uptake_mol_per_h`, root salt content) around the root uptake calls at hour 3,289 in ONE run. Legacy: uptake.f salt uptake. Queue: issue-107, issue-106.

Use `audit/manifest/command_registry.json` for argv and `run_logged.py` for logs. Time a D: read before and after long jobs (6 ms healthy 2026-09-24). A task PASS is not a release PASS.

## Recovery

No task-owned processes (run-031 exited). No detached controller (lead-driven). Pi `audit/reviews/carry-forward.md`: no pending assignments. History: `audit/history/INDEX.md`. Do not load the archive on startup.
