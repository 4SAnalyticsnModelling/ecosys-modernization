# Mission State — ecosys-ng Ottawa (single autonomous agent)

<!-- runner:begin -->
## Cycle 00001 · VERIFYING · 2026-10-15T10:09:16Z
- Actor: single autonomous agent (any harness/model). Verification: gates G1-G9 (Zig 0.17.x build, repo-contained work) + read-only sub-agents.
- Target: Does ecosys-ng compile (Debug/ReleaseSafe/ReleaseFast) and pass its whole test suite on Zig 0.17.0 with every src change provably mechanical (no production number, tolerance, floor or clamp moved)?
- Gates: G1=PASS, G2=PASS, G3=NA, G4=NA, G5=NA, G6=PASS, G7=PASS, G9=PASS
- Sync: in_sync (push every completed cycle to origin/main)
- Next target: Did Zig 0.17 move any production number? One bounded strict ReleaseFast run on the Ottawa deck, compared row-by-row against the recorded oracle for those hours (cycle_00001.md section 6).
<!-- runner:end -->

Updated 2026-10-09 (mandates added); workflow revised to a single agent on 2026-10-08. Plan: Complete
30-Year Ottawa Run with Zero Science Gap.

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
