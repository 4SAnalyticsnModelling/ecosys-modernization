# Feature ID: FEAT-013-EXTRACT-FIRE-COMBUSTION-UPTAKE-AGGREGATION

Status: PARTIALLY_ASSESSED (source-audit; `extract.f` is 975 lines and was FULLY read this pass; ~60% is mechanical PFT-to-grid-cell summation with no independent math, spot-checked rather than line-by-line)

## Scope and provenance

Legacy source: `f77src/extract.f` (sha256 `AFD88FD3B587FD7B82AB8350F29C1E89800203E4A012D977AE3EFDA22BA01077`), header: `SUBROUTINE extract(...)`. Not an uptake-physics routine itself -- it's the aggregation/driver layer summing per-PFT results already computed in `uptake.f`/`grosub.f` into grid-cell totals for `redist.f`. The one genuine file-local physics block is fire/combustion (`:143-587`).

### 1. Canopy fire temperature response + O2/CH4-limited combustion partition -- `preserved`

`extract.f:167-211` (`RTK=8.3143*TKQ`; `TFNCO=min(1,exp(12.028-60000/RTK))`; `ROGOK=min(ROGCK*O2/(O2+K),O2content)*FCOGC`; `RC4OK=min(RCHOK*CH4/(CH4+K)*O2/(O2+K),(O2content-ROGOK)/2.667)`; `FCC=(RCGCK-RCGOK-RCHOK)/RCGCK`). Zig: `ecosys-ng/src/plant/exchange/soil.zig` (sha256 `1712D3330FDF1CAA33DFD54BD19B19608982F13D5D40FBCAD77A5D6157261129`), `canopyFireCombustion` (`:677-718`), explicitly headed "Exact EXTRACT total-canopy combustion partition." One-to-one match including the `2.667` O2/C stoichiometry constant (`:90`) and the double-limited (O2 x CH4) Michaelis-Menten form. Called from `plant/growth/shoot_fire.zig:122-142` (`partitionCellProducts`), bound in the live driver.

### 2. Fire N/P mineral-vs-gaseous partition (EXTRACT-004) -- `preserved`, post-fix; standing-lesson check applied and mattered

`extract.f:44-45,256-259,276-277,391-397` (`FCOMN=FCOMNY+(FCOMNX-FCOMNY)*(1-TFNCOC)`, constants `FCOMNX=0.5/FCOMPX=0.9/FCOMNY=0.1/FCOMPY=0.7`). **Two candidate Zig owners with contradictory-looking headers found** -- exactly the pattern this session has repeatedly hit: `ecosys-ng/src/management/fire_nutrient_partition_state_update.zig` (sha256 `60F86D38935630EFE591258E3D87DA69BF3A737C69C12ACA9081F81EB71DFC4A`) opens "SUPERSEDED BY BOUND OWNER; EXTRACT-004/005 are closed," but immediately below carries an older "HISTORICAL DISPOSITION: GAP" block that reads as open if not checked further. **Grep for callers confirmed this module is referenced only from `module_index.zig`/its own test index -- never bound into the live driver.** The real, live owner is `ecosys-ng/src/plant/growth/shoot_fire.zig` (sha256 `84CA414161393E0047F3F788F476826A1BA17263AD50B6867A7A21C2C8B1F200`, `:175-212`, tagged `EXTRACT-004`): `ammonium_fraction=0.1+0.4*(1-response)`, `phosphate_fraction=0.7+0.2*(1-response)` -- exact match to the Fortran constants -- crediting the mineral share to `surface_fire_exchange.addCanopyFireSurfaceNutrients`. Verified end-to-end by test "EXTRACT-004 fix verification" (`shoot_fire.zig:558-612`), closing N/P mass balance across gaseous-loss + mineral-share sinks.

### 3. Fire salt credit to surface pool (EXTRACT-005) -- `preserved`, post-fix

`extract.f:298-315,543-563`. Zig: `shoot_fire.zig:214-231`, tagged `EXTRACT-005`, routes combustion salt loss (8 species) to `surface_fire_exchange.addCanopyFireSurfaceSalts`, verified by test at `:741-777`.

### 4. Root-water-uptake convective heat -- `preserved`

`extract.f:701-703` (`TUPHT=TUPHT+UPWTR*4.19*TKS`, water volumetric heat capacity 4.19 MJ/m3/K). Zig: `ecosys-ng/src/plant/root/root_uptake_outputs.zig` (sha256 `5D89ED146A97DC5FD30F1A99FCF659862F8D18E6B2B5FC2DEC05545C4A671589`, `:224`) and `plant/root/water_uptake_state_update.zig` (sha256 `E813DF7EEF35923ED9613A418D9F710F8D544915A0C502E69CF134D41AFBD7FA`, `:3,201`), both with the exact `4.19` constant and matching test assertions. Two files cover overlapping-looking scope (one narrow water/heat ledger, one broader ledger) -- confirmed an organizational split, not a duplication conflict.

## Not covered this pass

The ~60% of the file that is mechanical PFT-to-grid-cell `+=` summation with no independent numerical content -- spot-checked one representative accumulator pattern (`aggregate()`, `soil.zig:779-815`) rather than exhaustively.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file coverage). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Four equation groups `preserved` (two of them post-fix, EXTRACT-004/005, both confirmed closed by call-site tracing rather than trusted from a stale comment). Zero open gaps found in this file.
