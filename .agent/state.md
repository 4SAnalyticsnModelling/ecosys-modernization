# Adversarial Workflow State

Updated 2026-09-29 09:35 (local). Plan: Complete 30-Year Ottawa Run with Zero Science Gap.

## Current Round: 20
- Proposer: CLAUDE. Challenger: DEEPSEEK (r16-r19 ACCEPT; r20 reviewing DEV-012 explicit gas pressure).

## Frontier (diagnostic runs on C:\ecosys-build\runs, deck blob ecf5e61a, ReleaseSafe)
- Top-layer solids drain (root of hour 4037/3918 failures) fixed across 627634a + 470810a; verified dry
  density stays 1.11 MJ m-3 K-1 through thaw (r00011-diag). Fresh strict run r00012 (commit 470810a,
  binary 5a600650) started 13:03 → audit/runs/ottawa/r00012-strict.
- Throughput ~150 ms/h (WATSUB ~41, SOLUTE ~30-40); 30-yr ≈ 11 h at steady state (legacy 51 ms/h; D4 = P6).
- verified_frontier = 0 (a single-binding strict campaign from hour 0 has not yet run to a stopping point
  with every fix; each fix so far validated by strict hour-0 or checkpoint replay).

## Fixed this session (commits, all local; push → 403)
8a4a565 deck D6 revert + compile fix · 2edcbf2 STARTE ZEROC dust (P gates, SOLUTE floors, layer ions) ·
f0389ce snow vapor airless layers, bounded water stagnation (DEV-009), root salt delta publish ·
56dfca4 root respiration RCO2A lag (carbon destroyed hourly) · d38218a root salt legacy explicit fallback,
zero-volume band dissolution · e2e4679 band shrink/collapse amount preservation · 9416f92 DEV-011 interim
(never triggered since) · 1b098e1 exact phosphate-site projection (SOLUTE site crawl; registered
NONCONVERGENCE-001 fixture now converges), cell ion floor · 7e04f9f recoverable ingress overflow ·
a83519a legacy per-cycle FLQRS rain overflow to litter · 627634a freeze-thaw no longer drives soil relayering
material transfer (redist.f 8186-8195 CDPTHY excludes NN=2).

## Proposed deviations (audit/intentional-deviations.md)
DEV-009 bounded water stagnation publication; DEV-010 legacy ZEROC floors; DEV-011 terminal SOLUTE best-bounded
(evidence insufficient; unused since 1b098e1).

## Open / known simplifications
- FLQRS ignores FSNX (partial snow cover). Rain solutes not rerouted with overflow water (legacy-consistent).
- DEEPSEEK r12: H3PO4 dissociation Jacobian ~1/[H+]^2 at high pH (not currently blocking).
- Push to origin fails 403 (account lacks write permission).
- Relayering: legacy DDLYRY thickness restore (DLYR→DLYRI) and IFLGM=0 branch not ported.
- Richards→enthalpy rebase applies internal inflow heat only in the later spatial solve; intermediate
  temperature can leave [173,373] K for a genuinely low-capacity layer (not seen once solids preserved).
