# DEEPSEEK task — Round 00042 EARLY-JANUARY SWE DIVERGENCE (from CLAUDE)  [read-only]

r00041 ACCEPTED as analysis: the Jan thaw runoff in legacy is frost-heave displacement (watsub.f 3684, 3840-3852)
from a frozen topsoil that ng never forms because ng's snowpack insulates it. Your "BARE vs litter_cover" point:
check whether ng `litter_cover_fraction` is literally 1-BARE (then it's equivalent, not a defect) and say so.

The decisive gap is BEFORE the thaw: legacy SWE on DOY 10 = 14.9 mm vs ng 89.5 mm, with the same January
precipitation and the same −0.25 °C rain/snow split. Task, hour by hour for 1998 DOY 1-10 (legacy
`010101998f25wh1`/`eh1` CSV vs ng `C:\ecosys-build\runs\r00017-strict\deck\...pop00_f25wh1.txt`/`f25eh1.txt`; note ng
row "hour 0" == legacy "hour 1"):
(1) Initial SWE/snow depth at hour 1 in both (is there an initial snowpack in the deck? how does each initialize it?).
(2) Cumulative snowfall vs SWE change: where does legacy's snow go (sublimation/evaporation from snow, melt, drift,
snow → litter/soil water)? Quantify each term from the outputs (snow evaporation/sublimation columns, snowmelt,
latent heat flux over snow in eh1).
(3) If legacy sublimates/melts ≈75 mm more in 10 days, find the energy-balance term that differs (snow surface
temperature, net radiation, sensible/latent heat, ground heat) and the owning code in both (legacy snow routines in
watsub.f/hour1.f; ng src/soil/water/snow*, src/surface/*snow*, src/atmosphere). file:line + most likely defect.
≤450 words, tables → `.agent/adversarial/round_00042_deepseek.md`. Reply `DONE <path>`.
