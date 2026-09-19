# Issue 046: `solute.f` litter HCO3-CO3+H dissociation (`RHCO3`) bounds against a stale, unrelated carboxyl-exchange substrate limit

## Impact/severity

Real, bounded legacy defect in the litter (surface residue) chemistry pathway of `f77src/solute.f`. Litter's `RHCO3` (HCO3- <-> CO3-- + H+ dissociation) rate is clamped on its dissociation (negative) side by a stale scratch variable `XMIN` that was last assigned two reactions earlier for a completely unrelated species (carboxyl exchange sites), instead of the freshly-computed `XMINN` (the correct HCO3- substrate limit for this exact reaction) sitting two lines above it. This is the "N parallel blocks, 1 outlier" defect shape confirmed repeatedly elsewhere in this file (`issue-036`, `issue-045`) and across this session, this time at N=3 within one litter ion-pairing block.

Numerical consequence is real, not cosmetic: `RHCO3` feeds litter's net H+ transformation `RHY` every reaction sub-iteration (`solute.f:5012`, `RHY=RHY+RZHYS-RXHC*BKVLW-RCO2Q-RHCO3+...`), which in turn drives the immediately-following gibbsite/Fe(OH)3 closing precipitation-dissolution block (`:5025-5047` and onward) and the whole-hour `TR*` mass totals handed to `redist.f`. Severity is judged bounded (one clamp bound on one of ~dozens of litter reactions, litter is a thin surface pool) rather than catastrophic, but it is a genuine mis-citation, not a documented design choice.

## First bad location

`f77src/solute.f:4538` (litter, `IF(ISALTG.NE.0)` dynamic-salt branch), inside the "ION PAIRING REACTIONS IN LITTER" block (`:4503-4553`).

```fortran
C     RHCO3=HCO3-CO3+H dissociation
C
      XMINN=FION0*CHCO31
      XMINP=FION0*AMIN1(CHY1,CCO31)
      ACO3Q=DPHCO*AHCO31/AHY1
      RHCO3=AMAX1(-TSL,-XMIN
     2,(AMIN1(TSL,XMINP,(ACO31-ACO3Q)/A2(0,NY,NX))))
```

`XMINN` is computed fresh at `:4535` for exactly this reaction (`FION0*CHCO31`, the HCO3- substrate limit) but the clamp at `:4538` reads `-XMIN`, not `-XMINN`. `XMIN` was last assigned at `:4492`, three sections earlier, for the litter carboxyl-radical dissociation block: `XMIN=FION0/BKVLW*XHC1` (a substrate limit derived from occupied carboxyl exchange sites, `XHC1`, a chemically unrelated species). Between `:4492` and `:4538`, `XMIN` is never reassigned.

## Reference and Zig source anchors

Legacy: `f77src/solute.f` (sha256 `DC0056F3EDEE5670F5EB4443802E829A24A0D3BAE1DE0C4644A33A5007442324`), lines `4483-4501` (carboxyl block that last sets `XMIN`), `4521-4539` (NH4-NH3 then RHCO3), `4541-4547` (RCO2Q), `5012` (RHY consumer).

Triangulation against three sibling reactions, all of which correctly use a freshly-computed, matching-name substrate limit:
1. Litter's own immediately-preceding reaction, NH4-NH3 dissociation (`RNH4`, `:4523-4527`): `XMINN=FIONH*CN41` (`:4523`), clamp uses `-XMINN` (`:4526`). Correct.
2. Litter's own immediately-following reaction, CO2-HCO3+H dissociation (`RCO2Q`, `:4543-4547`): `XMINN=FION0*CCO21` (`:4543`), clamp uses `-XMINN` (`:4546`). Correct.
3. The soil-layer sibling of the exact same `RHCO3` reaction (`:1498-1504`): `XMINN=FIONX*CHCO31` (`:1500`), clamp uses `-XMINN` (`:1503`). Correct.

Litter's `RHCO3` is the sole outlier among these four textually-parallel locations (2 litter siblings in the same block + 1 soil-layer analog of the same reaction).

Zig: `ecosys-ng/src/surface/litter_reaction_rates.zig` (sha256 `84303EB46E1A6AD04631A4F9A38DD8B3E6C0B94C358E275E2E08F5B6E1CB262B`), `calculate()` (`:692-`), `result.carbonate_hydrogen_association_mol_per_m3 = try association(cell.carbonate_mol_per_m3, hydrogen, cell.bicarbonate_mol_per_m3, ...)` at `:747`, calling the shared kernel `ecosys-ng/src/soil/solute/ion_pairing.zig` (sha256 `8734F803FF49E60572ABD90AAE8CCBE4EB9EC3C9D676965296808F369CECDA56`), `calculate()` (`:24-41`). That kernel derives its dissociation-side substrate limit at `:39` as `parameters.substrate_limit_fraction * @min(state.free_first_mol_per_m3, state.free_second_mol_per_m3)` -- always computed fresh from the two reactant concentrations passed into that specific call. Zig has no mutable scratch variable shared across reaction calls, so it is architecturally incapable of reproducing the Fortran's "leftover value from an earlier, unrelated reaction" defect. Zig's `carbonate_hydrogen_association_mol_per_m3` call is therefore always bounded correctly (by carbonate/bicarbonate concentrations), matching the source's own (bug-free) soil-layer form and litter's own bug-free `RNH4`/`RCO2Q` siblings, not litter's buggy `RHCO3`.

## Falsifiable cause

Copy-paste-and-edit slip: the litter ion-pairing block was very likely authored by copying an adjacent reaction's clamp line and editing the equilibrium-activity terms (`ACO3Q`, `AHY1`, etc.) but missing one occurrence of the bound variable name (`XMIN` not updated to `XMINN`). This is falsifiable by inspection alone (no ambiguity: `XMIN` and `XMINN` are distinct declared variables with distinct, unrelated last-assignment sites) and is not a case of intentional reuse -- unlike `issue-045`'s "iteration-freshness" pattern or Finding 6's "restricted-band NH4 reuses potassium's limit" pattern (both of which at least reuse a *scratch value from the same chemical family*), this reuses a value from a structurally unrelated exchange site (carboxyl, a solid-phase cation-exchange quantity) to bound an aqueous carbonate-speciation reaction.

## Minimal input/state

Any litter cell with `ISALTG.NE.0` (dynamic salt equilibria enabled) and a nonzero occupied-carboxyl-site pool (`XHC1`) different in magnitude from the HCO3- substrate limit (`FION0*CHCO31`) will show a different `RHCO3` clamp bound than the corresponding freshly-computed `XMINN` would give. The defect is latent (no effect) only in the coincidental case `XMIN == XMINN`, i.e. `XHC1/BKVLW == CHCO31`, which is not guaranteed by any invariant in the model.

## Before/after results

Not run this pass (read-only, static-analysis-only assignment; no `zig build`/binary execution/test run performed, consistent with this pass's constraint). Quantifying the magnitude of the resulting H+/HCO3-/CO3-- perturbation in litter would require a matched-state kernel test comparing the Fortran's literal `XMIN`-bounded `RHCO3` against the corrected `XMINN`-bounded form -- flagged as the natural follow-up, not performed here.

## Regression test

None added this pass (read-only). Recommended for whoever next touches this area: a Fortran-side matched-state unit test is not directly constructible (no Fortran build in this checkout, per `issue-002`), but a targeted Zig-side test asserting `litter_reaction_rates.calculate`'s carbonate association bound tracks `min(carbonate, bicarbonate)` and is independent of the carboxyl-exchange state (`hc1`/occupied carboxyl sites) would directly document and lock in the already-correct, already-favorable Zig behavior described above.

## Affected evidence invalidated

None. This is a new finding; it does not overturn or supersede any prior `feature-017` finding, `TRC` row, or other issue file.

## Independent review

Not yet done (consistent with every other `feature-017` finding to date -- the dossier as a whole has had no independent reviewer pass).

## Disposition

`unresolved`. Zig's shared `ion_pairing.calculate` kernel's behavior is almost certainly scientifically correct (it matches the bug-free soil-layer analog and litter's own two bug-free sibling reactions in the same block) and is a favorable, architecturally-forced deviation from the literal buggy Fortran -- but, per the same category as `issue-018`/`issue-020`/`issue-021`/`issue-036`, this deviation has no feature-register/issue record disclosing it as intentional. This issue file is that record. No fix to the Fortran reference is proposed or warranted (it is a read-only scientific reference); no fix to the Zig implementation is proposed (it is already correct).

## Secondary, lower-confidence observation found in the same pass (not filed separately)

While tracing this range, also found that litter's dicalcium phosphate (`RPCADX`, CaHPO4) precipitation-dissolution substrate limit differs between litter's own two `ISALTG` branches: the dynamic branch (`:4589`, `XMINP=FION0*AMIN1(CCA1,CH2P1)`) bounds against `CH2P1` (H2PO4-), while the restricted branch (`:4700`, `XMIN=FION0*AMIN1(CCA1,CH1P1)`) bounds against `CH1P1` (HPO4--, the species actually appearing in this reaction's own driving-force term, `(AH1P1-AH1PQ)`). Cross-checked against soil's non-band form of the identical reaction (`:2008`, `XMINP=FIONX*AMIN1(CCA1,CH1P1)`) and soil's restricted-domain form (`:3017-3018`, `XMIN=FIONN*CH1P1`) -- both agree with litter's restricted branch (`CH1P1`); litter's dynamic branch is the sole outlier among these four sibling locations. (Soil's own band-zone mirror at `:2092` uses `CH2PB`, a separate, pre-existing band-vs-non-band question already adjacent to this dossier's Finding 4/9 territory and not investigated further here.) Zig (`litter_reaction_rates.zig:905`, `dicalcium_phosphate_mol_per_m3 = try phosphateExtent(calcium_mol_per_m3, cell.hpo4_mol_p_per_m3, ...)`) uses the HPO4 species (`cell.hpo4_mol_p_per_m3`) unconditionally for both the dynamic and restricted litter branches -- i.e. Zig again does not reproduce the Fortran's dynamic-branch-only anomaly, unifying to the majority/physically-matching form. Confidence of material impact is lower than the primary `RHCO3` finding above (this term is only a secondary upper-bound bound inside an `AMIN1` clamp, not the primary driving-force term), so it is recorded here for completeness rather than filed as its own issue, consistent with this dossier's Finding 9 precedent for similarly low-confidence copy/paste-style asymmetries noted "in passing."
