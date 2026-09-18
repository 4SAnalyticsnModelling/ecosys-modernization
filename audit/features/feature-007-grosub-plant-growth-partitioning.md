# Feature ID: FEAT-007-GROSUB-PLANT-GROWTH-PARTITIONING

Status: PARTIALLY_ASSESSED (first-pass source-audit; `grosub.f` is the single largest legacy file, 525KB/13,177 lines, single monolithic subroutine; only ~20% read in depth this pass)

## Scope and provenance

Legacy source: `f77src/grosub.f` (sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`), single subroutine `grosub(...)`, header: "THIS SUBROUTINE CALCULATES ALL PLANT BIOLOGICAL TRANSFORMATIONS." Structural map (banner grep, whole file): includes/params (1-300); living-population transformations + organ carbon partitioning by phenological stage (307-960); C4/C3 carboxylation/stomatal effects (960-1710); maintenance/growth respiration split (1710-2000); leaf/sheath/stalk remobilization and litterfall at senescence, canopy-layer leaf-area allocation (2000-4700); seasonal-storage remobilization, grain fill (4697-5700); root growth, root respiration allocation, grazing demand (5708-8748); grazing rebalancing, tillage-driven litterfall, dead-branch/root/nodule/standing-dead litterfall (8748-12574+); tail unread (~12574-13177).

**Depth-read this pass:** ~2,500-2,700 of 13,177 lines (~20%) -- organ partitioning, respiration split, start of leaf-remobilization cascade. **NOT depth-read:** root growth (~3,000 lines, contains `BIND-GROSUB-506` per tag sweep below), grazing, all tillage/standing-dead litterfall (~4,400+ lines).

## Addendum 2026-09-18 (same session, follow-up pass): root-growth section (`:5708-6595`, ~29% of that 3,040-line block) -- five more items traced, all `preserved`, one `legacy-defect-corrected` needing a paperwork fix

1. **Root porosity/O2-stress acclimation** (`PORT`, `:5963-5966`) -- Zig `plant/root/plant_root_porosity.zig:45-69` (`adapt`), constants `0.75/0.1/0.01` match exactly, unit tests pin numeric values. `preserved`.
2. **Growth-respiration cascade** (`CNPG->RCO2RM->RMNCR->CGROR->GRTWTG`, secondary `:6066-6197`, primary `:6492-6595`) -- Zig `plant/root/plant_root_metabolism_growth.zig:208-281`. `preserved`, **with one real, correctly-fixed but under-documented item**: `grosub.f:6546-6553` applies the `RCO2RM` cap using a **stale prior-axis `RMNCR`** (the cap precedes `RMNCR`'s reassignment for the current axis, a genuine legacy traversal-order artifact, independently re-verified). Zig deliberately uses the *current* axis's value instead (`plant_root_metabolism_growth.zig:238-241`, gated by `cap_substrate_to_current_maintenance`, verified live at `stages/root_processes_metabolism.zig:406-407`). No formal issue/feature-register entry existed for this correction beyond the inline comment -- filed as `audit/issues/issue-016-root-metabolism-stale-rmncr-cap-order-needs-record.md`. **Disposition: `legacy-defect-corrected`** (already fixed and live; the gap was paperwork only).
3. **Secondary root length extension** (`GRTLGL`, `:6399-6403,6417`) -- Zig `plant_root_metabolism_state_update.zig:441,582-586`, exact term correspondence. `preserved`.
4. **Secondary root axis-count growth** (`RTN2`, `:6424-6427`, distinct from the already-closed `BIND-GROSUB-506`) -- Zig `plant_root_metabolism_state_update.zig:62-77` (`sourceOrderSecondaryAxisCount`), self-documented "GROSUB 6424-6427," exact algebraic match including the quadratic-in-`RTFQ` two-term sum. `preserved`.
5. **Root senescence recycling/litterfall** (`RCCC/RCCN/RCCP/SNCR/RCCR/RCZR/RCPR/FSNC2`, `:6210-6337`) -- Zig `plant_root_metabolism_litter.zig:89-172,429-436`, term-for-term match including the woody/nonwoody litterfall split. `preserved`.

**Remaining scope, still not covered**: `grosub.f:6595-8748` (~71% of the root-growth block) -- primary-root branch continuation past line 6595, layer-crossing propagation (cited at `plant_root_metabolism_state_update.zig:568` pointing to `grosub.f:7080/7288/7332`), and any root death/turnover or root-to-shoot ratio logic beyond what's sampled. Plus the still-untouched grazing and tillage/standing-dead litterfall sections (`:8748-13177`, ~4,400+ lines).

### 1. Organ carbon partitioning (`PART(1:7)`) -- `grosub.f:560-687`

Builds leaf/sheath/stalk/reserve/husk/ear/grain fractions branching on floral induction/anthesis/grain-fill-onset flags, keyed by determinacy type and internode-extension capability. E.g. `PART(1)=AMAX1(PART1X(IDTYP),PART1-FPART1(IBTYP)*TGSTGI(NB))`; post-grain-fill indeterminate: `PART(3)=0.125*PARTS`, `PART(7)=0.625*PARTS`.

Zig: `ecosys-ng/src/plant/partition/organ.zig` (sha256 `1A2EF229FE627A30125709CD0124230D4B91D176543D01A656F130E7B40E532F`), `calculate` (`:70-120`), doc comment explicitly: "Exact GROSUB PART(1:7)... leaf, sheath, stalk, reserve, husk, ear, grain" (`:68-69`). Four-branch stage logic and reproductive coefficient splits (0.125/0.625, 0.75/0.25) match verbatim (`:96-105`). `compatibilityParameters()` (`:26-37`) hardcodes `initial_leaf_fraction=0.75`/`initial_sheath_fraction=0.25` matching `PARAMETER(PART1=0.75,PART2=0.25)` (`grosub.f:84`).

**Disposition: `preserved`.** Note: `PART1X`/`PART2X` are PFT-file-driven in Fortran; Zig's `minimum_leaf_fraction_by_determinacy={0.02,0.05}` is baked into `compatibilityParameters()` -- likely a deliberate default-PFT snapshot, NOT independently verified against a live PFT input file this pass.

### 2. Growth vs. maintenance respiration split -- `grosub.f:1742-1791`

`RCO2C=VMXC*CPOOL*TFN3*CNPG*FDBKX*WFNSG*XNFH*CCPOLB/(CCPOLB+CCKM)`; `RMNCS=RMPLT*TFN5*WTSHXN*XNFH`; `RCO2X=RCO2C-RMNCS`; `RCO2Y=max(0,RCO2X)` (growth resp.); `SNCR=max(0,-RCO2X)` (excess maintenance -> senescence driver).

Zig: `ecosys-ng/src/plant/growth/shoot_growth_metabolism.zig` (sha256 `0AEBE57F72FA8082E1917C080EC3786AD25AF3246B786C6BAF62252ABF608C76`), `calculate` (`:502-539`), pre-emergence variant at `:283-343` cited to `grosub.f:1866-2063`. Constants verified identical: `maximum_mobile_carbon_oxidation_per_h=0.015`=`VMXC`; `mobile_carbon_respiration_half_saturation=0.025`=`CCKM`; `maintenance_respiration_g_c_per_g_n_h=0.010`=`RMPLT`. Term-for-term match: `substrate_respiration`(`:511-512`)<->`RCO2C`; `maintenance`(`:513`)<->`RMNCS`; `excess_growth_respiration=max(0,substrate-maintenance)`(`:514`)<->`RCO2Y`; `excess_maintenance=max(0,maintenance-substrate)`(`:515`)<->`SNCR`. `maintenanceWaterFraction` doc comment matches the `IGTYP.EQ.0.OR.IWTYP.EQ.2` branch at `grosub.f:1747-1751` exactly.

**Disposition: `preserved`.** No sign/unit/indexing concerns found.

### 3. Leaf senescence remobilization -- `grosub.f:2551-2588`

`RCCLX=WGLFX*RCCC`; `RCZLX=WGLFNX*(RCCN+(1-RCCN)*RCCC)`; `RCPLX=WGLFPX*(RCCP+(1-RCCP)*RCCC)` (gated `WGLFX>ZEROP`); recycle fraction `FSNCL` capped by `WGLF(K)/WGLFX` when requested mass exceeds available.

Zig: `ecosys-ng/src/canopy/leaf/senescence_snapshot.zig` (sha256 `0D783F08E8A1917BFD5A680E7E426902F8463A8A6B4BABD97DB441BBBFAFC9E9`), `prepare` (`:36-90`), explicitly cited "grosub.f lines 2561--2588," reproduces the C/N/P recycling formulas and `FSNCL`-equivalent cap exactly. File header: "**PRODUCTION BOUND.** `GROSUB-SENESCENCE-001` is implemented by `photosynthesis_node_layer.state_updateSelectedNodeSenescence`."

**Disposition: `preserved`** (per the project's own `GROSUB-SENESCENCE-001` tag, closed/production-bound).

## Issue-tags folded in (not independently re-derived)

- **`GROSUB-SENESCENCE-001`** -- closed, production-bound (item 3 above).
- **`BIND-GROSUB-506`** (`src/plant/root/primary_root_axis_scaling.zig:133-176`) -- **candidate `legacy-defect-corrected`**, in the unread root-growth section (`grosub.f:5708+`): a prior Zig binding read `@max(1, axis_primary_count)` (a hardcoded constant) where the Fortran computes a per-layer `RTN1`/`XRTN1` scaling; a regression pins that the corrected binding diverges from the old constant-1 substitution by an order of magnitude and grows with root mass/population. **Not independently verified against `grosub.f:5708+` this pass** -- flagged for the root-growth follow-up audit.
- **`STORAGE-REMOB-PARTITION-SUM-001`** (`src/plant/growth/storage_remobilization_test.zig:161-170`) -- a regression tightening a validation check (one-sided `sum>1` to two-sided `|sum-1|>1e-12`) catching silent carbon leakage in shoot/root partition fractions during storage remobilization (`grosub.f` ~4697-4900 region, not deep-read).

Neither tag's current open/closed status was cross-checked against `docs/discrepancy_register.md` (not present in this `D:` checkout, per issue-005's established pattern) -- out of scope for this pass.

## Not covered this pass

Root growth and root respiration allocation (`grosub.f:5708-8748`, ~3,000 lines, contains `BIND-GROSUB-506`); grazing demand/rebalancing; tillage-driven litterfall; dead-branch/root/nodule/standing-dead litterfall (`:8748-13177`, ~4,400+ lines); C4/C3 carboxylation and stomatal water-deficit sections (`:960-1710`); seasonal-storage remobilization/grain fill detail beyond the partition-sum tag (`:4697-5700`).

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (first-pass, ~20% depth coverage, explicitly scoped). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Three equations `preserved`; one candidate `legacy-defect-corrected` (`BIND-GROSUB-506`) not yet independently verified; ~80% of this file (by line count) remains a follow-up audit target, notably the entire root-growth and litterfall/tillage sections.
