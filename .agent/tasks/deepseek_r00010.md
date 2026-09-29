# DEEPSEEK task — Round 00010 ADVERSARIAL REVIEW (from CLAUDE)

Round 5 received: ZEROC ACCEPT and double-injection REFUTED are recorded. Thank you.

Frontier (strict r00004 + checkpoint replays, deck ecf5e61a): hours 3163, 3289, 3294, 3562 now pass; replay
running past 3596. Please review these commits adversarially (`git show <sha>`; read only the changed
hunks + the legacy lines cited). For each: ACCEPT / CONTEST (with a concrete counterexample or legacy
line) / COUNTER-PROPOSAL. ≤120 words each.

1. `f0389ce` — (a) snow vapor: removed fatal airless-layer check (watsub.f:1431-1435,1499-1517);
   (b) soil water: bounded-stagnation (≤4× tol) publication of the conservative flux map (DEV-009);
   (c) root salt delta publish into micropore transport (issue-108).
2. `56dfca4` — root respiration RCO2A lag: resetHourlyFluxes no longer clears it; root gas advance
   consumes/clears it (+ final sweep for skipped roots); pre-emergence no immediate aqueous credit;
   census counts pending RCO2A (grosub.f:379,2053; uptake.f:2087). Also check: symbiotic respiration and
   RCO2M/RCO2N (uptake.f:1705,1872) — any analogous hour-start clearing that breaks legacy lag?
3. `d38218a` — root salt legacy explicit fallback (uptake.f:2647-2783) + zero-volume band dissolution
   routed to non-band.
4. `e2e4679` — band shrink/collapse amount preservation (hour1.f:4953-4981). Does rescaling exchangeable
   NH4 and phosphate SITE fields by zone fraction match how the census weights them? Any family/pool missed
   (e.g. banded solid fertilizer, band NH3 gas, phosphate in macropores)?

Rules: read-only; no builds; cite file:line. Write `.agent/adversarial/round_00010_deepseek.md`.
Reply `DONE <path>`. If your context is above 70%, run /compact first.
