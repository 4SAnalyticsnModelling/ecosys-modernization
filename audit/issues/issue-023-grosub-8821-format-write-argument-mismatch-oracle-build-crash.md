# Issue 023 -- grosub.f:12766 debug WRITE is missing the IYRC argument required by shared FORMAT 8821; crashes any strict-runtime (gfortran) build on the first harvest-day event

Status: RESOLVED and CONFIRMED (scratch-only patch applied and verified via a full 30-year successful production run; not a science/production defect since the statement is diagnostic-only and Zig has no counterpart)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979
Legacy source anchor: `f77src/grosub.f` sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`

Failure signature and first bad time/location/process:
Running the independently-built gfortran oracle (see `audit/runs/run-002-independent-gfortran-oracle-build-2026-09-18.md`) against the isolated, decontaminated Ottawa deck crashed on day 286 of simulated year 1998 (the first of 6 simulated years) with:
```
At line 12771 of file grosub.f (unit = 6, file = 'stdout')
Fortran runtime error: Expected INTEGER or UNSIGNED for item 9 in formatted transfer, got REAL
(A8,8I4,30E12.4)
```

Root cause, found by direct inspection: `grosub.f:12766-12771` is a live (uncommented) debug trace statement:
```fortran
      WRITE(*,8821)'CASNC0',I,J,NFZ,NX,NY,NZ,NB
     2,CASNC(0,NZ,NY,NX),CSNCL(0,NZ,NY,NX),CASNC(0,NZ,NY,NX)
     2/CSNCL(0,NZ,NY,NX),ZCAQ(NB,NZ,NY,NX),CAHVX
     3,CAHVC(NZ,NY,NX),HVSTC(NZ,NY,NX),CAHVC(NZ,NY,NX)
     4/HVSTC(NZ,NY,NX),FZCAC,FCSNC0,FCSNCH,WTSHT(NZ,NY,NX)
     4,HVSTCX(NZ,NY,NX)
```
supplying only **7** integers (`I,J,NFZ,NX,NY,NZ,NB`) against the shared `FORMAT` statement's `8I4` spec:
```fortran
8821  FORMAT(A8,8I4,30E12.4)
```
Its own **commented-out sibling three lines below** (`:12772`, `SOSNC0` trace) uses the *correct* 8-integer argument list, including the leading `IYRC` (simulation year) this one is missing:
```fortran
C     WRITE(*,8821)'SOSNC0',IYRC,I,J,NFZ,NX,NY,NZ,NB
```
i.e. the live `CASNC0` WRITE is a copy of this same pattern with `IYRC` accidentally dropped -- a plain omission, not an intentional design choice. Because the FORMAT still expects 8 integers, the 8th `I4` slot silently consumes the WRITE's 9th argument (`CASNC(0,NZ,NY,NX)`, a REAL) as if it were an integer. Under ifort's (the original, unavailable toolchain) formatted-I/O runtime this kind of type mismatch is commonly tolerated (reinterpreted/garbage-printed without aborting); gfortran 16.1's runtime enforces strict type-matching on formatted transfers and aborts instead.

The triggering condition is `DHVSTC.GT.0.0` (`:12760`) -- a harvest/litterfall-carbon-flux gate -- which fires on the deck's first crop-harvest event, explaining why the crash lands on a specific simulated day (286) rather than at hour 1.

Scientific/output impact: **none** -- this is a `WRITE(*,...)` debug trace to stdout (unit 6), not a model-state computation; no state variable is read from or written to by this statement. It has no Zig counterpart to check for equivalence (grep of `ecosys-ng/src` for `CASNC0`/similar found nothing, as expected for a stdout debug print). This is purely a **toolchain-compatibility blocker for building a runnable oracle**, not a science gap.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: `<scratchpad>/legacy-run/ecosys_x.exe < <scratchpad>/legacy-run/stdin.deck` (gfortran 16.1.0 build, see run-002). Reproduced once; failure signature is deterministic (same day, same message) given the same deck.
Hypothesis: restoring the missing `IYRC` argument (matching the commented-out sibling's pattern exactly) resolves the FORMAT/argument-count mismatch without altering any computed state.
Stop/resource budget: resolved on the first experiment; root cause was directly legible from the source (a commented-out sibling showing the intended, correct form immediately adjacent), no multi-experiment diagnosis loop needed.

## Experiments
Experiment 1: patched a **scratch-only copy** of `grosub.f` (never the tracked `f77src/grosub.f`) at line 12766, changing:
`WRITE(*,8821)'CASNC0',I,J,NFZ,NX,NY,NZ,NB` -> `WRITE(*,8821)'CASNC0',IYRC,I,J,NFZ,NX,NY,NZ,NB`
Recompiled that one file and relinked the oracle binary. **Result: CONFIRMED FIXED.** The full 30-simulated-year Ottawa deck (see `audit/runs/run-002-independent-gfortran-oracle-build-2026-09-18.md`) subsequently ran to completion (exit code 0, 1,138 output files produced) with no recurrence of this or any other Fortran runtime error -- the harvest-day trigger condition (`DHVSTC.GT.0.0`) fires repeatedly across the 30-year rotation (once per crop cycle in each of the 5 repeats) and never crashed again after the patch, confirming the fix is complete and correct, not merely a one-instance workaround.

## Resolution
Cause and focused patch: missing `IYRC` argument in a diagnostic WRITE statement, restored to match its own commented-out sibling and the shared FORMAT's 8-integer spec. Applied only to the isolated scratch oracle-build copy of `grosub.f` -- **the tracked `f77src/grosub.f` is untouched**, per contract (preserve historical build artifacts as-is; a fixed-up build is a "separately named diagnostic build").
Before/after results: before = deterministic crash at day 286/year1 every run; after = pending confirmation via re-run.
Regression added and actually executed: n/a (Fortran-oracle-side toolchain fix, not a Zig regression target).
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: this is a legacy-source defect confined to a dead-code-path debug print; fixing it in a diagnostic oracle build is analogous in spirit to the already-applied `EXTERNAL SPLIT` gfortran-16-compatibility patch (also scratch-only, also required only because of stricter modern-toolchain behavior, also without touching tracked sources). Recommend documenting this as a known, permanent required patch for any future gfortran-oracle rebuild of this codebase (alongside `EXTERNAL SPLIT` and the two input-deck contamination strips), rather than something to "fix" in the tracked legacy source itself (out of scope -- the tracked `f77src` is a preserved historical artifact per `PROJECT_CONTRACT.md`).

## Note for other sessions/reviewers
This also strongly suggests the OneDrive reference project's own gfortran oracle run -- documented as "terminated externally partway through day 286 with no Fortran error recorded" -- likely hit this exact same crash (same deck, same day-286 harvest event, same gfortran strict-I/O behavior) and their process/log-capture simply did not retain the stderr Fortran runtime error text, rather than being genuinely killed by an external wall-clock limit before any error occurred. Not confirmed (their raw job logs were not re-examined for this finding), but worth flagging if that project's docs are ever revisited.
