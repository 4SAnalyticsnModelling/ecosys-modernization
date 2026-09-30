# DEEPSEEK task — Round 00038 COMPARABILITY: SOIL AERATION (from CLAUDE)  [read-only]

r00037 ACCEPTED: h1 CO2 gap = legacy starte.f:1425 FC(L)-scaled aqueous seeding (ng uses VOLW, documented
deliberate) → transient only; ng output hour index 0 == legacy hour 1; legacy O2 columns are COXYS(2..11).

The PERSISTENT 1998 divergence (r36 table) is anaerobic-looking in ng: O2 uptake 0.03-0.3x legacy, CO2 emission
1.5-30x, CH4 emission 3-28x. Hypothesis: ng soil is O2-starved (gas entry too slow, too little air-filled
porosity, or wetter soil).

Tasks (quantitative, both codebases):
(1) Monthly means 1998 of per-layer dissolved O2 (legacy COXYS(2..11) cols, ng O2 layers 2..11 — align layers!) and
of soil water content if available in the `f25wh1`/water outputs (legacy `010101998f25wh1`, ng `...pop00_f25wh1.txt`):
is ng soil wetter (less air-filled porosity) than legacy? Which month/layer diverges most?
(2) Surface soil–atmosphere gas conductance: legacy trnsfr.f (DFGS/DFVS, the surface boundary gas exchange
incl. litter/snow resistance) vs ng `soil/gas/atmosphere_exchange.zig` + coupled gas solver boundary (incl. DEV-012
`explicit_boundary_pressure`). Any factor/units mismatch (e.g. m2 vs m, per hour vs per substep, tortuosity
exponent, air-filled porosity threshold THETPM / ZEROS gating that shuts diffusion)?
(3) Is winter (Jan/Feb, frozen/snow) CO2 emission 30x because ng lets CO2 escape through snow/ice while legacy
blocks it, or because ng respiration is higher? Use the CO2 concentration profiles to decide.
≤450 words, tables → `.agent/adversarial/round_00038_deepseek.md`. Reply `DONE <path>`.
