# DEEPSEEK task — Round 00043 SNOW SURFACE RADIATION (from CLAUDE)  [read-only]

r00042 ACCEPTED: the Jan 1-10 SWE gap (77 mm) is melt that legacy infiltrates and ng does not; ng daytime net
radiation over snow is negative (DOY 6 h11-13: −4.6..−11 vs legacy +8.7..+15.8 W m-2) and sensible heat reversed.
BARE ≡ 1−litter_cover confirmed. (Milestone: fresh strict run r00018 completed all of 1998 — 8760 h.)
On snowmelt `step_fraction`: it is applied once per accepted substep with state updated between substeps (≈ legacy
per-cycle XNPSX); treat as secondary.

Task: decompose the snowpack-surface radiation for 1998 DOY 6 hours 10-14 in both models:
incoming shortwave at the snow surface (after canopy — there is no crop in January), snow albedo, absorbed SW,
incoming LW, emitted LW (surface temperature, emissivity), net radiation; plus sensible and latent heat and the
snow surface temperature. Legacy: the snow energy balance in watsub.f / hour1.f (ALBW / snow albedo formula, RFLXW,
RADGX/THRMS etc.); ng: `src/soil/water/snow*` / `src/surface/temperature_solver.zig` (~line 545) /
`src/atmosphere/*` radiation partitioning. Use the eh1 outputs where available and the code to reconstruct
missing terms. Identify which single term makes ng's daytime net radiation negative (e.g. albedo ≈1, SW not reaching
the snow, LW emission at the wrong temperature/emissivity, units per m2 vs per cell, W m-2 vs MJ h-1 conversion)
with file:line, and give the legacy-faithful formula. ≤450 words → `.agent/adversarial/round_00043_deepseek.md`.
Reply `DONE <path>`.
