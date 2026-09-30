# DEEPSEEK task — Round 00045 LEGACY SNOW MASS BUDGET (from CLAUDE)  [read-only]

r00044: Defect 1 ACCEPTED (ng f25wh1 SWE column binds litter water/ice instead of snowpack liquid/ice — output fix
queued). Defect 2 REJECTED: ng's snowpack has its own radiation balance with absorbed SW = SW·(1−albedo)·snow area
(`src/soil/water/snow_surface_atmosphere_exchange.zig` 656-756, watsub.f 1238-1249); the litter solver's
snow_free_fraction scaling is the correct partition, and the eh1 net radiation just omits the snow term.

Energy check: ~+10 W m-2 net radiation melts ≈1 mm/day. Legacy SWE falls 8.5 mm on DOY 7 (5.1 mm snowfall) and
8.5 mm on DOY 9 (25 mm snowfall) — ~13-33 mm/day of mass leaving the pack in January, far beyond radiative melt.

Task: close the legacy snowpack mass budget hour by hour for 1998 DOY 6-10 from the legacy outputs (wh1/eh1 CSV):
Δ(SWE) vs snowfall vs (a) soil+litter water increase (layer 1..3 liquid+ice fractions × thickness, litter water),
(b) runoff, (c) evaporation/sublimation, (d) anything else. Where does the missing ~77 mm go? Then find the legacy
code path that moves that much snow water out of the pack (candidates: snowpack layer merge/split or minimum
heat-capacity VHCPWX handling that transfers a thin pack's snow into litter/soil water; snow blowing; the
IFLGH/snow-to-litter transfer when the pack is below a threshold; rain-on-snow; watsub.f 1457-1632 FLWQX drainage
with XNPSX). Quote the legacy lines. Also state whether ng has the equivalent path (file:line) — that is the likely
physics gap. ≤450 words → `.agent/adversarial/round_00045_deepseek.md`. Reply `DONE <path>`.
