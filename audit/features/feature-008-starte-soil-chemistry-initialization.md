# Feature ID: FEAT-008-STARTE-SOIL-CHEMISTRY-INITIALIZATION

Status: PARTIALLY_ASSESSED (first-pass source-audit; `starte.f` is 73KB/2205 lines; the two 1000-iteration convergence loops NOT traced, only their seeding inputs)

## Scope and provenance

Legacy source: `f77src/starte.f` (sha256 `BBE124F6809BD1720B94DDB8512FAAD5DA2FBAF7131C57A0A13E36496DC174A5`). **Identity verified, not assumed from the filename**: header states "THIS SUBROUTINE INITIALIZES ALL SOIL CHEMISTRY VARIABLES" (`:3`) -- gas solubility/dissociation constants, ion-pair speciation, phosphate protonation/anion-exchange, cation-exchange (Gapon), precipitate pools, carboxyl (SOC) proton exchange, gaseous/aqueous gas-phase state, across three water sources (K=1 rainfall/K=2 irrigation/K=3 soil).

### 1. Gas solubility coefficients -- `unresolved` (citation lineage, not a science gap)

`starte.f:32-35,235-250`, e.g. `CCO21=CCO2M*SCO2X/EXP(ACO2X)*EXP(0.843-0.0281*ATCA)`. Zig: `ecosys-ng/src/soil/water/gas_solubility.zig` (sha256 `8EA6EBEB4D36B009672F201185D300F962E8B78B9C132E0C70375B9F65C8B32A`, `:90-109`) implements the identical exponential form with all five coefficient pairs (`0.843/0.0281`, `0.597/0.0199`, `0.516/0.0172`, `0.456/0.0152`, `0.897/0.0299`) matching exactly. **But** this Zig file's own header cites `hour1.f:4092-4106` as its source, not `starte.f`, and is tagged "never production bound... architecturally superseded... reachable only from tests." No Zig module was found citing `starte.f:227-250` by line number the way sibling functions cite their sources. **Disposition: `unresolved` (citation-lineage gap, equation form is not in doubt)** -- flag for whoever owns the module-index/citation cleanup, not a science defect.

### 2. Solubility products / dissociation constants and hydroxide-mineral sentinels -- `preserved`, one candidate concern flagged

`starte.f:53-65` (`DPH2O,SPALO=1.9E-21,SPFEO=6.3E-26,DPH3P=7.5,DPH2P=6.2E-05,DPH1P=4.8E-10`), used at `:265-274`: `IF(CALZ.LT.0.0) CAL1=SPALO/COH1**3 ELSE CAL1=AMIN1(CALZ,SPALO/COH1**3)`. Zig: `ecosys-ng/src/soil/chemistry/initialization.zig` (sha256 `57BE2C7F2E7592786B381331C604FBC03644F4323AA2B1047E63F4DF16F12B05`), test at `:441-449` asserts the exact constants; `resolveProfileEquilibriumSentinels` (`:452-476`, citing `starte.f:265-273`) reproduces the negative-sentinel branch (`CAL1=SPALO/COH1**3`) correctly.

**Candidate concern**: the Fortran's `ELSE AMIN1(CALZ,SPALO/COH1**3)` -- capping a *non-negative* input at the hydroxide-mineral solubility ceiling -- was not found applied in this specific Zig function (it only overwrites when input is negative). **Investigated same session**: `reaction_surface_minerals.zig` has an active `aluminum_hydroxide_1..4`/`iron_hydroxide_1..4` mineral field system, confirming the runtime coupled reaction network models Al/Fe hydroxide precipitation/dissolution continuously, not just at init -- a supersaturated init value would very plausibly be driven toward equilibrium by the very next hour's reaction solve regardless of whether it was pre-clamped at init. This is a weaker form of "resolved elsewhere" than the HOUR1-002/SOLUTE-042 pattern (same session, both confirmed false alarms) -- **not independently verified this pass whether the runtime reaction network's timestep is fast enough, or whether an unclamped supersaturated init value could cause a transient issue in hour 1 before the reaction network catches up.** **Disposition: `unresolved` (low-confidence-of-impact; plausible but unconfirmed runtime self-correction)** -- recommend a targeted follow-up: trace `seedProfilePrimaryState`'s actual callers and check whether a synthetic supersaturated-Al/Fe test case produces a bounded hour-1 transient or a real divergence.

### 3. Initial phosphate speciation -- `preserved`

`starte.f:324-329` (four-species Boltzmann-style partition, K!=3 branch). Zig: `initialization.zig:478-505`, `initialPhosphateSpecies`, cites `starte.f:323-335`, rewritten in log-domain to avoid overflow -- verified term-by-term algebraically equivalent, not a physics change.

### 4. Phosphate anion-exchange (surface-site) initialization -- `preserved`

`starte.f:330-357` (K=3 branch, `FXH2/FXH1/FXH0/FXP2/FXP1`). Zig: `initialization.zig:593-620`, `seedProfilePhosphateSurfaceSites`, cites `starte.f:332-360`. Site-weight construction and `adsorbed_total=min(AEC,total_P)`/`hpo4_to_h2po4_ratio` reduce to the same `FXP2=1/(1+ratio)` form.

### 5. Carboxyl (SOC) proton-exchange initialization -- `preserved`; the associated SOLUTE-042 concern is CLOSED

`starte.f:402-403,1726-1734` (`XCOOH=max(ZEROC,COOH*1e-6*ORGC/BKVLX)`, `XHC1=XCOOH*min(1,CHY1/DPCOH)`). Zig: `soil/chemistry/carboxyl_exchange_initialization.zig` and the surface-litter equivalent, citing `starte.f` line 403 directly, test "STARTE carboxyl occupancy seed reproduces source line 403" (`initialization.zig:872`).

A dated in-code note (`initialization.zig:951-987`) describes `SOLUTE-042`: production once ran `solute.f`'s looser substrate-limit form (`XMIN=FIONX/BKVLW*XHC1`, ignoring H+ activity, `solute.f:1418`) on the *initialization* path instead of `starte.f`'s own throttled form (`XMIN=FION*min(XHC1,AHY1)`, `starte.f:813`), permitting a carboxyl step 250x larger than the source's initial equilibrium allows in acidic, site-rich horizons -- described as the quantitative basis of four blocked wave-1 examples. **Checked same session, confirmed CLOSED**: `ecosys_ng.zig:9957-9959` sets `use_starte_hydrogen_substrate_cap=true` with the comment "STARTE's carboxyl hydrogen substrate cap is active only during initialization and remains inside every solver iteration" -- i.e. production now applies the STARTE-throttled cap at every solver iteration, not just at init. **Disposition: `legacy-defect-corrected`, closed.**

## Not covered this pass

The two 1000-iteration Newton-style convergence loops (`starte.f:406-1400`, `:1778-2205`) -- only their seeding inputs traced, not the iteration/convergence logic itself (likely `soil/solute/reaction_solve.zig` and related files, located but not read in depth). Cation-exchange (Gapon) partitioning detail (`:715-763`). Gas/mineral N,P state-variable block (`:1401-1710`) beyond structural skim. Surface-litter full loop (`:1711-2205`) beyond the seeding/handoff portion. K=1/K=2 (rainfall/irrigation) branches (`:121-163`) read but not matched to Zig.

## Acceptance and review

Author: this session's audit fork, 2026-09-18; SOLUTE-042 status independently verified by the coordinating session (this file). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Three items `preserved`, one `legacy-defect-corrected` (closed), two `unresolved` (one citation-lineage only, one low-confidence Al/Fe transient concern needing a targeted follow-up).
