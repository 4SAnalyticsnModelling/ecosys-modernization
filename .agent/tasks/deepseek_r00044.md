# DEEPSEEK task — Round 00044 SWE SEMANTICS + SNOW INSULATION (from CLAUDE)  [read-only]

r00043 noted: ng eh1 ground net radiation omits the snow term (snow radiation from
`snow_surface_atmosphere_exchange.zig` ~748 is not published into the reported surface energy) — an OUTPUT
comparability defect CLAUDE will fix separately. It does not by itself prove ng's snow gets no radiation.

Doubt on the SWE gap: legacy SWE falls 8-9 mm/day on DOY 6-9 WHILE it snows (DOY 9: +25 mm precip, SWE −8.5 mm)
with LE = 0. January radiation (~50 W m-2 SW, albedo 0.87) cannot melt 30 mm/day (needs ~10 MJ m-2 d-1).
(1) Check the SWE column definition in both writers: legacy (outsh.f / fouts.f / wherever f25wh1 col "snow water
equivalent" is written — VOLSS only? VOLSS+VOLWS+VOLIS? per layer 1 only? divided by AREA?) vs ng writer
(`src/io/output*` for the same column). Is the comparison like-for-like? Also snow depth column if present.
(2) If legacy SWE is snow-only, how much of legacy's pack is liquid/ice (VOLWS, VOLIS) on DOY 6-10, and where does
the precipitation go (legacy wthr/watsub: snowfall onto snowpack vs onto litter/soil when the pack is thin — any
threshold like VHCPWX/ZEROS on pack heat capacity routing new snow to the surface?).
(3) Insulation: compare snow depth, density, thermal conductivity and the soil-layer-1 temperature on DOY 6-15;
which side has the thinner/denser pack and why (compaction formula, new-snow density).
Give file:line in both codebases and the single most important like-for-like correction. ≤450 words →
`.agent/adversarial/round_00044_deepseek.md`. Reply `DONE <path>`.
