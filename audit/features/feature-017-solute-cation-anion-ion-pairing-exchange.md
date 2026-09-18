# Feature ID: FEAT-017-SOLUTE-CATION-ANION-ION-PAIRING-EXCHANGE

Status: PARTIALLY_ASSESSED (source-audit; `solute.f` is 5,248 lines; this dossier covers ~830 newly-traced lines this pass, ~16%; combined with `feature-003`'s solver-machinery/mineral-kinetics coverage, cumulative detailed coverage ~30-40% of the file)

## Scope and provenance

Legacy source: `f77src/solute.f` (sha256 `DC0056F3EDEE5670F5EB4443802E829A24A0D3BAE1DE0C4644A33A5007442324`). This dossier covers the equilibrium-chemistry equations distinct from the reaction-network Newton/Anderson solver machinery (already covered in `feature-003`) and the mineral precipitation/dissolution kinetics (already covered in `feature-008`/`issue-015`).

### 1. Cation exchange (Gapon selectivity) -- `preserved`

`solute.f:1210-1387` (CA-NH4/H/AL/FE/MG/NA/K competitive Gapon equilibrium, `FX`/`FY` charge-normalization, `TXXX`/`TXXY` proportional excess redistribution). Zig: `ecosys-ng/src/soil/solute/cation_exchange.zig` (sha256 `7E9D3B2C6FCBBEB926A3762BC52EBB067CBE175FDF8FAB0CCBE9A439DACE0EF5`), `equilibriumCharge`/`sourceOrderEquilibriumCharge` reproduce the denominator sum with the 0.333 trivalent and 0.5 divalent roots exactly; `normalizeSiteCharge` implements the FX/FY rescale; `closeSiteChargeAndConvertToIonMoles` implements the `RXN4=RXN4Q-TXXX*ABS(RXN4Q)/TXXY` proportional closure (`solute.f:1354-1365`). Non-band/band NH4 zone-fraction weighting and the strict `XCEC>ZEROS` admission gate (`:1213`, mirrored `:3351`) both preserved with explicit tests.

### 2. Carboxyl radical dissociation, soil vs. litter siblings -- `preserved`, intentional asymmetry correctly kept

Soil `solute.f:1407-1423` (`RXHC`, uses carried-state `XCOOH`, `TADCX`/`BKVLW`); litter sibling `solute.f:4483-4498` (`RXHC`, recomputes `XCOOH=CCEC0` from litter CEC each step, uses `TADC`/`FION0`). Zig: `ecosys-ng/src/soil/solute/carboxyl_exchange.zig` (sha256 `F80B52FFF9D674ECBCD0B4C0E221AF988BF1C12C38B921D7F3C2E33A54946E1F`), `calculateSourceOrderSurface` (litter) and `calculateChangeMolPerMg`/`calculateSourceOrder` (soil), division/floor/nesting order identical. **Applied the domain-asymmetry lesson**: checked whether this is a real Fortran difference or a Zig-introduced asymmetry -- confirmed the soil and litter forms genuinely differ in the Fortran itself (soil reuses evolving state; litter re-derives from CEC every call), and the Zig split correctly mirrors that real difference rather than incorrectly unifying or incorrectly diverging. `calculateChangeMolPerMg` also carries a documented `capacity_rebase` term for organic-carbon-driven site shrinkage -- an intentional, explicitly-flagged robustness addition, not a silent deviation.

### 3. Ion-pairing network (Al(OH)/Fe(OH) stepwise speciation, carbonate speciation) -- `preserved`

`solute.f:1432-1707` (`RALO1..RALO4`, Al3+->AlOH2+->Al(OH)2+->Al(OH)3->Al(OH)4-, `:1528-1568`, constants `DPAL1..DPAL4`; `RHCO3`/`RCO2Q` carbonate speciation, `:1498-1526`). Zig: `ecosys-ng/src/soil/solute/aqueous_reaction_rates.zig` (sha256 `BC6E1581D8F1CC4EBC012919BF92BAA490CEA9ECCFCE13E5DAF13DD9E8811418`, `calculate:145-180`) driving a shared kernel `ion_pairing.zig` (sha256 `8734F803FF49E60572ABD90AAE8CCBE4EB9EC3C9D676965296808F369CECDA56`). Traced term-by-term: each `reaction()` call reproduces the Fortran equilibrium-quotient/driving-force form including the valence-stepping activity-coefficient assignment (g3->g2->g1->1 as charge drops) and the no-divisor neutral-step case. `DPCO3=DPCO2*DPHCO` composition verified. The generalized `reaction()`/`ion_pairing.calculate` abstraction is a legitimate DRY refactor (same equilibrium form and sign convention preserved in each instantiation), not a semantic change.

### 4. Phosphate anion exchange, non-mineral surface sites -- `preserved`, intentional band/non-band asymmetry correctly kept

Non-band `solute.f:957-1082` (R-OH2/R-OH site protonation, H2PO4/HPO4-site exchange); band sibling `:1084-1174`. Notable: band `:1141`'s `SPH2P=SXH2P*DPH2O` (direct water-activity-product substitution) differs from non-band `:1020`'s `SPH2P=SXH2P*AHY1*AOH1`. Zig: `ecosys-ng/src/soil/solute/phosphate_exchange.zig` (sha256 `02C87C082842D30211620F9A7FA74ADB46040D80A72F600B7A3A51555DE09504`), `calculateForZone` explicitly branches non_band vs. band on exactly this formula difference (`:339-345`), with a dedicated test asserting the two zones diverge as the source does. Restricted-domain counterparts (citing `:3075-3139,3268-3307`) preserve a source quirk mixing `FIONX`/`FIONN` substrate fractions across sub-reactions -- called out explicitly in a doc comment, correctly not "fixed" to be symmetric.

## Issue-tag check

No inline issue tags found in any of the four files touched this pass; no open-issue files reference these equations. Clean.

## Not covered this pass

Silicate weathering equations; surface-charge/anion-exchange-capacity derivation; restricted band-zone mirrors of items 2-4 (`:3348-3520`); the second full litter/pond-adjacent repeat block (`:4127-5248`) beyond the carboxyl/ion-pairing slice checked here.

## Acceptance and review

Author: this session's audit fork, 2026-09-18. Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Four equation groups `preserved`, including two cases where an apparent asymmetry was correctly identified as an intentional, faithfully-preserved Fortran design choice rather than a translation gap -- a useful counterpoint to `issue-017`/`issue-018`'s genuine asymmetries found elsewhere this session. **No open gaps found in this pass.**
