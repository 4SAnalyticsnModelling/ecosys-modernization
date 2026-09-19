# Issue 055 -- `starte.f`'s surface-litter free-ion seed (NH4/Al/Fe/Ca/Mg/Na/K) reads stale loop-carryover scalars when ISALTG=0; Zig instead zeros the same species unconditionally in both salt modes

Status: OPEN, filed this pass (2026-09-19, statement-level read-only audit of `starte.f`'s two 1000-iteration convergence loops, `:406-1400` and `:1778-2205`, closing `feature-008`'s last named gaps)
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
