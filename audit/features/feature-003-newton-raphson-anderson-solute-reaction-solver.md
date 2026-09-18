# Feature ID: FEAT-003-NEWTON-ANDERSON-REACTION-SOLVER

Status: PARTIALLY_ASSESSED (source-audit level; scoped to the reaction-network solver and its whole-hour retry ladder; the currently-open hour-2,604-class convergence difficulty is explicitly out of scope for this dossier)

## Scope and provenance

**Legacy source/equations/interface:** `f77src/solute.f`. The reaction-equilibrium solve is a **fixed-count successive-substitution loop, not a Newton scheme with a convergence test**: `DO 1000 M=1,MRXN` (`solute.f:822`), `PARAMETER (MRXN=60...)` (`solute.f:111`, comment `:97`: "number of cycles for solving reaction equilibria"). No convergence-tolerance check or early exit exists in this loop -- it runs exactly 60 cycles every hour and accepts whatever state results, with no non-convergence detection at all. (`starte.f:101` separately defines an unrelated `MRXN=1000` for a different context, not cross-checked here.) Implication: the oracle cannot "fail to converge" because it never checks -- this is the mechanism behind this project's own documented pattern (a stronger ecosys-ng check surfaces strain the coarser oracle cannot see).

**New source/equations/variant:** `ecosys-ng/src/soil/solute/reaction_solve.zig` (+ `reaction_solver_types.zig`, `reaction_solver_numerics.zig`) implements a genuine Newton-Raphson solver with Anderson acceleration:
- Iteration ceiling, **directly oracle-cited**: `reaction_solver_types.zig:44-45`, `max_iterations: u16 = 60`, comment: `` `MRXN=60` in SOLUTE.F; convergence exits before this ceiling. `` Zig adds a real convergence exit the oracle lacks -- an improvement, not an invented number.
- Newton step: Jacobian-based (`reaction_span_jacobian`, ~`:2769-2792,2971,3074,3138`) with **projection onto free/non-bound-pinned coordinates** (`reaction_span_projected_jacobian`, `:3178-3229`) -- correct active-set-style bound handling (bound-pinned coordinates excluded from the linear solve rather than differentiated through naively).
- Candidate arbitration: `retainMeaningfulNewtonCandidate` (`:128-193`) prefers the direction that decreases the true L-infinity residual norm over one that only decreases a smoothed RMS "merit" (RMS used strictly as a tiebreaker) -- principled globalization, not ad hoc.
- Anderson acceleration: `retainMeaningfulAndersonCandidate` (`:195-225`) gates acceptance through `numerics.andersonImprovesAcceptedMerit`; `andersonTierEnabled` (`:227-248`) uses a logarithmic contraction-rate extrapolation against the remaining iteration budget (`:238-247`; comment: "a hard iteration ceiling must not turn a mathematically descending but asymptotically inadequate Newton step into the only priced direction"). One bare constant, `1.0e-6` relative-improvement floor (`:235`), reads as a standard floating-point noise-floor epsilon -- not oracle-cited, but its role (treating near-zero improvement as "no improvement") is self-evidently a numerical-noise guard, not a physical bound.
- Bounded mineral-recovery sub-budget: `@min(@as(u16, 40), options.max_iterations - iteration - 1)` (`:1578, :1585`) -- the literal `40` has no oracle citation, but is always further bounded by the grounded 60-cycle ceiling via `@min`. Traceability nit, not a correctness defect.
- No-partial-publish / exactly-once discipline: explicit comment "No partially improved recovery state is published" (`:1570`); recovery only proceeds to `requireConservedInventories`/`reaction_charge.requireConservedStates` (`:1593-1594`) after passing a residual-quality gate (`:1591-1592`, rejects if `recovered_quality.maximum > 1`) -- exactly-once, checked-before-commit pattern, matching `PROJECT_CONTRACT.md`'s "trial states must be transactional" requirement.

**Whole-hour retry ladder** (a *different*, separate solver layer -- the hourly heat/water/solute transport recovery controller, not the reaction-network solver above): `ecosys-ng/src/stages/hourly_heat_water_solute.zig`, `ecosys-ng/src/soil/water/heat_step.zig`. Ladder `recovery_substep_counts = [_]u8{1,2,4,8,16,20,32,64}` (`heat_step.zig:483`). `boundedRecoveryFallback` (`hourly_heat_water_solute.zig:11302-11313`) strictly escalates through named tiers (20->32->64), returns `null` at the ceiling -- guaranteed termination, no infinite retry, matching the contract's explicit ban on "an unbounded 2/4/8/16/... retry cascade." `recoverFixedExternalHourAdaptively` (`:11434-11469`) delegates rollback correctness to the caller's `attempt.run(substep_count)` (`runBoundedRecoveryAttempt`, `:11399-11406`); tests pin the rollback contract ("fixed external hour recovery rolls back before its single bounded fallback", `:9722`) and the full ladder walk (`:9829-9859`, `:9861-9882`).

**Primary reference:** none external -- this is the project's own established Newton-Raphson/Anderson-accelerated solver architecture that `PROJECT_CONTRACT.md` explicitly requires be preserved ("Inspect the current Newton-Raphson primary solver and Anderson-accelerated fallback... Do not introduce vanilla Picard as an alternative fallback").

**User-approved scope / repository decision:** `PROJECT_CONTRACT.md`'s "Existing numerical architecture constraints" section names this exact solver architecture as a preserve-target and forbids ad hoc replacement.

**Unchanged contracts:** bounded retries, rollback-on-failure, and exactly-once state publication are all present and each independently evidenced above (not merely asserted).

## Scientific and numerical tests

**Expected effects and unaffected quantities:** not run this pass (source-read only), except for the full-suite regression evidence below.

**Parameter/domain/edge tests:** two historical defects in this exact machinery are closed with cited before/after evidence under the in-code tag `SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001` (`hourly_heat_water_solute.zig:9790-9797, 9829-9837`):
- hour 2,571: the previous implementation made at most one fallback, so a preferred schedule below 20 could reach 20 but never the documented 32-step rescue; fixed by looping through the full chain.
- hour 2,604: the 32-step "rescue" was itself a hardcoded ceiling one rung short of the ladder's own declared maximum (64); fixed by adding the third tier.

**Matched-state controls:** not run this pass.

**Independent analytical/reference/limiting cases:** the 60-iteration ceiling's oracle citation (`solute.f:111`) was read directly, not assumed.

**Conservation, residual/Jacobian and coupling evidence:** the exactly-once/no-partial-publish discipline described above is a coupling-safety property, verified by direct reading of the gating order (residual-quality gate before conservation-check before publish), not by running a live scenario.

**Interaction with other features:** shares the reaction-network solver's Newton/Anderson core with (by name/architecture, not independently confirmed this pass) the soil-water and soil-heat solvers referenced in `PROJECT_CONTRACT.md`'s numerical-architecture section; cross-solver consistency not verified this pass.

## Acceptance and review

**Predeclared tolerances/scientific envelope:** the 60-cycle ceiling is the only numeric bound independently cross-checked against the oracle this pass; no scientific envelope established beyond that.

**Observed discrepancies and causal explanation / disposition:**
- 60-iteration ceiling: **preserved** (directly cited against oracle `MRXN=60`), with a documented improvement (early convergence exit) layered on top -- **replaced-by-approved-feature** for the convergence-detection behavior specifically.
- Newton candidate selection, bound-coordinate projection, Anderson gating: **replaced-by-approved-feature** (corrected label -- there is no oracle counterpart to *preserve* against; the oracle has no convergence-aware iteration at all, so calling this `preserved` was a labeling error caught on independent review, not a factual one). Zig-native additions consistent with the contract's numerical-architecture policy.
- Whole-hour retry ladder: **replaced-by-approved-feature** (same correction -- no Fortran source is cited or exists for this ladder; the oracle's fixed 60-cycle loop has no retry/rollback concept at all). Terminates deterministically, escalates strictly, rollback/no-partial-publish invariants both stated in comments and covered by tests pinning the exact escalation sequence.
- Mineral-recovery sub-budget literal `40` (`reaction_solve.zig:1578, 1585`): **unresolved** (minor) -- no oracle citation for this specific value, though it cannot exceed the grounded outer ceiling. Recommend a one-line citation or named-constant rename; not blocking.

**Unresolved risks or close-range goal conflicts:** none identified at the general-machinery level. The project's own separately-tracked, still-open hour-2,604-class convergence difficulty (a genuinely stiff simultaneous aluminum/iron/calcium-hydroxide-site disequilibrium, per the reference project's `docs/GOAL.md`, not yet independently confirmed to reproduce in this specific `D:` checkout) is a solver-*performance* limit at one specific cell/state, not a defect in the machinery audited here -- keep as a separate, already-tracked item, do not conflate with this dossier's disposition.

**Performance impact:** not measured this pass.

**Author and independent reviewer:** authored by this session's audit forks (read-only trace), 2026-09-18. No independent reviewer yet -- needs a genuinely separate review pass before final disposition, per contract.

**Evidence paths/hashes:** citations above are file:line references into `D:\ecosys-modernization\f77src\solute.f` (+`starte.f` cross-check) and `D:\ecosys-modernization\ecosys-ng\src\soil\solute\reaction_solve.zig`, `src\soil\solute\reaction_solver_types.zig`, `src\stages\hourly_heat_water_solute.zig`, `src\soil\water\heat_step.zig`, at git commit `97a33a9`. Supporting regression evidence: full-suite `zig test src\module_index.zig` this session, **4286 passed; 1 skipped; 0 failed** (4287 total), exit code 0 -- includes this solver's own test coverage (`soil.solute.reaction_solve.*`, `soil.solute.reaction_try_acceptance.*`, `soil.solute.reaction_solver_numerics.*` observed passing in the live run log).

**Decision:** NOT_ASSESSED for gate purposes (source-audit level; one minor unresolved traceability nit, no correctness defect found). Faithful and justified at the machinery level.

**Independent review (2026-09-18, fresh agent, no shared context with the author): CONFIRMED, with one disposition-terminology correction (applied above).** `solute.f:97,111,822` (MRXN comment/definition/loop) confirmed exact; the reviewer independently grepped the entire file for convergence/tolerance/early-exit patterns and found zero matches, strengthening the "no convergence check anywhere" claim beyond what the original pass had shown. `starte.f:101`'s unrelated `MRXN=1000` confirmed as a different context, as caveated. All Zig citations (`reaction_solver_types.zig:44-45`, `reaction_span_projected_jacobian:3178-3229`, `retainMeaningfulNewtonCandidate:128-193`, `retainMeaningfulAndersonCandidate:195-225`, `andersonTierEnabled:227-248` including the `1.0e-6` floor at exactly line 235, sub-budget literal at `:1578,1585`, no-partial-publish comment at `:1570`, gate sequence at `:1591-1594`, `heat_step.zig:483`, and the `hourly_heat_water_solute.zig` line ranges) confirmed exact or within ±1 line. The one real finding: "Newton candidate selection/bound-projection/Anderson gating" and the "whole-hour retry ladder" were labeled `preserved` while the dossier's own prose already admitted no oracle counterpart exists for either -- corrected to `replaced-by-approved-feature` above. The 4286-pass test claim is correctly disclosed as unverifiable-by-the-reviewer (no execution permitted in the review pass) rather than independently reproduced.
