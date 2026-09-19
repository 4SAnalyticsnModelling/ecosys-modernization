# Issue 055 -- `starte.f`'s surface-litter free-ion seed (NH4/Al/Fe/Ca/Mg/Na/K) reads stale loop-carryover scalars when ISALTG=0; Zig instead zeros the same species unconditionally in both salt modes

Status: **OPEN, corrected framing 2026-09-19.** Independent closing review confirmed Part A (the legacy Fortran stale-scalar defect) but found Part B's claim about Zig ("Zig instead zeros the same species unconditionally in both salt modes") to be **substantively wrong**: it cites the wrong Zig function. See "## Closing review (2026-09-19)" below for the corrected mechanism, the actual production seeder, and why this issue is being kept open rather than closed.
Owner: unassigned
Candidate/input hashes: `f77src/starte.f` sha256 `BBE124F6809BD1720B94DDB8512FAAD5DA2FBAF7131C57A0A13E36496DC174A5` (unchanged from prior passes); `ecosys-ng/src/surface/litter_ion_complex_initialization.zig` sha256 `66CD741052B58971E899DC7957C23EC4282E279A38EF29F3035BD1A6A0A8275A`.

## Failure signature and first bad time/location/process

Not a run-time failure signature -- a source-level defect and an independent, unverified Zig divergence, both found by statement-level reading of `starte.f`'s surface-litter initialization block (`:1711-2050`), done specifically to close `feature-008`'s "surface-litter full loop beyond seeding/handoff" gap.

### Part A: real legacy defect in `starte.f` (ISALTG=0 path, the mode this project's decks use)

`starte.f`'s outer `DO 1200 I=1,366 / DO 1200 L=NU,NL / DO 2000 K=1,3` loop (`:117-1709`) recomputes the scalars `CN41,CAL1,CFE1,CCA1,CMG1,CNA1,CKA1` (among many others) fresh on every iteration that actually executes the `M=1,MRXN` convergence loop -- but only three of the nine `(K,I,L)` combinations reach that code: `K=1` at `I=1,L=1` only (once, rainfall); `K=2` at `L=1`, every `I=1..366` (irrigation, once per day); `K=3` at `I=1`, every `L` (soil, once per layer). All other combinations hit the terminal `ELSE GOTO 2000` (`:223-225`) and skip the M-loop entirely, leaving those scalars untouched.

Consequently, the last `(K,I,L)` combination in program order that actually runs the M-loop is `K=2, I=366, L=1` -- irrigation-water chemistry for the last simulated day. After `1200 CONTINUE` (`:1709`) exits the triple loop, the surface-litter initialization block (`:1711-2205`) runs once per grid cell using whatever values those scalars still hold.

At `:1948` and `:1965-1970` (`IF(DATA(20).EQ.'NO'.AND.IGO.EQ.0)THEN` block, unconditional on `ISALTG`):
```
ZNH4S(0,NY,NX)=CN41*FC(0,NY,NX)*14.0        <- stale scalar (day-366 irrigation)
...
ZAL(0,NY,NX)=CAL1*FC(0,NY,NX)               <- stale scalar
ZFE(0,NY,NX)=CFE1*FC(0,NY,NX)               <- stale scalar
ZCA(0,NY,NX)=CCA1*FC(0,NY,NX)               <- stale scalar
ZMG(0,NY,NX)=CMG1*FC(0,NY,NX)               <- stale scalar
ZNA(0,NY,NX)=CNA1*FC(0,NY,NX)               <- stale scalar
ZKA(0,NY,NX)=CKA1*FC(0,NY,NX)               <- stale scalar
```
These sit immediately beside four **correctly** array-indexed siblings in the exact same block (`:1949-1953`):
```
ZNH3S(0,NY,NX)=CN3U(NU(NY,NX),NY,NX)*FC(0,NY,NX)   <- soil surface-layer (NU) converged value
ZNO3S(0,NY,NX)=CNOU(NU(NY,NX),NY,NX)*FC(0,NY,NX)
H2PO4(0,NY,NX)=CH2PU(NU(NY,NX),NY,NX)*FC(0,NY,NX)
H1PO4(0,NY,NX)=CH1PU(NU(NY,NX),NY,NX)*FC(0,NY,NX)
```
`CN3U`, `CNOU`, `CH2PU`, `CH1PU` are the `K=3` branch's own per-layer output arrays (populated at `:1348-1399` from the converged `M=1000` soil state, one entry per layer `L`), and reading `CN3U(NU(NY,NX),NY,NX)` correctly pulls the converged **soil surface layer's** speciation. The exact same arrays exist for the stale-scalar species -- `CALU`, `CFEU`, `CCAU`, `CMGU`, `CNAU`, `CKAU` are all populated at `:1357-1363` -- but the litter-seed lines at `:1965-1970` use the bare scalars instead of `CALU(NU(NY,NX),NY,NX)` etc. This is the file's own "N parallel blocks, 1 outlier" shape (four correct array-indexed lines immediately beside seven incorrect scalar lines, all superficially doing the same kind of assignment), and it means: **for ISALTG=0 decks (confirmed the mode used by this project's Ottawa deck, per `issue-053`), the legacy oracle's surface-litter initial ammonium, aluminum, iron, calcium, magnesium, sodium and potassium content is not zero, not litter-derived, and not soil-derived -- it is whatever the irrigation-water chemistry equilibrium happened to be on the last simulated day of the previous year's `starte` call (or day 366 of whichever year STARTE last ran for), an artifact of Fortran's automatic-scalar loop-carryover, not an intended physical initialization.**

This is a genuine, confirmed, independent-of-Zig defect in the legacy Fortran itself (same "reused uninitialized/stale scalar across loop scope" family as `issue-002`'s `-auto-scalar` finding and `issue-027`'s `FIONX`, though this one is deterministic-but-wrong rather than nondeterministic-and-wrong).

### Part B: Zig's production path does not reproduce Part A -- but replaces it with a different, also-unverified behavior

`litter_ion_complex_initialization.zig`'s `initializeTransportFromTopsoil` (the only production caller, `ecosys_ng.zig:12747`) is the sole seeder of the surface-litter transport-species array. It:
1. Unconditionally `@memset`s the *entire* per-cell species array to zero (`:207`), covering species indices `0..11` -- `AqueousSpecies.aluminum, .iron, .hydrogen, .calcium, .magnesium(?), .sodium, .potassium` and whatever else occupies that index range (the free, non-complexed ions) -- for **every** cell, regardless of `salinity_enabled_by_cell`.
2. Then, only for cells with `salinity_enabled_by_cell[cell]==true`, overwrites species indices `12..41` (the hydroxide/sulfate/carbonate/phosphate-pair "complexes") from the equilibrated topsoil `ChemistryState` -- this part is a correct, verified translation of `starte.f:1981-2050`'s `IF(ISALTG.NE.0)` array-indexed branch (confirmed by direct comparison; the module's own header cites `starte.f` lines 1981-2050).

Consequence: **Zig never populates the free-ion species (indices 0-11, including the ammonium/Al/Fe/Ca/Mg/Na/K family this issue is about) for the litter cell at all, in either salt mode.** For ISALTG=0 (ISALTG the deck actually uses), this sidesteps Part A's stale-scalar defect -- arguably a cleaner outcome (zero instead of an irrigation-day-366 artifact) but undocumented as an intentional correction and not reviewed. For ISALTG!=0 (not currently exercised by any deck in this project, but a live, documented model mode per the file's own header comments), the legacy code performs a **real, separate, litter-specific cation-exchange (Gapon) + carboxyl Newton solve** (`starte.f:1726-1906`, the second of the two 1000-iteration convergence loops this pass was assigned to read) that legitimately computes non-zero `CN41,CAL1,CFE1,CCA1,CMG1,CNA1,CKA1` for the litter surface -- and Zig has **no counterpart to that solve at all**: the loop's outputs (the litter-specific converged free-ion state) are never read by any production Zig code path found this pass. This makes `starte.f:1726-1906` (the litter Gapon/carboxyl solve for the ISALTG!=0 mode) a dormant-but-genuinely-unimplemented mechanism in Zig, not merely an intentional zero-fill.

## Scientific/output impact

For this project's actual decks (ISALTG=0): low-to-moderate. Zig's zero is plausibly *more* correct than the Fortran oracle's irrigation-day-366 artifact, but this has not been reviewed or approved as an intentional `legacy-defect-corrected` disposition, and a byte-for-byte "bidirectional" comparison against the legacy oracle would show a real, explainable, non-tiny difference in litter-layer NH4/Al/Fe/Ca/Mg/Na/K at hour 1 for any deck where irrigation data is present and nonzero on the last simulated day. For a hypothetical ISALTG!=0 deck: the litter cation-exchange/carboxyl equilibrium (`:1726-1906`) would be entirely missing from Zig's litter-layer initial state -- a real scope gap, not yet materialized because no such deck has been run in this project.

## Minimal reproducer and hypothesis

Exact command/cwd/environment: none run this pass (static source read only, per this pass's read-only constraint).
Hypothesis: (1) for the Ottawa deck (ISALTG=0), `starte.f`'s `ZAL(0,..)/ZFE(0,..)/ZCA(0,..)/ZMG(0,..)/ZNA(0,..)/ZKA(0,..)/ZNH4S(0,..)` are nonzero and equal to the last day's irrigation-water equilibrium concentrations (or zero if the deck has no irrigation data at all, in which case Part A is moot for this specific deck); (2) Zig's corresponding litter-layer species are exactly zero at hour 1 for this deck.
What would refute it: instrumenting the Fortran oracle's `CN41,CAL1,CFE1,CCA1,CMG1,CNA1,CKA1` values immediately after `1200 CONTINUE` (`:1709`, before the surface-litter block runs) for a real STARTE call, and comparing against Zig's litter transport-species array for the same species/cell/hour.
Stop/resource budget: fresh issue, 0 of 3 experiments spent; filed for a future specialist pass, not chased further this pass (read-only, single-file-completion scope).

## Resolution

Cause and focused patch: not determined -- Part A is a confirmed-real legacy defect (source-only, needs no Zig change to confirm); Part B is a confirmed-real, but not yet materiality-assessed, Zig scope decision (implicit zero-fill, undocumented, and a genuine missing-mechanism for the ISALTG!=0 mode).
Before/after results: n/a -- no fix identified or applied; no source changed.
Regression added and actually executed: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: OPEN. Recommended next action: (a) confirm whether the Ottawa (or any in-use) deck's irrigation file has nonzero `CALQ/CFEQ/CCAQ/CMGQ/CNAQ/CKAQ/CN4Q` on its last simulated day, to bound Part A's actual materiality for current runs; (b) get an explicit scope decision on whether Zig's zero-fill for litter free ions should be formally adopted as `legacy-defect-corrected` (documented, reviewed) rather than left as an undocumented side effect; (c) if ISALTG!=0 support is ever required, implement the litter Gapon/carboxyl solve (`starte.f:1726-1906`) and its consumption at `:1948-1970`'s array-indexed equivalent, rather than the current unconditional zero.

**Superseded by the "Closing review" section immediately below as of 2026-09-19: item (b)'s premise ("Zig's zero-fill for litter free ions") is not what production Zig actually does. Do not act on (b)/(c) above without reading the closing review first.**

## Closing review (2026-09-19)

Independent re-verification pass, done from scratch per this session's closing-review discipline (read the cited legacy lines and the cited Zig file myself; do not trust the filer's characterization).

### Part A (legacy defect): CONFIRMED, independently re-derived

Re-read `f77src/starte.f:100-284` (outer `DO 1200 I=1,366 / DO 1200 L=NU,NL / DO 2000 K=1,3` loop header and branch dispatch) and `:1700-2205` (litter init block) from scratch. Independently traced the loop-nesting order (`I` outermost, `L` middle, `K` innermost) and confirmed: only `K=1` at `I=1,L=1`; `K=2` at every `I`, `L=1`; and `K=3` at `I=1`, every `L` reach the `M=1,MRXN` convergence loop (`:408-1400`) that (re)computes `CN41,CAL1,CFE1,CCA1,CMG1,CNA1,CKA1` -- every other combination hits `GO TO 2000` (`:224`) untouched. Given the nesting order, the **last** combination in program order that actually executes the M-loop is `I=366,L=1,K=2` (irrigation, final simulated day), exactly as filed. For `ISALTG=0`, the litter-init block's own recompute of these seven scalars (`:1726-1908`, gated `IF(ISALTG.NE.0)`) is skipped entirely, so the unconditional `SOLUTES` block at `:1948,1965-1970` reads whatever those scalars held after `1200 CONTINUE` (`:1709`) -- the stale irrigation-day-366 value, not soil- or litter-derived state. **Part A stands exactly as filed.** This is a legacy-only fact, independent of anything Zig does.

### Part B (Zig's behavior): WRONG AS FILED -- wrong function cited, wrong conclusion

Independently read `ecosys-ng/src/surface/litter_ion_complex_initialization.zig` in full (all 355 lines) and confirmed the filer's mechanical description of it is accurate as far as it goes: `initializeTransportFromTopsoil` does `@memset(transport.amount_mol, 0)` unconditionally (`:207`) and then repopulates only species indices `12..42` for salinity-enabled cells. **But this function is the seeder for a different set of Fortran lines than the ones this issue is about.** Independently re-read `starte.f:1981-2050` (the block this Zig file's own header comment cites) side by side with the module's species list: `ZSO4,ZCL,ZCO3,ZHCO3,ZALOH1-4,ZALS,ZFEOH1-4,ZFES,ZCAO,ZCAC,ZCAH,ZCAS,ZMGO,ZMGC,ZMGH,ZMGS,ZNAC,ZNAS,ZKAS,ZHYSI,H0PO4,H3PO4,ZFE1P,ZFE2P,ZCA0P,ZCA1P,ZCA2P,ZMG1P` (the *complex* species, `AqueousSpecies` indices 12-41) -- confirmed exact match, including the ELSE-branch zero-fill for `ISALTG=0` at `:2016-2049`, which the module's per-cell salinity gate correctly mirrors. **This is a correct, faithful translation of `:1981-2050` and is not a defect.** It has nothing to do with `ZNH4S`/`ZAL`/`ZFE`/`ZCA`/`ZMG`/`ZNA`/`ZKA` at `:1948,1965-1970` (indices 0-11, the free ions), which is what Part A is actually about.

Traced where those seven free-ion species are *actually* seeded in production and found `ecosys.soil_chemistry_initialization.seedSurfaceLitterFromTopsoil` (`ecosys-ng/src/soil/chemistry/initialization.zig:116-177`), called from `ecosys_ng.zig:12524` in the per-cell startup loop -- **before** `initializeTransportFromTopsoil` runs at `ecosys_ng.zig:12747`. Read this function in full: it sets `cell.ammonium_mol_per_m3 = aqueous.ammonium_non_band`, `cell.aluminum_mol_per_m3 = aqueous.aluminum`, `cell.iron_mol_per_m3 = aqueous.iron`, `cell.calcium_mol_per_m3 = aqueous.calcium`, `cell.magnesium_mol_per_m3 = aqueous.magnesium`, `cell.sodium_mol_per_m3 = aqueous.sodium`, `cell.potassium_mol_per_m3 = aqueous.potassium` **unconditionally** (outside the `if (dynamic_salts)` block, i.e. regardless of `ISALTG`), reading from `topsoil.aqueous[topsoil_cell]` where `topsoil_cell` is the converged top soil layer (`state.layerIndex(cell, 0)`). This is confirmed by the module's own test (`initialization.zig:324-347`), which asserts `ammonium_mol_per_m3`/`calcium_mol_per_m3`/etc. take nonzero topsoil-derived values regardless of the `dynamic_salts` flag.

**This is not zero, and it is not legacy's stale scalar.** It is the converged top-soil-layer equilibrium concentration -- structurally the *same* correct pattern as the four sibling lines the issue itself flagged as correct (`CN3U(NU,..)`, `CNOU(NU,..)`, `CH2PU(NU,..)`, `CH1PU(NU,..)`), generalized by Zig to all seven species instead of the four legacy got right.

Also checked whether the transport array's transient zero (from `initializeTransportFromTopsoil`) leaks into production before being corrected: `ecosys-ng/src/soil/solute/litter_soil_interface.zig`'s `exportRepresentedLitterChemistry` (`:204-231`), called every hour from `advanceLitterSoilInterface` (`ecosys-ng/src/stages/hourly_heat_water_solute.zig:8251`) before the litter-soil exchange step, rebuilds the transport-compatible working amounts for exactly these 12 species (indices 0-11) from the *chemistry cell's own current concentrations* (`cell.aluminum_mol_per_m3` etc., multiplied by carrier water), overwriting whatever `initializeTransportFromTopsoil`'s `@memset` had left there. So even the transport ledger's initial zero for these species is transient and immaterial -- it is corrected by the topsoil-seeded chemistry value before the first hourly exchange runs.

**Secondary correction, not independently chased to a conclusion:** the issue's claim that the ISALTG!=0 Gapon/carboxyl solve (`:1726-1906`) "legitimately computes non-zero `CN41,CAL1,CFE1,CCA1,CMG1,CNA1,CKA1` for the litter surface" is also imprecise. Re-reading `:1739-1744` and the `M=1,MRXN` loop body (`:1778-1906`), those seven scalars are set once *before* the M-loop (from `CCA(NU,..)` etc., matching the topsoil concentration) and are **not reassigned inside the M-loop** -- the M-loop's actual outputs are the *exchangeable* cation pools `XN41,XHY1,XAL1,XFE1,XCA1,XMG1,XNA1,XKA1`, which feed a different downstream state (`XAL(0,NY,NX)` etc. at `:2054-2062`, "EXCHANGEABLE CATIONS AND ANIONS"), not the aqueous `ZAL(0,NY,NX)` content lines this issue is about. Whether Zig has a counterpart to *that* exchangeable-pool solve was not verified this pass and remains an open question -- flagged for a future, correctly-scoped pass, not confirmed missing or present here.

### Why this stays OPEN rather than closing

Per this session's practice (cf. `issue-050`): when the filed claim is substantively wrong rather than merely imprecise, force-closing it -- especially by placing a defensive citation comment in the *wrong* file for the *wrong* reason -- would corrupt the record rather than fix it. Part A is confirmed and could stand alone, but Part B's citation, mechanism, and conclusion all need correction, and the ISALTG!=0 exchangeable-pool question raised by the secondary correction is genuinely unresolved. No code changes were made this pass (correctly: the originally-proposed fix target, `litter_ion_complex_initialization.zig`, turned out not to be the relevant seeder at all, so no citation comment was added there). A new traceability row `TRC-299` was added (existing rows `TRC-274`/`TRC-275` were not overwritten) recording this correction, still `disposition=unresolved`, pointing at the actual seeder (`soil/chemistry/initialization.zig:116-177`, `seedSurfaceLitterFromTopsoil`).

**Recommended next bounded action for whoever picks this up:** (a) Part A's materiality bound (nonzero irrigation on day 366) is still worth checking for the in-use deck; (b) get an explicit scope decision on whether `seedSurfaceLitterFromTopsoil`'s unconditional (ISALTG-independent) top-soil-concentration seed for these seven species is the intended, approved behavior -- it looks favorable and correct but has no feature-register entry disclosing it as intentional; (c) independently check whether Zig implements a counterpart to the litter's own exchangeable-cation Gapon solve (`starte.f:1726-1906` feeding `XAL(0,..)` etc.) for the ISALTG!=0 mode, which this pass did not verify.

Independent reviewer: this closing-review pass, 2026-09-19 (acting as independent reviewer for this closeout; Part A re-derived from the primary source independently of the original filer's trace, Part B re-derived by reading the actual Zig call graph rather than trusting the filed citation).
