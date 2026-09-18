# Run 002 -- Independent gfortran-built Fortran oracle for this checkout (build succeeded; multi-year execution attempt in progress)

Date: 2026-09-18
Context: follow-up to `audit/issues/issue-002-fortran-toolchain-substitution.md`'s "Follow-up" section. Per user decision ("Check OneDrive reference first"), confirmed the mature OneDrive reference project has a working gfortran-based build methodology for this exact legacy source tree, then reproduced that methodology independently against **this checkout's own** `f77src`/`f77example`, in an isolated scratch location, without ever modifying tracked files.

## Build

Isolated scratch dir (not `f77src`): `<scratchpad>/legacy-build/`. Populated from a plain copy of `D:\ecosys-modernization\f77src\*.f,*.h,*.c` (97 files).

**New finding, not previously documented**: `f77src` contains a **stray, uncompiled duplicate** -- `redist_utf8.f` -- which is not part of `f77src\makefile`'s `SRCS` list (the makefile lists exactly 40 `.f` modules; the directory has 41). A first build attempt that globbed all `*.f` files failed at link time with `multiple definition of 'redist_'` (both `redist.f` and `redist_utf8.f` define the same `redist_` symbol). Rebuilding from exactly the makefile's 40-file `SRCS` list (excluding `redist_utf8.f`) resolved this. This is a source-tree hygiene issue, not a science gap -- `redist_utf8.f`'s relationship to `redist.f` (byte-for-byte duplicate vs. a divergent variant) has not been diffed and is out of scope for this run record; flagging for a future dedicated check.

Compiler: `gfortran (MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r2) 16.1.0` -- exact version match to the OneDrive reference project's own documented build.

Flags (identical to OneDrive's documented `PROVENANCE.md` recipe): `-O2 -std=legacy -cpp -ffixed-form -ffixed-line-length-72 -fdefault-real-8 -fdefault-double-8 -falign-commons -fautomatic -fmax-stack-var-size=0 -fprotect-parens -fno-associative-math -fno-reciprocal-math -ffp-contract=off -fno-frontend-optimize -fallow-argument-mismatch`, plus the same `EXTERNAL SPLIT` compatibility declaration inserted into a scratch **copy** of `soil.f` (gfortran 16 otherwise treats `SPLIT` as an intrinsic and rejects the legacy 10-argument call to the user-defined `SPLIT` subroutine). `splits.c`/`splitp.c` compiled separately via `gcc -O2 -c`.

**Result: build succeeded.** Two harmless warnings only (`watsub.f:5774,5780` -- unary-minus-following-arithmetic-operator extension warnings, purely a parser-leniency note, not a correctness concern). Output binary: `ecosys_oracle.exe`, 38,966,941 bytes, SHA-256 `B1DD9E67CDCB37DFCD8B4BEF73C6361833ECD3C590DEFB5B99A85B66412C64C3`. (For comparison, the OneDrive reference binary built from their own, slightly different source snapshot is 38,971,210 bytes -- consistent near-match, same compiler/flags/toolchain, expected minor size difference given this checkout lacks whatever divergent history led to their exact byte count.)

## Input-deck preparation (isolated copy, `f77example` untouched)

Isolated scratch dir: `<scratchpad>/legacy-run/`, populated only with the actual legacy input files needed by `runottawa` (all `f25*`, `gbf*h`, `maiz33`/`soyb33`/`swhe33`, `restart.manifest`, `runottawa`) -- deliberately excluding the Zig `.bin` checkpoint files and the stray date-prefixed leftover hourly-output files already proven (issue-002 CORRECTION) to be misplaced ecosys-ng artifacts, not legacy inputs.

**Confirmed the same "already extended for ecosys-ng" input contamination OneDrive's own `PROVENANCE.md` documented having to strip, present in this checkout's `f77example` too**:
1. `f25sol98` line 4: an injected `van_genuchten_inflection_pressure_head_m,0,0,0,0,0,0,0,0,0,0 # zero requests Carsel-Parrish texture estimates` record inserted into what is otherwise a pristine fixed-format legacy numeric block (55 lines -> 54 after removal).
2. Each of the six yearly option files referenced by `runottawa`'s stdin deck (`f25y98`,`f25y99`,`f25y00`,`f25y01`,`f25y02`,`f25y03`) has a trailing `weather_phase,-0.25,0.0001 # snowfall temperature threshold C, minimum snowfall water equivalent m` record appended (12 lines -> 11 after removal in every case).

Both records were stripped from the isolated scratch copies only (never touching the real `f77example`), using the exact same two-fix recipe OneDrive's own documentation used -- this independently corroborates that OneDrive's characterization ("this example had already been extended for ecosys-ng and was not a pristine legacy snapshot") applies identically to this checkout's own copy of the example deck, not just theirs.

## Execution attempt

`ecosys_oracle.exe` (renamed to `ecosys_x.exe` for PowerShell invocation -- PowerShell refuses to run a bare `.x`-extension file mid-pipeline, treating it as a document rather than an executable) launched against the isolated, decontaminated deck via the exact stdin sequence extracted from `runottawa`'s heredoc (6-year Ottawa Cool-Temperate Maize-Soybean run, 1998-2003).

**Observed behavior**: the binary runs and is genuinely making progress (confirmed via direct log-file byte-growth checks over multiple short intervals -- not a hang), but is extremely slow and extremely verbose during `starte.f`'s soil-chemistry initialization phase (the two ~1000-iteration Newton-style convergence loops already documented in `audit/features/feature-008-starte-soil-chemistry-initialization.md`). The legacy code prints a full diagnostic dump (`RPALPX1`,`RPFEPXI`,`APATI`,`RXH2PI`,`RYH2PI` state vectors) every 100th Newton iteration, for every grid cell, for every K-branch (rainfall/irrigation/soil) -- this print is unconditional in the Fortran source (not gated behind a debug flag), so it fires on every run of this binary, not just this attempt. This independently corroborates why the OneDrive reference project's own gfortran run was "externally terminated" rather than run to natural completion -- the same verbose-and-slow initialization behavior would affect any gfortran build of this codebase, not something specific to this checkout.

**Status at time of writing: still running in the background** (task id tracked in this session only, not durable across sessions). This run record will be updated with final results (completion, a Fortran runtime error, or an explicit decision to externally terminate after a bounded observation window, mirroring OneDrive's own documented precedent) once the run reaches a concluding state.

## Disposition and next steps
- Build methodology: **reproducible and now documented for this checkout specifically** (not just inferred from OneDrive's). This directly unblocks `issue-002`'s "no Fortran oracle at all" blocker -- a genuine, independently-built binary now exists for this exact source tree.
- `redist_utf8.f` stray duplicate: flagged for a follow-up diff/disposition decision; not blocking.
- Execution: in progress; given the demonstrated per-grid-cell initialization verbosity/slowness, a full 6-year run may take substantially longer than is practical to await synchronously. If it does not reach usable multi-day output within a reasonable observation window, the plan is to explicitly document a bounded partial result (mirroring OneDrive's own "partial derived comparison artifact" framing) rather than silently waiting indefinitely or fabricating a completion claim.
