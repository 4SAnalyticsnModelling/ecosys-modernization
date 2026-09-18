# Feature ID: FEAT-005-NITRIFICATION-DENITRIFICATION-MINERALIZATION

Status: PARTIALLY_ASSESSED (first-pass source-audit; `nitro.f` is ~179KB/~7000 lines, only ~4 equations + surrounding blocks read)

## Scope and provenance

**Legacy source:** `f77src/nitro.f` (sha256 `26D2222512F672E12500A5C3253218808C4A83722D7127F35A9D655A21305A2A`).

**Nitrification (NH3->NO2->NO3):** `nitro.f:1153-1170` (NH3 oxidizers) / `:1251-1265` (NO2 oxidizers). Unlimited rate x temp/N,P/CO2/biomass/timestep activity, ammonia self-inhibition `1/(1+CNH3S/VHKI)`, Monod NH4 term, O2-demand coefficients `2.667`/`3.429`(NH4)/`1.143`(NO2). Params `nitro.f:150-159`: `VMXH=0.125`, `VMXN=0.125`, `ECNH=0.30`, `ECNO=0.10`, `RNFNI=2.0E-04`, `ZHKI=7.0E+03`, `VMKI=1.0`, `VHKI=14.0`.

**New (Zig):** `ecosys-ng/src/soil/microbial/nitrification.zig` (sha256 `7EE3EA8DDE00EDC65536C211112E980CD754A725B25E6A5ECBA4862B065C80D5`), `calculatePotential` (`:77-124`), called from `nitrification_step.zig`. All constants verified identical by name/value: `ammonia_oxidation_rate_g_n_per_g_c_h=0.125`, `nitrite_oxidation_rate_g_n_per_g_c_h=0.125`, `ammonia_oxidizer_carbon_efficiency_g_c_per_g_n=0.3`, `nitrite_oxidizer_carbon_efficiency_g_c_per_g_n=0.1`, `oxygen_per_respired_carbon=2.667`, `oxygen_per_ammonium_n=3.429`, `oxygen_per_nitrite_n=1.143`, `inhibition_decay_per_h=0.0002`, `inhibition_decay_ammonium_constant=7000`, `ammonia_product_inhibition=14`.

**Disposition: `preserved`.**

**Denitrification (heterotrophic, NO3->NO2->N2O):** `nitro.f:1732-1769`. Unmet-O2-demand-driven capacity (`ROXYD`, `VMXD3=0.875*ROXYD`), competitive NO2/NO3 Monod inhibition, product inhibition `1/(1+cap/(K*V))`, triple-min (capacity/DOC-budget/supply) at `RDNO3` (`:1762`). Params `nitro.f:152-159`: `Z3KM=1.4`, `Z2KM=1.4`, `VMKI=1.0`, `ECN3=0.429`, `ECN2=0.429`, `ECN1=0.214`.

**New (Zig):** `ecosys-ng/src/soil/microbial/denitrification.zig` (sha256 `18826B49FCD50B2E498B0C51FDB7FC30C9F87C4C5D82B877AE2B837A6F475223`), `calculateHeterotrophicPotential` (`:72-141`). Same chain and constants verified identical: `nitrate_half_saturation=1.4`, `nitrite_half_saturation=1.4`, `product_inhibition_rate=1`, `carbon_per_nitrate_n=0.429`, `carbon_per_nitrite_n=0.429`, `carbon_per_nitrous_oxide_n=0.214`, `nitrate_n_per_unmet_oxygen=0.875`.

**Disposition: `preserved`.**

**NH4/NO3 mineralization-immobilization:** `nitro.f:2094-2116` (NH4), `:2154-2172` (NO3, leftover demand after NH4). Sign convention: positive `RINHP=(OMC3*CNOMC-OMN3)` = immobilize, negative = mineralize; Monod-capped uptake capacity/competition/min-clamp sequence.

**New (Zig):** `ecosys-ng/src/soil/microbial/nitrogen_exchange_step.zig` (sha256 `CB2EF6ADE6358D2131FE6C18113B516E1E82C909B0D3DF3EBF71B4EDB0885BD3`), `applyTile` (`:71` on, doc comment `:32-34` explicitly cites "Ports NITRO RINHP/RINHO/RINHB/RINH4/RINB4 and the following RINOP/RINOO/RINOB/RINO3/RINB3 sequence"). Same sign convention, same C:N-deficit driver, same two-stage NH4-then-NO3 sequencing including the "leftover demand" pattern (`:88`).

**Disposition: `preserved`** (functional-form/sign match confirmed; constant-level cross-check of `Z4MX/Z4KU/ZOMX/ZOKU/CNOMC` against `nitrogen_parameters.zig` NOT done this pass).

## Two findings worth tracking separately

**1. Dead reference code (not a science gap):** `nitrification.zig`'s `state_updateZone` (`:139-149`) and `denitrification.zig`'s `state_update`/`state_updateAutotrophicZone` (`:223-239,258-267`) are tagged `NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001` (in-code comment) -- zero production callers. Production applies potentials via an independently-maintained reimplementation, `soil/nutrients/nitrogen_state_update.zig`'s `applyZone` (`:214-215,1438`), **not audited this pass**. Disposition on the dead helpers themselves: cosmetic/harmless (a fix there would have no simulation effect) -- but `applyZone` itself is an open verification gap: `unresolved` until independently traced against the same Fortran equations.

**2. Corrected translation defect, found via in-code evidence (not independently re-derived):** `denitrification.zig:143-176`'s doc comment on `AutotrophicInputs.ammonium_supply_per_nitrite_reduction` documents a previously-reconstructed bound that conflated two distinct source constants -- `nitro.f:2029/2031` (`FNH4*3.0*ZNH4S*XNFH`) vs `nitro.f:2040/2041` (`0.333`) -- computing `NH4/0.333 = 3.003x NH4` instead of keeping `3` and `0.333` as separate factors, overstating the electron-donor ceiling by `1.001001x`. The fix is evidenced by the comment and a named regression test ("NITRO autotrophic denitrification retains distinct 3 and 0.333 factors"). **`nitro.f:2029-2041` itself was not independently re-read this pass** -- this is reported as found-in-Zig-comment evidence, not independently verified. Disposition: `legacy-defect-corrected` (tentative, pending independent verification of the cited Fortran lines).

## Not covered this pass

`nitrogen_state_update.zig`'s `applyZone`; constant-level check of `Z4MX/Z4KU/ZOMX/ZOKU/CNOMC`; N2 fixation (`RN2FX`); CH4/H2 methanogen pathways; plant-N-uptake coupling; litter-surface mineralization (`RINH4R`); P mineralization-immobilization (`RIPO4`/`RIP14`); ~5000 remaining lines of `nitro.f` (colonization, priming, growth-respiration bookkeeping); independent re-read of `nitro.f:2029-2041`.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (first-pass, explicitly scoped as above). Independent reviewer: not yet done. Evidence: file:line citations above, git commit `97a33a9`-era tree. Decision: NOT_ASSESSED for gate purposes; three equations `preserved` at the level read, one candidate `legacy-defect-corrected` pending independent verification, `applyZone` open.
