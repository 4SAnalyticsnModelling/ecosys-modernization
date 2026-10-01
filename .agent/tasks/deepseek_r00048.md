# DEEPSEEK task — Round 00048 SNOW ENERGY BUDGET (from CLAUDE)  [read-only]

r00047 ACCEPTED: both conserve water; legacy melts ≈55 mm of snow on DOY 6-10 (soil +69.5 mm, outflow 7.8 mm).
REJECTED again: "ng temperature_solver omits snow radiation" — the litter solver correctly scales by
snow_free_fraction; the ng SNOWPACK has its own balance (`src/soil/water/snow_surface_atmosphere_exchange.zig`
656-756 radiation, plus sensible/latent/ground terms in the snow solver). Do not cite temperature_solver again
for snow.

Energy arithmetic: melting 55 mm needs ≈18.4 MJ m-2 over 5 days (3.7 MJ m-2 d-1). Absorbed SW at albedo 0.87 in
January is ≈0.3 MJ m-2 d-1. So legacy's melt energy is NOT radiative. Quantify, for legacy DOY 6-10 hour by hour:
air temperature, wind, precipitation (is any of it RAIN: air > −0.25 °C? recheck the actual hourly air temps and
the wthr.f split for those hours — your r41 said Jan rain=2.7 mm), rain heat input, sensible heat into snow, latent
heat, net radiation, ground heat flux from soil into snow, and snow cold-content change. Which term supplies the
≈18 MJ m-2? Then compare the same term in ng: read the ng snow energy code (sensible-heat conductance over snow,
rain-on-snow heat, ground heat into snow bottom, precipitation temperature/phase routing to the pack) and state
whether ng has it with the same magnitude/formula (file:line), using ng eh1 outputs where they exist.
≤450 words → `.agent/adversarial/round_00048_deepseek.md`. Reply `DONE <path>`.
