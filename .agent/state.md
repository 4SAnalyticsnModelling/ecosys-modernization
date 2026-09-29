# Adversarial Workflow State

Updated 2026-09-28 22:40 (local). Plan: Complete 30-Year Ottawa Run with Zero Science Gap.

## Current Round: 5
- **Active Proposer**: CLAUDE (solver/ledger gaps on the live frontier)
- **Active Challenger**: DEEPSEEK (round 5: T-00075 deposition double-injection proof; round 4 ZEROC challenge)

## Frontier (provisional, diagnostic runs on C:\ecosys-build\runs, deck blob ecf5e61a)
- Strict hour-0 at HEAD 8a4a565 failed hour 277 (T-00075 exposure). Fixed (2edcbf2): phosphate gates,
  legacy SOLUTE ZEROC=1e-32 floors (Newton refs, acceptance, layer ion ledger).
- Replay from checkpoint 480 (h0E) reached hour 2540; fails hour 2541 (1998 d106 h21)
  `SnowVaporInventoryWithoutAirVolume`. Fix in progress: remove fatal pre-check, WATSUB 1431-1435/1499-1517
  leave vapor in airless layers undiffused (face loop already skips them).
- Next known blocker: hour 3289 Ca/Na/K layer-2 residual (issue-108; DEEPSEEK cation-sync CONTESTED,
  needs delta publish; stash "deepseek-cation-sync").
- verified_frontier = 0 (no strict campaign under a single binding yet).

## Decisions this session
- D6 DEV-004 deck-half revert executed (runtime f6 200->100, blob ecf5e61a). f6 shown irrelevant to 277.
- T-00075 (DEV-008) KEPT: pre-T-00075 behaviour is rejected science; its runtime gaps are being fixed.
- Push to origin fails 403 (account lacks write permission) — commits are local only.

## Latent gaps logged (not Ottawa-visible)
- DEEPSEEK r4 §2: possible double injection of deposition cations (primary_g[Al..Cl] + salt_mol) —
  Ottawa rain ions are 0; under proof in round 5.

## Tooling notes
- Build: `$env:ZIG_LOCAL_CACHE_DIR=C:\ecosys-build\cache; zig build -Doptimize=ReleaseSafe` in ecosys-ng
  (~15 min); exe lands in cache `o/<hash>/ecosys_ng.exe` (install step does not copy).
- Replay: copy deck in place (manifest binds absolute path), set f25y98 line 6 resume=YES; runscript edits
  break run identity; outputs after the checkpoint must match (replay refuses trajectory changes).
