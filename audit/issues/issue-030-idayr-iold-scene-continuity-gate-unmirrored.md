# Issue 030 -- `exec.f`/`soil.f`/`reads.f`'s `IDAYR`/`IOLD` scene-continuity and re-initialization-suppression gate has no confirmed Zig counterpart, self-flagged as unmeasured in ng's own code

Status: OPEN
Owner: unassigned
Candidate/input hashes: `f77src/exec.f` sha256 `B588CAE65E01607DB18DD2DFED8751CFB23FB2D0D2AFC2EC1B88E9CA99BFF8B4`; `f77src/soil.f` sha256 `E2C5A5B3AD972907F31336C066019E87D22B9BCC5B50E117AD62B887861EBA0A`; `f77src/reads.f` sha256 `BB1D5A79CF51061CCEE98670B96CF296E061E05ADC4ECEC221C3E53C7DEAE139`; `f77src/routs.f` sha256 `EC640E50BA6A35CC8659DC78967F475B9762B2D34DD2B19CEC2EFB3FE7F7C24F`; `ecosys-ng/src/ecosys_ng.zig` sha256 `98F15D0CA238A8D2F5020C7871210C2B56A074DA330708003714351C86B6DECE`

Raised while auditing `f77src/exec.f` for `audit/features/feature-023-exec-daily-mass-balance-progress-and-reinit-gate.md` finding 3.

## Confirmed content and location

Legacy: `exec.f:94-99` sets, unconditionally, every simulated day: `IDAYR = (IDAYR.LT.0) ? LYRX+IDAYR : I` and `IOLD = I`. `soil.f:285-289` (immediately after `CALL EXEC(I)`, `soil.f:278`) tests `IF(NYR.NE.1.AND.IDAYR.NE.IOLD)` to decide whether to re-read state from checkpoint (`CALL ROUTS`/`CALL ROUTP`). The same `IDAYR.NE.IOLD` comparison also gates full cold-start re-initialization at the top of a new scene: `soil.f:39` (`STARTS`), `soil.f:78` (`STARTQ`), `soil.f:106` (`STARTE`), each as `IF((DATA(20).EQ.'YES'.AND.IGO.EQ.0).OR.IDAYR.NE.IOLD)THEN`.

`reads.f` is called once per scene (`soil.f:32`, before the day loop) and sets the scene-boundary sentinel that this comparison actually tests against: `reads.f:760` `IDAYR=MIN(ISTART-1,ILAST)` with `NYR=0` for a mid-year scene end, or (`reads.f:763-767`) `IDAYR=LYRX` (`LYRX`=days in the previous year) with `NYR=1` and `IYRR=IDATA(3)-1` for a year-boundary scene end. Because `exec.f` re-syncs `IDAYR=IOLD=I` every day *during* the day loop, `IDAYR` only ever differs from `IOLD` right after a fresh `reads.f` call at a new scene's start -- i.e. this is the mechanism by which a multi-scene deck can tell "this new scene picks up exactly where the last one's `exec.f` calls left off" (skip re-init, preserve continuous state) from "this new scene is discontinuous" (force re-init via `STARTS`/`STARTQ`/`STARTE`, or force a checkpoint reload via `ROUTS`/`ROUTP`).

**Zig's own code explicitly documents the absence of an equivalent gate.** `ecosys-ng/src/ecosys_ng.zig:312-316`, inside `recordHourStageExecution` (a stage-execution census/measurement instrument, not a science-path branch):

> "The day-of-year wrap. The deck is six forcing years repeated five times with continuous state, so this fires at each 365->1 boundary. Legacy handles that boundary with `reads.f:760-767` setting IDAYR=365 so `soil.f:39,78,106` do not re-initialize; ng has no such gate, so whether this ever fires is exactly what needs measuring."

This is a same-repository, in-code admission that (a) the production deck this project validates against exercises exactly the multi-scene-repeat pattern this gate exists for, (b) legacy's behavior at that boundary is to *suppress* re-initialization via the `IDAYR`/`IOLD` mechanism, and (c) ng has not confirmed it reproduces that suppression -- only that it *measures* whether the boundary is crossed (`census.record(.day_of_year_reset, hour)`, `:319`), not that it takes the corresponding action.

## Why this matters

If ng's production driver re-initializes (or fails to re-initialize) state at scene/year boundaries differently from legacy's `IDAYR.NE.IOLD`-gated behavior, this would be a **state-continuity divergence at exactly the boundaries a multi-year-repeat production deck crosses** -- silently re-zeroing accumulators that legacy carries forward, or vice versa, carrying forward state that legacy intentionally resets. This is not a numerical-precision or translation-defect question in the usual sense (an equation mismatch); it is a control-flow question about *whether the same reset/carry-forward decision is made at all*, which the contract's investigation order places above physics-level attribution ("Investigate differences in this order: unequal inputs/initialization; parsing or output semantics; missing/incorrect bindings and update order... **then** approved physical changes"). A silent divergence here could manifest as an unexplained mass-balance or state discontinuity at scene boundaries in exactly the kind of multi-scene comparison run this project's output-comparison work depends on (`feature-019`), and could masquerade as a physics or precision bug if not checked first at this control-flow level.

## What is not yet known

1. Whether ng's driver has *any* mechanism, elsewhere in the codebase, that performs the equivalent of `STARTS`/`STARTQ`/`STARTE` cold-start suppression or `ROUTS`/`ROUTP` reload at scene boundaries -- this pass only confirmed the *census/measurement* instrument at `:312-316` and did not exhaustively search for a separate action-taking gate. The comment's own wording ("ng has no such gate") is the strongest evidence found this pass, but it was not independently re-derived by tracing every scene-boundary code path in `ecosys_ng.zig`.
2. Whether ng's checkpoint-resume validation path (`ecosys.checkpoint_resume.validateCompletedDayBoundary`/`validatePlantMetadata`, `ecosys_ng.zig:519,553`, and the `resume_from_checkpoint` option, `options.zig:49,98`) already covers the *reload* half of legacy's behavior (the `ROUTS`/`ROUTP` consumer at `soil.f:285-289`) even if the *cold-start-suppression* half (`STARTS`/`STARTQ`/`STARTE` at `soil.f:39,78,106`) is not covered -- these are two related but distinct legacy consumers of the same `IDAYR.NE.IOLD` test and need to be checked separately.
3. Whether the six-forcing-years-repeated-five-times production deck (referenced directly in the Zig comment) has actually been run far enough to cross a 365->1 boundary and had its `day_of_year_reset` census checked, and if so what was observed.
4. The setter for `IDAYR`'s negative-sentinel form (`exec.f:94`, `IF(IDAYR.LT.0)`) was not located in this pass (not present in the two `reads.f` `IDAYR=` assignments read, nor in `routs.f`'s `IDAYR=IDATE`) -- there may be a third legacy code path into this same state machine not yet accounted for, which would need to be checked before concluding the Fortran-side mechanism itself is fully understood.

## Disposition: `unresolved`

The legacy mechanism is confirmed real and load-bearing for the project's actual validation deck. The Zig side's own commentary confirms the gate is not (yet) known to be reproduced, and explicitly calls this out as something that "needs measuring" -- i.e. this is a self-identified, not-yet-closed gap, not a reviewed-and-approved scope change. Per contract this cannot be marked `preserved`, `replaced-by-approved-feature`, or `retired-with-explicit-scope-approval` without that measurement and review.

## Next bounded action

1. Trace every scene-boundary code path in `ecosys_ng.zig` (not just the census instrument at `:312-316`) to determine definitively whether any code takes a `STARTS`/`STARTQ`/`STARTE`-equivalent or `ROUTS`/`ROUTP`-equivalent action keyed off a scene/year-boundary discontinuity, separate from the day-of-year census recording.
2. If the actual Ottawa (or other) multi-scene production deck referenced in the comment has run evidence available, check whether `day_of_year_reset` was ever recorded and what state-continuity behavior was observed at that boundary.
3. If no equivalent action-taking gate exists, this needs a design decision (does ng's continuous-state architecture make the legacy suppression unnecessary by construction, e.g. because ng never re-reads scene input files the way legacy's per-scene `reads.f`/`READI`/`READQ` do -- plausible but not demonstrated this pass) or a bounded implementation task, with independent review either way.
4. Independent review before closing.
