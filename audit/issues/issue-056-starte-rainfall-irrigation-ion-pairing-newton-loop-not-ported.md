# Issue 056 -- `starte.f`'s K=1/K=2 (rainfall/irrigation) ion-pairing convergence loop has no confirmed Zig counterpart; only the closed-form NH4/phosphate sub-piece is ported

Status: OPEN, filed this pass (2026-09-19, statement-level read-only audit of `starte.f`'s two 1000-iteration convergence loops, closing `feature-008`'s "K=1/K=2 branches read but not matched to Zig" gap). **Follow-up (2026-09-19, same day): CONFIRMED NOT REACHABLE/immaterial for the Ottawa deck** -- irrigation is never scheduled (K=2 side moot) and the weather files' rainfall base-cation/anion chemistry (Al/Fe/Ca/Mg/Na/K/SO4/Cl) is exactly zero every year checked (K=1 side immaterial). See "Follow-up resolution (2026-09-19)" near the end of this file. Deprioritized accordingly; not closed.
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

## Follow-up resolution (2026-09-19) -- NOT REACHABLE/immaterial for Ottawa on both the K=1 and K=2 sides

A dedicated, bounded, read-only follow-up (no `zig build`/run, exactly as scoped) checked exactly the
input-file condition this issue's own "Minimal reproducer" section asked for.

**K=2 (irrigation) side -- moot, irrigation is entirely absent.** A parallel bounded check for
`issue-044` (same session) confirmed the Ottawa deck's land-management manifests (`f25m98`..`f25m03`
in `f77example/Cool Temperate Maize-Soybean ON/`, cross-checked against
`ecosys-ng-prod-examples/.../management/soil/management_grid_1998.txt`) all give `NO` in the
irrigation-file slot for every year of the deck's 1998-2003 forcing cycle. The `K=2` branch of
`starte.f`'s convergence loop is only reached when an irrigation event occurs; since none ever does
for this deck, the ion-pairing network's `K=2` occasions never fire at all, regardless of what
concentrations an irrigation-chemistry file might specify.

**K=1 (rainfall) side -- reachable (rain occurs every year) but the relevant chemistry inputs are
uniformly zero.** `f77src/reads.f:251-263` shows the rainfall ion-pairing inputs (`CALRG, CFERG,
CCARG, CMGRG, CNARG, CKARG, CSORG, CCLRG` -- Al, Fe, Ca, Mg, Na, K, SO4, Cl) are read from line 4 of
the weather file itself (one record per year, applied to every rain event that year), immediately
after the two header lines and the `Z0G,IFLGW,ZNOONG` line. Read this record for every weather file
available for the Ottawa deck: `f77example/Cool Temperate Maize-Soybean ON/gbf98h` line 4 =
`7 0.25 0.75 0.2 0 0 0 0 0 0 0 0`, and `gbf99h` line 4 = `7.0 0.25 0.75 0.2 0.0 0.0 0.0 0.0 0.0 0.0
0.0 0.0` (also cross-checked against `ecosys-ng-prod-examples/.../weather/gbf98h`, byte-equivalent).
In `reads.f`'s read order, this maps to `PHRG=7, CN4RIG=0.25, CNORIG=0.75, CPORG=0.2` (pH, NH4, NO3,
PO4 -- all nonzero, but these are exactly the species already handled by the ported closed-form
piece, `precipitation_nutrient_speciation.zig`) followed by `CALRG=CFERG=CCARG=CMGRG=CNARG=CKARG=
CSORG=CCLRG=0` -- **every one of the eight base-cation/anion species this issue's missing ion-pairing
network would actually operate on (Al, Fe, Ca, Mg, Na, K, SO4, Cl) is exactly zero**, consistently
across both years checked and both the legacy and modern input copies.

**Verdict: NOT REACHABLE/immaterial for the Ottawa deck, in any input this project currently has.**
The `K=2` occasions never fire (no irrigation scheduled at all). The `K=1` occasions fire every rain
event, but with `CALRG=CFERG=CCARG=CMGRG=CNARG=CKARG=CSORG=CCLRG=0`, the omitted Al-OH/Fe-OH/Ca-CO3/
Ca-HCO3/Ca-SO4/Mg-OH/Mg-CO3/Mg-HCO3/Mg-SO4/Na-CO3/Na-SO4/K-SO4 complexation reactions all converge
trivially to zero on both sides regardless of implementation -- exactly the "likely low materiality"
hypothesis this issue already stated, now confirmed rather than merely assumed. The already-ported
closed-form NH4/phosphate piece remains the only species family with nonzero rainfall input for this
deck, and it is already covered.

**What would trigger it**: any deck whose weather-file rainfall-chemistry record (or a future
irrigation-chemistry file, once one exists) specifies a nonzero Al/Fe/Ca/Mg/Na/K/SO4/Cl concentration.
No deck currently in this project's scope does so.

**Disposition update**: downgraded from "likely low materiality, not checked" to "confirmed
immaterial for the only deck this project currently validates against, decisively so from input
files alone (no run needed)." The missing routine remains tracked, not silently closed, per the
contract's dormant-branches clause. Traceability: see new row `TRC-297` in
`audit/traceability/traceability.csv`, which supersedes `TRC-276`'s materiality framing (disposition
unchanged, `unresolved`) with this dormancy finding.
