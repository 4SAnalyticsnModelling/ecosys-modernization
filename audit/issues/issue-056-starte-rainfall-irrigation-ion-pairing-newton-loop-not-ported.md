# Issue 056 -- `starte.f`'s K=1/K=2 (rainfall/irrigation) ion-pairing convergence loop has no confirmed Zig counterpart; only the closed-form NH4/phosphate sub-piece is ported

Status: OPEN, filed this pass (2026-09-19, statement-level read-only audit of `starte.f`'s two 1000-iteration convergence loops, closing `feature-008`'s "K=1/K=2 branches read but not matched to Zig" gap)
Owner: unassigned
Candidate/input hashes: `f77src/starte.f` sha256 `BBE124F6809BD1720B94DDB8512FAAD5DA2FBAF7131C57A0A13E36496DC174A5`; `ecosys-ng/src/chemistry/precipitation_nutrient_speciation.zig` sha256 `191AB43208EF25351AF1132D39A33D5A6E9E6520A653238E2BAB7FAA0C3557BD`.

## Failure signature and first bad time/location/process

Not a run-time failure signature -- a source-audit scope-completeness finding from reading `starte.f`'s main convergence loop (`:406-1227`) in full at statement level.

The loop's precipitation-dissolution, anion-exchange and cation-exchange (Gapon) reactions are all gated `IF(K.EQ.3)THEN` (`:503-802`) and the carboxyl-dissociation reaction is gated the same way (`:812-825`) -- correctly restricted to soil water. But the **ion-pairing/dissociation network** (`:826-1101`, ~20 reactions: NH4=NH3+H, HCO3/CO2 dissociation, Al-OH/Fe-OH/Ca-CO3/Ca-HCO3/Ca-SO4/Mg-OH/Mg-CO3/Mg-HCO3/Mg-SO4/Na-CO3/Na-SO4/K-SO4 complexation, and the phosphate ion-pair family `RF1P/RF2P/RC1P/RC2P/RM1P`) has **no `K.EQ.3` gate** -- it runs identically for `K=1` (rainfall, once) and `K=2` (irrigation, once per simulated day) whenever those branches reach the M-loop. This means rainfall and irrigation water, if they carry any dissolved Al/Fe/Ca/Mg/Na/K/SO4/CO3, undergo the same iterative complexation equilibrium as soil water (minus precipitation/exchange, which needs a solid substrate that rain/irrigation water lacks).

Zig's only confirmed counterpart for the K=1/K=2 branches is `ecosys-ng/src/chemistry/precipitation_nutrient_speciation.zig` (`calculate`, explicitly cites "STARTE K=1 initial CN41/CN31/CH1P1/CH2P1 speciation"), which reproduces exactly the **closed-form** NH4/NH3 and 4-species phosphate partition (`starte.f:258-263,324-329`'s `K.NE.3` branches) -- a direct algebraic ratio, not an iterative solve, because at `M=1` these species' equilibrium fractions are already exact for the `K.NE.3` case (no coupled competing reactions feed back into them when precipitation/exchange are absent). No Zig module found this pass cites `starte.f:826-1101` for the `K.NE.3` case, and no rainfall/irrigation-specific Al-OH/Fe-OH/Ca-carbonate/etc. complexation module was located (a broad grep for "rainfall...ion", "irrigation...ion", and the `starte.f:8xx-11xx` line-citation range over `ecosys-ng/src` returned no hits beyond the two closed-form modules and the K=3 soil chemistry files already tracked elsewhere in `feature-008`).

## Scientific/output impact

Likely low materiality for non-saline decks (Ottawa's weather/irrigation files plausibly carry zero or near-zero Al/Fe/Ca/Mg/Na/K/SO4 concentrations, in which case the omitted iterative complexation converges trivially to zero regardless of implementation), but this has not been checked against the actual input files this pass (read-only static-analysis scope; no input-file values were read). If any deck's precipitation or irrigation chemistry specifies nonzero base-cation/anion concentrations, Zig's rainfall/irrigation-derived solute state would omit the Al-OH/Fe-OH/Ca-CO3/etc. complexed fractions the legacy oracle computes, understating total dissolved Al/Fe/Ca/Mg/Na/K speciation detail (though likely not total mass, since the free-ion pools are still tracked) for wet-deposition and irrigation inputs specifically.

## Minimal reproducer and hypothesis

Exact command/cwd/environment: none run this pass (static source read only).
Hypothesis: the Ottawa (or any currently-used) deck's weather/irrigation files specify zero (or negligible) `CALR/CFER/CCAR/CMGR/CNAR/CKAR/CSOR` (rainfall) and `CALQ/CFEQ/CCAQ/CMGQ/CNAQ/CKAQ/CSOQ` (irrigation) inputs, making this gap immaterial for current evidence; if any are nonzero, Zig's precipitation/irrigation solute speciation would diverge from the legacy oracle's complexed-ion breakdown (though not necessarily total elemental mass).
What would refute it: reading the Ottawa deck's actual weather and irrigation input files for nonzero Al/Fe/Ca/Mg/Na/K/SO4 fields, and/or instrumenting both sides' rainfall/irrigation solute speciation for one wet hour.
Stop/resource budget: fresh issue, 0 of 3 experiments spent; filed for a future specialist pass, not chased further this pass (read-only, single-file-completion scope).

## Resolution

Cause and focused patch: not determined -- scope-completeness gap only, materiality not evaluated.
Before/after results: n/a -- no fix identified or applied; no source changed.
Regression added and actually executed: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: OPEN. Recommended next action: check actual deck input files for nonzero rainfall/irrigation base-cation/anion fields before prioritizing further; if material, port `starte.f:826-1101`'s ion-pairing network (minus the `K.EQ.3`-gated precipitation/exchange/carboxyl reactions) for the `K.NE.3` case, or confirm via a dedicated kernel test that the closed-form NH4/phosphate result is the only species that matters for this project's decks.
