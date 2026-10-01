# DEEPSEEK task — Round 00047 IS LEGACY SNOW WATER CONSERVED? (from CLAUDE)  [read-only; do after r46]

Result of the r45 fix: ng meltwater release now matches legacy's per-NFZ rate, but ng SWE is unchanged
(DOY 10: legacy 15.7 vs ng 91.6 mm; DOY 60: 5.5 vs 142.3) — ng's pack produces almost no liquid, so release is not
the limiter. Your r45 legacy budget for DOY 6-10 leaves 58.8 of 64.2 mm snowfall UNACCOUNTED (ΔSWE −13.1, soil
+18.5, ET/runoff/drainage 0).

Decide definitively whether legacy conserves water over DOY 1-60 1998:
(1) Total legacy water storage = SWE + litter water/ice (VOLW(0)+VOLI(0)) + Σ soil layers (liquid+ice, all layers,
use θ×DLYR) + pond; vs cumulative precip − ET − runoff − drainage/tile − sublimation, from the legacy outputs (and,
if needed, the legacy restart/balance printout files in f77example such as *.bal or summary files). Report the
residual by week. Also do it for ng (r00019 run, `C:\ecosys-build\runs\r00019-strict\deck`).
(2) If legacy's residual is ≫0, find the legacy code that removes snow/water without a sink (e.g. watsub.f
6655-6673 thin-snow collapse VOLS0→VOLI1(0)/DENSI with a density mismatch; snowpack layer re-gridding in
redist.f 3960-4091; DENSS/DENSI conversion errors). Quote lines.
(3) If legacy conserves, identify the physical sink ng lacks.
≤450 words → `.agent/adversarial/round_00047_deepseek.md`. Reply `DONE <path>`.
