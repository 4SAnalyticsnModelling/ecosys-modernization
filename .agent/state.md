# Mission State — ecosys-ng Ottawa (single autonomous agent)

<!-- runner:begin -->
## Cycle 00002 · PLANNING · 2026-10-15T10:25:44Z
- Actor: single autonomous agent (any harness/model). Verification: gates G1-G9 (Zig 0.17.x build, repo-contained work) + read-only sub-agents.
- Target: Did Zig 0.17 move any production number? One bounded strict ReleaseFast run on the Ottawa deck, compared row-by-row against the recorded legacy oracle for the same hours, every difference explained by exact arithmetic or diagnosed to file:line (no tolerance loosened, no bound moved).
- Gates: none recorded
- Sync: unknown (push every completed cycle to origin/main)
- Next target: Did Zig 0.17 move any production number? One bounded strict ReleaseFast run on the Ottawa deck, compared row-by-row against the recorded oracle for those hours (cycle_00001.md section 6).
<!-- runner:end -->

Updated 2026-10-09 (mandates added); workflow revised to a single agent on 2026-10-08. Plan: Complete
30-Year Ottawa Run with Zero Science Gap.

- **0.17 diagnostic divergence, resolved as far as this repository allows (2026-10-15, cycle 00002)**: ReleaseSafe ==
  ReleaseFast bit-identical (0 differing of 382,178 cells over 3,338 h); the deck's `f6` iteration ceiling is **inert for
  this deck** (`core/iteration_control.zig:96,119-141`: every ceiling is `min(hard, X<=100)`; `NPH=4, NPG=1`), proven by
  staging the baseline blob `9ec1bf4e` (f6=200) under the same binary — outputs **bit-identical** (388,086 cells,
  0 differing) and both markers unchanged (aqueous 1,237 from d57; probe onset d113). So neither optimisation level nor
  the iteration ceiling explains the diagnostics. The earliest marker is the macropore aqueous extensive transport
  fallback (`aqueous_extensive_transport.zig:455`): **1,237 hits from d57** (reason iteration-limit @ iteration=100) vs
  **2 hits (d85, iter 28-30)** in the 0.16 baseline — the same 100-iteration ceiling, now exceeded. Every `aq=2` log in
  the repo is Windows/0.16 (`cwd: D:\`), every `aq=1,237` log macOS/0.17, 735 commits apart and unbuildable here
  without installing Zig 0.16, so host-ISA vs code remains unseparated by bisection; Debug-vs-ReleaseFast sensitivity on
  this host (`max_rel 3.15e-8` by day 11) shows a 1-ulp cross-ISA difference reaches that regime before d57, so
  diagnostic counts are not a parity oracle. Details: `audit/issues/issue-109-*.md`.
- **G2 is a reproduced FAIL — issue-110, fix pending**: `plant.lifecycle.reproduction.test.reproduction worker scratch is
  bitwise equivalent under disjoint grid concurrency` fails ~25% under CPU load (2/12 + 1/11 + 1 filter run;
  `audit/runs/zig017-repro-reproduction-test-20261015-1/`). Root cause: three growth operators memcpy the **whole**
  branch-indexed state array in and out (`potential_seed_site_accumulation.zig:36,58`, `final_grain_number.zig:46,77`,
  `maximum_individual_grain_size.zig:33,54`), so one worker's copy-in reverts another worker's cells (observed
  `branch_potential_seed_site_count` `[6,6]` -> `[6,0]`). Latent since `514dd68`; latent for the one-cell Ottawa deck.
  Six-line fix + acceptance plan in **issue-110** (not applied: session ended).
- **G1 recording gap**: build/test receipts contain no `zig_version` and no `0.17.0` string (toolchain is genuinely
  0.17.0 by `zig version`, `build.zig.zon`, preflight). Next cycle: put `zig version` in the receipt argv.

## Mandates added 2026-10-09 (read before any build)
- **Zig 0.17.x builds `ecosys-ng`; Zig 0.16 is retired** (protocol §8, gate G1). Machine check
  `uv run ecosys-audit/scripts/preflight.py` → currently `zig-version PASS (0.17.0 installed)` but
  `build-zon-pin PASS`: `ecosys-ng/build.zig.zon` now declares `minimum_zig_version = "0.17.0"` (2026-10-12), so the
  tree can no longer be built by a retired 0.16. **The compile migration IS executed and green (cycle 00001,
  2026-10-15)**: `build.zig` lost the `std.Build.args` passthrough, the `**` repeat codemod (1197 repeats / 188 files)
  plus `std.meta.fields` → `ti_compat.fieldViews` and `zig fmt`'s own `@intFromEnum` → `@backingInt` (1563) /
  `@enumFromInt` → `@fromBackingInt` (165) rewrites landed. Debug 28.1 s / ReleaseSafe 163.6 s / ReleaseFast 168.4 s,
  all exit 0, `audit/runs/zig017-{debug,releasesafe,releasefast}-20261015-1`; `zig build test` = **4518/4520 passed,
  1 env-gated skip, 1 crash (tracked issue-106)** and **zero assertion failures**,
  `audit/runs/zig017-test-20261014-4`. What is still NOT done is the numeric side: **no bounded run has re-derived
  parity on 0.17 yet** (G3/G4/G5 = NA), and 168 files still carry 0.16 `zig fmt` formatting. Old 0.16 receipts
  (`audit/runs/zig017-debug-migration-20261008*`) stay as dated history. Work order: `.agent/migrations/zig-0.17.md`;
  pin: `.agent/toolchain.json`; cycle record: `.agent/cycles/cycle_00001.md`.
- **All work stays inside this repository** (protocol §8a, gate G9): caches pinned to `.tmp/`, `.cache/`,
  `.uv-cache/`, `ecosys-ng/.zig-cache*/`; evidence under `audit/runs/`. Nothing needed by a later cycle may live
  outside the repo; the recorded `C:\ecosys-build\...` paths below are the retired Windows host, not a target.
- **Test baseline 2026-10-09**: `uv run python -m pytest ecosys-audit/tests` gives **50 failures on a clean `HEAD`
  worktree** and **48 after this setup round** (the hook fixes two). The remainder are pre-existing, mostly
  host/evidence-dependent (Windows paths, absent local artefacts) — not science regressions and not blockers for
  opening a cycle, but never let the number grow: record the count in every cycle that touches tooling.

## Cycle 00002 findings (2026-10-15) — what a real 0.17 run proved, and what it cannot prove here
- **The deck runs clean on this host under 0.17.** Strict ReleaseFast, staged deck `ecf5e61ab453288b1763f81f841729bee34e8426`:
  hour 3,419 in 3,600 s, **142/142 daily conservation acceptances, zero rejections**, no model error (`audit/runs/ottawa/zig017-frontier-20261015-1`).
- **The recorded frontier failure at hour 3,289 did not reproduce** on the current tree+deck (issue-108 Ca/Na/K layer-2
  excess `+9.19e-8 / +2.9e-10 / +1.5e-10`, `audit/runs/run-038-*.md:28`): day 138 closes normally. `.agent/frontier.json`
  is deliberately **unchanged** — a wall-clock-stopped bounded run is not a campaign and cannot promote. The
  non-reproduction is not 0.17-attributable: the deck's `runtime` f6 (200 -> 100, `8a4a565`) and three weeks of source
  changes differ from the 09-24 baseline as well.
- **Same-toolchain parity is bit-exact where it should be**: ReleaseSafe == ReleaseFast over 2,400 h and a rebuilt
  ReleaseFast == the original over 2,908 h, 17/17 output streams, **0 differing cells** (`ecosys-audit/scripts/zig_run_diff.py`,
  reports under `audit/runs/ottawa/zig017-*-20261015-1/zigdiff.json`). Debug vs ReleaseFast is *not* comparable
  digit-for-digit (75.2% of cells differ, worst rel `6.831e-11`, first difference day 1 h23) — **compare receipts only
  within the same build mode.**
- **0.16-vs-0.17 digit parity is undecidable from this repository**: 13 of ~413 `audit/runs/*` dirs are model runs and
  all are 0.16/ReleaseSafe/Windows diagnostics; no 0.16 ReleaseFast log and no legacy output stream survived the
  Windows hosts (`D:\ecosys-evidence`, `C:\ecosys-build`). Only behavioural parity + self-consistency is decidable here.
- **New issue**: `audit/issues/issue-109-*.md` — the `implausible surface conductive flux` probe (`temperature_solver.zig:778-798`)
  fires 1,008 times by hour 3,288 on 0.17 vs 16 in the 0.16 log (first hit hour ~2,712). Also 32 `root salt implicit
  solve failed` fallbacks at hours 3,384/3,408 (baseline never got that far; 0.16-era same event was hour 3,562, `d38218a`).
- **Throughput on this host (ReleaseFast, strict, 1 cell)**: 194 h/min in winter, but only **57 h/min** averaged to hour
  3,419 because spring/summer days cost 19-47 s in the final hour alone. Budget any campaign from the second number:
  262,920 h is not a single-run target on this machine.
- **Tooling test baseline 2026-10-15**: `uv run --project ecosys-audit python -m pytest ecosys-audit/tests -q` =
  **48 failed, 104 passed, 1 skipped** — the failure count is exactly the recorded post-setup baseline (48); the
  +7 passes are `ecosys-audit/tests/test_zig_run_diff.py`.

## Actor (from 2026-10-08): one autonomous agent
- **One agent** owns everything — planning, Zig implementation, builds, tests, runs, diagnosis, decisions, the
  ledgers (this file included) and the final scientific review of each cycle against gates G1–G9. Any harness or
  model may pick it up; no agent name is required. Protocol: `.agent/protocol.md`.
- **Verification is objective, not interpersonal**: gates + a fresh-context read-only verifier sub-agent (G7) for
  any science / solver / DEV / architecture change (`.agent/briefs/verifier.md`). The retired worker/judge pair
  (DEEPSEEK worker, CLAUDE judge with final rulings) and the earlier 4-agent swarm are history only.
- **Every completed cycle is committed and pushed to GitHub `main`** (`./sync-main.sh push`), so no work is lost.
- Historical record: `.agent/adversarial/round_*.md` (r1–r57) — read it for the science, not for authority.
  Last rounds: r49 DEV-020 confirmed, r50 DEV-021 confirmed, r51 band sliver legacy gates, r52 challenge of
  7ebb94a, r57 DEV-003.

## LIVE: r00019-strict (fresh hour-0 run, resumed from its 4800 checkpoint with 7ebb94a)
- Past 1998 d209 h20 (hour 5012) after DEV-021 (9a363ea, molarity guards skip <1e-12 zones) and 7ebb94a (exact
  pre-HOUR1 band fraction; the FVL reconstruction cancelled for a 1e-14 band sliver, losing 0.5% of its mass).
- Journals 4801-5011 written by the pre-fix binary were moved to C:\ecosys-build\runs\r00019-journals-4801-5011-
  prefix-fix (1-ulp output differences made replay fail; resume = crash-before-link continuation).
- Throughput ~190 h/min; hour 7327 at 00:25.
- Hour 8470 (1998 d353 h22): in-loop DEV-014 publish with a rigid-pore displacement left layer 0 2.06e-3 MJ
  unclosed -> DEV-014 made terminal-only (ladder closes 8470). Hour 8479 (d354 h07): frozen topsoil
  (269.4 K, psi ~ -4.6 MPa) stalls at 1.6e-7 of capacity at every substep count -> bound 1e-8 -> 1e-6, phase
  stagnation made terminal-eligible, terminal ceiling publishes the explicit endpoint (in test).
- COMPARABILITY (r53/r54/r55): ng topsoil theta +50%, runoff +57%, N2O 16x, Reco +61% vs legacy. Root cause
  verified: the deck's zero inflection head selected the unanchored Carsel-Parrish MvG (theta 0.411 at FC
  vs deck 0.28; K 10-20x below HCND). STAGE A (uncommitted, backup C:\ecosys-build\stageA-fcwp-anchored-
  mvg.patch): zero inflection -> Carsel inflection as third anchor of the FC/WP fit (theta exact at FC/WP,
  K within ~2x of HCND 0.28-0.45). Needs a FRESH run: r00020-strict deck prepared (restart NO).
- Build/deploy: C:\ecosys-build\build_deploy.ps1 -Run <run> -Tag <tag> [-WithoutStageA] [-MoveJournalsFrom N].

## Frontier (strict runs on C:\ecosys-build\runs, deck blob ecf5e61a, ReleaseSafe)
- r00012 (470810a) + checkpoint replays with later fixes reached hour 3607 (d151).
- r00014 (6f50e81) fresh hour-0: failed hour 2786 (1998 d117 h02) surface litter/pond temperature solve pinned at
  273.14999 K (ponded water now stays on the surface after the NN=3 gate).
- r00015 (84c09d5, SOLUTE entry reset) crawled post-liming; stopped. Entry reset and hydroxyl site owner reverted.
- r00017 (df86724) fresh hour-0 started 19:02: passed 2786 (freeze clamp), 3295 (DEV-013), 3608 (ZEROS2 gate),
  3917, 4037; hour 4128 at 19:42 (new record; previous best 4036). One DEV-011 publication at d119 (quality 516).
- r00017 checkpoint replays (3edb1f2..): 4142/5617 fixed; 6456 DEV-014 (explicit WATSUB endpoint for a bounded stalled
  phase iterate); 6457 DEV-015 (terminal stiff solute image); 6458 DEV-014 at ceiling (terminal) + layer O2
  storage-update gamma_{4n} provenance (layer 11 O2 residual 1.3e-14 g on 4.02 g).
- d105 lime (360 g Ca m-2 CaCO3 broadcast) makes layer-0 pH 8-9.8 plausibly (DEEPSEEK r29): SOLUTE stiffness.
- Throughput ~150 ms/h at steady state; spring thaw/tillage hours slower.
- verified_frontier = 0 (no single-binding strict campaign has yet run to a stopping point with every fix).

## Fixed in the pre-solo session (commits; the old box could not push — 403)
8a4a565 · 2edcbf2 · f0389ce · 56dfca4 · d38218a · e2e4679 · 9416f92 · 1b098e1 · 7e04f9f · a83519a (see git log) ·
627634a freeze-thaw drives no soil relayering transfer · 470810a SOC restore uses freeze-free DLYR, DVOLI =
VOLI+VOLIH, NN=3 pond→soil transfer gated by NU>NUI, DEV-012 explicit boundary gas pressure · 215ad41 DEV-013
zone-capped topsoil uptake · 6f50e81 ZEROS2 gate on macropore water-table discharge · 84c09d5 SOLUTE entry RHHX.

## Proposed deviations (audit/intentional-deviations.md)
DEV-009 bounded water stagnation publication; DEV-010 legacy ZEROC floors; DEV-011 terminal SOLUTE best-bounded
(evidence insufficient; fired post-tillage with quality 161 before 84c09d5); DEV-012 explicit boundary gas pressure;
DEV-013 zone-capped topsoil microbial uptake; DEV-014 bounded phase stagnation/ceiling publication; DEV-015 terminal
stiff solute image. Terminal ladder attempt enables DEV-011/014-ceiling/015 together.

## Fresh strict run r00018 (from hour 0, all fixes incl. PSISA drainage + FOMA fallbacks)
- passed 2914 (DEV-019 soil), reaching 3254 (d136 tillage): surface Na/K vanish unbooked (trace in progress).
- COMPARABILITY (DEEPSEEK r36-r42): drainage 45 vs 384 mm (PSISA gate fixed; effect small so far),
  April topsoil θ 0.42 vs 0.31, SWE DOY10 89.5 vs 14.9 mm (legacy loses snow in Jan 1-10; r42 open),
  frozen-topsoil frost-heave runoff absent in ng.

## Open / known simplifications
- COMPARABILITY: 1998 d200/d210 noon cell fluxes ng vs legacy: CH4 -1.15 vs -0.21 umol m-2 s-1, O2 exchange 0.12 vs
  3.23 (NEE -1.30 vs -0.55). Maize sown d138 never emerges in BOTH (legacy pop file zero) - deck-consistent.
- Hour 6852 (d286 JCUT termination of unemerged maize): ~4.6e-5 g root C leaves the plant without litter booking.
- Hour 2786 surface pond freeze discontinuity (energy-limit TFREEZ vs Dall'Amico melt point?) — r26.
- Frost heave dilutes intensive mol/Mg soil carriers (legacy pins DLYR via DDLYRY; ng keeps elastic geometry).
- FLQRS ignores FSNX (partial snow cover). Rain solutes not rerouted with overflow water (legacy-consistent).
- DEEPSEEK r12: H3PO4 dissociation Jacobian ~1/[H+]^2 at high pH (not currently blocking).
- Push: works from this macOS clone (HTTPS + macOS Keychain; see `SYNC-LOCAL.md`). **Push-per-cycle is mandatory**
  (`.agent/protocol.md` §7), so `origin/main` always carries the latest verified work. The old 403 was the retired
  Windows account.
- Richards→enthalpy rebase applies internal inflow heat only in the later spatial solve.
- Many failure-only TEMP_DIAGNOSTIC logs to strip before release.
