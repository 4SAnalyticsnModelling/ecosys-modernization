# Backlog — open threads, deferred work, blockers

Ordered, durable, and the first thing a new session reads after `.agent/state.md`. Anything that outlives a cycle
lives here, not in a conversation. Protocol: `.agent/protocol.md` §9.

**Reading order for a new session**: `state.md` → `cycle.json` → `frontier.json` → this file → `audit/unresolved-gaps.md`.

## Now (unblocked, take in cycle order)
0. **Migrate `ecosys-ng` to Zig 0.17.x — gate G1 cannot pass until it is done.** Toolchain mandate
   `.agent/protocol.md` §8, pin `.agent/toolchain.json`, machine check `uv run ecosys-audit/scripts/preflight.py`
   (currently FAILs on `minimum_zig_version = "0.16.0"`). Work order with the proven breakages, the codemod and
   the parity re-derivation steps: `.agent/migrations/zig-0.17.md`. Blocked by nothing — take this first.
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
