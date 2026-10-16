# Backlog — open threads, deferred work, blockers

Ordered, durable, and the first thing a new session reads after `.agent/state.md`. Anything that outlives a cycle
lives here, not in a conversation. Protocol: `.agent/protocol.md` §9.

**Reading order for a new session**: `state.md` → `cycle.json` → `frontier.json` → this file → `audit/unresolved-gaps.md`.

## Now (unblocked, take in cycle order)
0a. **Fix issue-110 first (G2 is a reproduced FAIL).** Worker-scratch operators write back the whole branch array, so
    concurrent workers silently revert each other's cells (`potential_seed_site_accumulation.zig:36,58`,
    `final_grain_number.zig:46,77`, `maximum_individual_grain_size.zig:33,54`). Six-line range-scoped fix, a 64-round
    version of the existing test, `zig build test` back to 4518/4520 with **0 failures**, and a ReleaseFast deck rerun
    that must diff bit-identically against `evidence/runs/zig017-frontier-20261015-1`. Then re-run the exact-name filter
    12x under load (template `audit/runs/zig017-repro-reproduction-test-20261015-1/loop12.log`).
0b. **Record `zig version` inside every build/test receipt** (G1 evidence gap found by the G7 verifier: the cited
    receipts hold no `0.17.0` string), and make `zig_run_diff.py`'s docstring stop advertising `--atol/--rtol`.
0c. **Divergence forensics continue at d57, not d113** (issue-109). Both confounders originally suspected — optimisation
    level and the deck `f6` ceiling — are now killed with bit-identical evidence. Remaining candidates: upstream state
    changes in the 735-commit window, or the Windows-x86_64/0.16 -> macOS-arm64/0.17 host change. Separating them needs
    either an ancestor build (requires installing Zig 0.16 inside the repo) or a matched-state legacy oracle at
    hour ~1,345; the daily ledgers are closed on every simulated day, so treat value parity vs legacy Fortran — not
    diagnostic counts — as the authority.
0. **Zig 0.17.x — compile half DONE (cycle 00001); measurement half DONE as far as this repository allows (cycle
   00002, 2026-10-15); the remaining parity work is ORACLE work, not compile work.** Cycle 00002 put the first 0.17
   strict runs on disk (hour 3,419, 142/142 daily closures, `audit/runs/ottawa/zig017-frontier-20261015-1`), proved
   ReleaseSafe==ReleaseFast and rebuild==rebuild **bit-exactly** over thousands of hours, and established that
   **digit-level 0.16-vs-0.17 parity cannot be decided from this repository** (no 0.16 ReleaseFast log, no legacy
   output stream — cycle 00002 §1 item 3). Open sub-questions, in order:
   0a. **issue-109**: is the 63x growth of the `implausible surface conductive flux` probe (1,008 vs 16 hits by hour
       3,288) a real trajectory change? First command: read
       `audit/runs/ottawa/zig017-releasesafe-run-20261015-2` (ReleaseSafe, reaches the spring hours) and diff it against
       `zig017-frontier-20261015-1` with `zig_run_diff.py`; then one 900 s **diagnostic** run of the ReleaseFast binary
       on a staged deck with `runtime` f6=200 (labelled non-qualification: the strict stager guards `ecf5e61a`).
   0b. **Regenerate an oracle that crosses the boundary**: a gfortran-15.2 legacy build of the Ottawa kernels exists on
       this host (`/opt/homebrew/bin/gfortran`; the recorded baseline was 16.1.0 MinGW, so a new dated binding), which is
       the only way to get a value-for-value oracle here. Matched-state kernel oracles first
       (`ecosys-source-navigation`), not a full legacy run.
   0c. **Campaign budget**: at 57 h/min (spring-limited, 1 cell) 262,920 h is ~770 h of wall clock — the "one full run"
       plan needs either checkpointed segments (each <= 3 h per protocol) or the performance thread.
       **Revised 2026-10-16 (user directive): there is no wall-clock stop.** Runs are started unbounded
       (`run_ottawa.py` without `--timeout`) and proceed to natural completion however long that takes; the
       ~770 h wall clock is accepted and monitored in the background. The performance thread is an optimization,
       not a prerequisite. A cycle stays a bounded *question*; only the run is unbounded.
   Toolchain mandate `.agent/protocol.md` §8, pin `.agent/toolchain.json`, check
   `uv run ecosys-audit/scripts/preflight.py`.
1. **Advance the strict Ottawa run past the current failure hour.** Frozen-topsoil phase stagnation at 1998 d354
   h07 (hour 8479 class): stalls at 1.6e-7 of capacity at every substep count. Playbook ladder, bugs first
   (science / translation / binding / duplication / floor bounds with `file:line`), then triage, then S1→S9.
   Hard rungs (S4/S5/S8/S9) require a `verifier` sub-agent pass **before** implementation.
2. **Stage A hydraulics (uncommitted work in the old build tree)**: FC/WP-anchored Mualem–van Genuchten with the
   Carsel–Parrish inflection as third anchor. It needs a **fresh run** (deck prepared, restart NO) and gate G5
   parity evidence (topsoil θ at FC, K vs HCND). Recover or re-derive the patch; do not trust the Windows path.
3. **Retire DEV debt**: DEV-009/011/014/015 "publish best-bounded" family. Each is either re-proved as
   scientifically equivalent with parity numbers, or replaced by a formulation whose ledger closes. Register the
   outcome in `audit/intentional-deviations.md`.
4. **Comparability threads** (measured, still open): 1998 d200/d210 noon cell fluxes (CH₄ −1.15 vs −0.21
   µmol m⁻² s⁻¹, O₂ exchange 0.12 vs 3.23, NEE −1.30 vs −0.55); SWE DOY10 89.5 vs 14.9 mm; drainage 45 vs 384 mm;
   missing frost-heave runoff; hour 6852 root-C leak ~4.6e-5 g unbooked.
5. **Environment reconstruction on this machine**: the run/build tree recorded in `state.md` is `C:\ecosys-build`
   (retired Windows host). Establish the macOS equivalent (build dir, run dir, `build_deploy` equivalent as a
   `scripts/` bash tool), record it in `state.md`, and re-verify the pinned toolchain via the
   `ecosys-build-reproducibility` skill. Until then, long campaigns cannot be resumed — bounded runs can.

## Blocked (with the condition that clears it)
- **Full 30-year campaign restart** — cleared by item 5 (run tree + binary reconstruction) plus a fresh prepared
  deck under a single recorded binding. Check: `ls <run_root>` + a 1-hour replay that reproduces the frontier hour.
- **Legacy 30-year Ottawa baseline freshness** — cleared by locating or regenerating the legacy baseline outputs and
  their manifest (`evidence/manifest/`). Check: manifest exists, hashes verify, hourly outputs cover 262,920 h.

## Housekeeping / release-time (do not interrupt science work for these)
- **`audit/manifest/f77index.json` is gitignored and vanishes from a fresh tree** (found missing 2026-10-15, which
  silently disabled `f77query.py` and cost a G4 sub-agent a fallback path). Rebuild after any clone/reset with
  `uv run ecosys-audit/scripts/f77index.py --root . --out audit/manifest/f77index.json`; the good totals are recorded
  in `command_registry.json → analysis.f77_index_build` (95 files / 95 units / 53 COMMON / 1520 loops / 0 unclosed /
  53803 executable statements) — a mismatch means `f77src/` moved, which is itself a finding.
- 168 `.zig` files are still formatted by 0.16's `zig fmt` (`zig fmt --check src` on 0.17 lists them). One dedicated
  formatting-only commit, after the parity run lands, so it cannot contaminate a numerics diff.
- `src/canopy/gas/aqueous_environment.zig:20` doc comment cites `STOMATE.F 69--73`; the file is `f77src/stomate.f`
  and the two solubility `EXP` lines are `:69-70`. Comment-only fix, bundle with the formatting commit.
- `selectionBaseName` (`src/io/output/record.zig:247`) has no explicit mixed-separator (`a/b\c`) test case — G7
  §3 caveat (ii). Add one assertion to the existing test at `record.zig:540-575`.
- Strip the failure-only `TEMP_DIAGNOSTIC` logging before release.
- Richards→enthalpy rebase applies internal inflow heat only in the later spatial solve — confirm whether that is a
  real gap or legacy-consistent.
- Hour 2786 surface pond freeze discontinuity (energy-limit `TFREEZ` vs Dall'Amico melt point) — revisit with the
  Stage A hydraulics numbers.
- H₃PO₄ dissociation Jacobian ~1/[H⁺]² at high pH (not currently blocking).

## Migration follow-ups (workflow revision, 2026-10-08)
- `.agent/workflow.json`, `.agent/dispatch.json`, `.agent/current_task.md`, `.agent/tasks/`, `.agent/results/`,
  `.agent/failures/` are retired swarm-controller artifacts: keep as evidence, do not update.
- Retired multi-agent launchers (`scripts/start-adversarial.*`, `start-deepseek.sh`, `start-swarm.sh`,
  `setup-adversarial-layout.*`, `herdr-deepseek-status.ps1`, `ecosys-audit/scripts/adversarial_runner.py`) live
  under `archive/pre-solo-workflow/` — history, never a live entry point. `swarm_wrapper.py` + `workflow.py`
  stay (tooling/tests import them) but are not part of the protocol; keep as evidence.
- `state.md` still records run paths on the retired Windows host; rewrite them once the macOS tree exists (item 5).
