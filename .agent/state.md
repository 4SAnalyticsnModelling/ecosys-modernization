# Adversarial Workflow State

Updated 2026-09-30 03:00 (local). Plan: Complete 30-Year Ottawa Run with Zero Science Gap.

## Current Round: 34
- Proposer: CLAUDE. Challenger: DEEPSEEK (r31 dust-gate audit, r32 DEV-014, r33 DEV-015, r34 terminal toggles).

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

## Fixed this session (commits, all local; push → 403)
8a4a565 · 2edcbf2 · f0389ce · 56dfca4 · d38218a · e2e4679 · 9416f92 · 1b098e1 · 7e04f9f · a83519a (see git log) ·
627634a freeze-thaw drives no soil relayering transfer · 470810a SOC restore uses freeze-free DLYR, DVOLI =
VOLI+VOLIH, NN=3 pond→soil transfer gated by NU>NUI, DEV-012 explicit boundary gas pressure · 215ad41 DEV-013
zone-capped topsoil uptake · 6f50e81 ZEROS2 gate on macropore water-table discharge · 84c09d5 SOLUTE entry RHHX.

## Proposed deviations (audit/intentional-deviations.md)
DEV-009 bounded water stagnation publication; DEV-010 legacy ZEROC floors; DEV-011 terminal SOLUTE best-bounded
(evidence insufficient; fired post-tillage with quality 161 before 84c09d5); DEV-012 explicit boundary gas pressure;
DEV-013 zone-capped topsoil microbial uptake; DEV-014 bounded phase stagnation/ceiling publication; DEV-015 terminal
stiff solute image. Terminal ladder attempt enables DEV-011/014-ceiling/015 together.

## Open / known simplifications
- COMPARABILITY: 1998 d200/d210 noon cell fluxes ng vs legacy: CH4 -1.15 vs -0.21 umol m-2 s-1, O2 exchange 0.12 vs
  3.23 (NEE -1.30 vs -0.55). Maize sown d138 never emerges in BOTH (legacy pop file zero) - deck-consistent.
- Hour 6852 (d286 JCUT termination of unemerged maize): ~4.6e-5 g root C leaves the plant without litter booking.
- Hour 2786 surface pond freeze discontinuity (energy-limit TFREEZ vs Dall'Amico melt point?) — r26.
- Frost heave dilutes intensive mol/Mg soil carriers (legacy pins DLYR via DDLYRY; ng keeps elastic geometry).
- FLQRS ignores FSNX (partial snow cover). Rain solutes not rerouted with overflow water (legacy-consistent).
- DEEPSEEK r12: H3PO4 dissociation Jacobian ~1/[H+]^2 at high pH (not currently blocking).
- Push to origin fails 403 (account lacks write permission).
- Richards→enthalpy rebase applies internal inflow heat only in the later spatial solve.
- Many failure-only TEMP_DIAGNOSTIC logs to strip before release.
