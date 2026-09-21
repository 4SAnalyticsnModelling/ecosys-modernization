# Handoff summary -- ecosys-ng v1.0.0 audit, 2026-09-20

Single entry point for this session's production-run work. Read this first;
it points to the detailed evidence trail rather than repeating it. This
document is itself read-only synthesis -- it changes no disposition, source
file, or prior issue file.

---

## 1. Executive summary

**This session's biggest result: the Ottawa deck's blocking frontier moved
from hour 2,894/2,895 -- where it had been stuck for the vast majority of
this session, across issue-065's 18 rounds and issue-068's 10+ rounds -- all
the way to hour 3,252, a genuine, validated ~358-hour advance beyond that
long-stuck point.** The breakthrough was `issue-024`'s final round: Fortran's
`wthr.f:589-601` applies a **universal, unconditional `NFH=4` per-hour
substep baseline to every non-fire hour, for every layer** -- not merely the
conditional `ICHKV` escalation layered on top of it that round 8 had already
restored. Zig's translation was missing that universal baseline entirely,
defaulting every hour's first attempt to `substep_count=1`. The fix was (1)
empirically confirmed via a bounded, fully-reverted diagnostic experiment
before being committed; (2) checked for early-hour trajectory consistency
against the already-validated Fortran-comparison evidence (the deep layer
changed by a negligible ~6.5e-8 relative by hour 1,000; the actively-targeted
surface layer changed by a legitimate-looking ~3-4%); (3) verified with a
full ~34-filter regression sweep plus the full unfiltered test suite (4362
passed, 1 skipped, 7 failed -- the pre-existing, unrelated `issue-076` CRLF
baseline, zero new failures); and (4) validated with a fresh-from-hour-1
`ReleaseFast` run against the real committed binary, reproducing the
diagnostic experiment's results bit-for-bit. It also **unexpectedly improved
wall-clock performance** to the new, later frontier rather than worsening it
as this session had originally flagged as a real risk -- see Section 5.
Full evidence in `issue-024`'s "Committed fix (2026-09-21)" section.

This resolves, for real, the human-reviewer decision this document's
original Section 3 (preserved below for provenance) asked for regarding
`issue-024`/`issue-068`: the run now clears hour 2,894 and hour 2,895
cleanly. It does **not** resolve `issue-024`'s own separate, still-open
core hour-1/layer-1 chronically-elevated-water root cause (rounds 1-7),
which is unrelated to the hour-2,894 collapse this fix addresses.

The run now fails at a **new frontier, hour 3,253**, on a **genuinely
different failure class**: `RuntimeSoilPoreCapacityExceeded` (cell 0, layer
1) -- not a solver/temperature-domain issue at all. `issue-078`'s diagnosis
(all 3 of the contract's 3 experiments spent) root-caused this precisely to
an architectural mismatch in how tillage soil-mixing is applied: Fortran's
`REDIST` re-applies a small, `CORP`-fractional mix at **every substep of
every hour of the whole tillage calendar day**, interleaved with WATSUB's
own mechanical-displacement relief mechanism after each dose (self-correcting
by construction, even though the mixing formula itself is just as
capacity-unaware as Zig's); Zig's `applyDeferredTillageSoil` applies **one
single full-strength deferred dose**, once per tillage event, with no
equivalent repeated relief opportunity. Two candidate fixes were identified
-- (a) make the single dose itself capacity-aware/self-limiting, or (b)
restructure the dispatch to interleave repeated fractional applications
across the substep loop, mirroring Fortran's actual architecture -- but both
are genuine architecture decisions, not "restore an existing mechanism" safe
fixes, and were correctly **not** implemented autonomously. This new
frontier and its two open options are described in Section 3 below,
alongside the now-resolved `issue-024`/`issue-068` pairing.

Separately, this session's own `issue-069` commit had silently broken the
full untargeted `zig test src/module_index.zig` suite (a stale test
literal, fixed as `issue-075`); with that fix in, the full suite ran to
completion for the first time this session -- **4354 passed, 1 skipped, 7
failed** -- and all 7 failures were triaged (`issue-076`) to one shared,
benign checkout/CRLF root cause, unrelated to any science or production
logic. The full test suite's status is now completely accounted for, with
no unexplained failures anywhere. See Section 7.

---

## 2. What's fully resolved

This session also closed out the "exact-zero water-carrier" defect class
first identified in `issue-060`. Two independent search methodologies --
keyword/function-name-based (the original `issue-060`-`067` sweeps) and
consumer-of-the-live-water-field-based (the newer `issue-069`/`072`/`073`/
`074` sweeps, the latter three run concurrently by this session and two
independent peer sessions) -- now find **zero remaining instances**; the
defect class is believed **exhaustively closed**. See the two new bullets
at the end of this list.

- **`issue-015`** -- Ottawa's hour-2,578/2,579/2,589 `SoluteReactionSolverDidNotConverge` frontier. Root cause: a two-phase SOLUTE equilibrium split shared one flat iteration ceiling unevenly; fixed by giving the post-kinetic phase its own budget and raising the shared floor from 60 to 100 (matching this project's existing floor-of-100 policy for sibling solvers). Committed and validated by a fresh from-hour-1 run clearing all three named hours on the first attempt.
- **`issue-058`** -- `recovery_substep_counts` had two independently hardcoded consumers that only agreed by coincidence, a latent crash risk. Fixed: `boundedRecoveryFallback` made genuinely array-driven with comptime membership guards on both consumers.
- **`issue-059`** -- `TransportReplay.time_step_hours`'s fixed `[64]f64` buffer would overflow if the substep ladder were ever extended past 64. Fixed: buffer sizing now derives from the ladder's real maximum, plus a runtime capacity check that survives `ReleaseFast`.
- **`issue-060`/`issue-061`** -- the "exact-zero water-carrier" defect-class family: legacy's `VOLW.GT.ZEROS2` floor was mistranslated as an exact-zero-only guard in several mass-inventory/carrier-rebase modules, discarding real mass. Fixed at the original site (`landscape_mass_inventory_phosphorus_ions.zig`) plus three siblings found by a dedicated sweep.
- **`issue-062`** -- a second, previously-unaudited consumer of the same legacy negligible-heat-capacity-layer discard triggered `RelayeringActivityConservationFailure`. Fixed with a shared cross-consumer `FloorDiscard` reconciliation ledger rather than a third independent patch.
- **`issue-063`/`issue-064`** -- a carrier-basis mismatch (mutator used raw live water, census used the floored substitute) caused carbon and then a broader ten-element (C/N/P/Al/Fe/Ca/Mg/Na/K/Si) conservation failure at hour 2,894. Fixed for carbon directly; the requested exhaustive sweep found and fixed 3 more siblings, bringing the total confirmed `ZEROS2`-class fixes across `issue-060`/`061`/`064` to 8.
- **`issue-065`** -- after the 8 fixes above, hour 2,894 still failed identically; 15+ further diagnostic rounds located and fixed three more distinct siblings of the same carrier-substitution defect class (`erosion_chemistry_bridge.zig`, `aqueous_transport_bridge.zig`, `mineral_nitrogen_transport.zig`/`nitrogen_state_update.zig`), fully clearing hour 2,894.
- **`issue-066`** -- `litter_ammonia_phase_bridge.zig`'s pack/unpack round trip used an exact-zero litter-water guard instead of the shared `ZEROS2`/`dry_reference_water_m3` substitution, in a bridge whose own local conservation gate excludes ammonia. Fixed (`legacy-defect-corrected`), regression-tested.
- **`issue-067`** -- once hour 2,894 cleared, hour 2,895 failed on a new water-volume closure check. Root-caused to a tolerance-provenance gap (the check didn't account for the vapor solver's own already-accepted Newton convergence slack); fixed by threading that solver's real tolerance into the check's existing `upstream_arithmetic_roundoff_allowance` field. Confirmed by direct instrumentation and a fresh full validation run: the error class no longer occurs anywhere through hour 2,895.
- **`issue-068`'s first three rounds** -- three independent, zero-regression solver-safety guards (rounds 2, 3/5, and 6) closing every then-known unguarded path by which a physically absurd temperature could be silently committed into `grid.soil_temperature_k`. All three verified sound by dedicated regression tests and a full fresh-from-hour-1 run showing zero domain-violation events anywhere in a 2,895-hour run.
- **`issue-069`** -- an independent review of `issue-060` through `issue-067`
  checking for gaps between their sweeps found two more genuine siblings of
  the same defect class, missed by every prior sweep because each searched
  by function-name/keyword/naming-convention heuristics that these two call
  sites didn't match. Both fixed. Finding A is confirmed both by its own
  regression tests and by a fresh-from-hour-1 live production run over the
  full currently-reachable range (hour 1-2,894/2,895); Finding B is
  confirmed by regression test only, consistent with its own confirmed
  non-reachability on the current Ottawa deck.
- **`issue-072`/`issue-073`/`issue-074`** -- a further, more exhaustive
  sweep abandoned keyword-based searching entirely and instead searched by
  every consumer of the raw live-water field directly, run concurrently by
  this session and two independent peer sessions. This found 9 more genuine
  instances of the same defect class (issue-072: 2 findings; issue-073: 4
  findings; issue-074: 2 findings), all fixed. All are now live-validated:
  `issue-074` by its own fresh-from-hour-1 production run reaching the
  established hour-2,894/2,895 frontier with no new failure class; `issue-072`
  and `issue-073` together via a shared clean, uncontended re-run that
  reached the same frontier in 19.39 minutes (inside the established
  ~19-25 minute baseline band) with byte-for-byte identical log/failure
  behavior to the `run-008` baseline (an earlier attempt at this same
  validation was inconclusive only because of contention from other
  concurrent agents on the machine, not a fix defect). With this batch, the
  "exact-zero water-carrier" defect class is closed with zero known
  remaining instances after two independent search methodologies across
  three concurrent sessions.

---

## 3. The universal `NFH=4` baseline hypothesis: CONFIRMED, IMPLEMENTED, AND VALIDATED (2026-09-21)

**Update, 2026-09-21: this section's central open question (below, preserved for provenance) is now resolved for the specific hour-2,894/2,895 frontier.** The universal `NFH=4` baseline hypothesis this section originally documented as a not-yet-tested candidate requiring human sign-off was: (1) tested in a bounded, fully-reverted diagnostic experiment; (2) found decisively positive (prevents hour 2,894's collapse, clears hour 2,895, reaches hour 3,252 -- 358 hours further than any prior attempt -- and is measurably *faster*, not slower, contrary to this section's own flagged performance risk); and (3) implemented for real and committed, with full regression coverage and a fresh-from-hour-1 validation against the real committed binary that reproduces the diagnostic experiment's result bit-for-bit. Full evidence in `audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md`'s "Diagnostic experiment (2026-09-21, non-committed)" and "Committed fix (2026-09-21)" sections; summarized here:

- **Mechanism**: `hourly_heat_water_solute.zig`'s `boundedInitialRecoverySubstepCount` now applies an unconditional `requested = @max(requested, universal_nfh_baseline_substeps);` floor (`universal_nfh_baseline_substeps: u8 = 4`, a named constant citing `wthr.f:589-601` directly), before the pre-existing freeze-flow/`ICHKV` floors -- exactly the mechanism this section originally described as not-yet-implemented.
- **Performance concern (this section's implication 1, below) -- addressed, not confirmed-as-feared**: a single bounded, non-rigorous measurement found the fix reached hour 3,252 in ~4 min 46 s (diagnostic experiment) / ~4 min 44 s (committed-binary validation), versus ~17-25 minutes to reach only hour 2,894/2,895 previously -- 4-5x *faster* to a strictly later point, not the proportional-4x-slower worst case this section flagged. The most likely explanation: flooring every hour's first attempt at 4 substeps eliminates most of the costly reactive escalation-ladder retries (3 escalation events across the full 3,252-hour committed-binary run, versus 178 in the previous ~2,894-hour baseline window per `run-008`). This remains a single-window measurement, not the rigorous multi-repeat, controlled-power-state benchmark this section originally called for -- that rigorous measurement is still a recommended follow-up, now de-risked by this strongly favorable directional signal.
- **Numerical-behavior concern (this section's implication 2, below) -- addressed with concrete early-hour evidence, not full-scope proof**: an early-hour trajectory-consistency check (comparing already-captured OLD-code and NEW-code fresh-from-hour-1 runs at hours 100 and 1,000) found the already-validated deep layer 12 changes by only ~6.5e-8 relative at hour 1,000 (essentially bit-identical) and ~3.9e-3 at hour 100, while the actively-targeted surface layer 1 changes by a modest ~3-4% at the same hours -- consistent with a legitimate, modestly-different-but-valid discretization concentrated where the fix actually matters, not a wholesale trajectory change. This is early-hour, spot-check evidence, not a full re-validation of every one of the 262,920 hours' worth of existing output-comparison artifacts; that full re-validation, if this fix's scope is extended to the full 30-year production deck, remains a real, not-yet-fully-discharged obligation.
- **Validation**: full ~34-filter regression sweep and the full unfiltered `zig test src/module_index.zig` suite (4362 passed, 1 skipped, 7 failed -- exactly the documented issue-076 CRLF baseline, zero new failures) both pass. `zig build -Doptimize=ReleaseFast` exit 0. Fresh-from-hour-1 validation with the real committed binary reproduces the diagnostic experiment's hour-2,894/2,895/3,252 results bit-for-bit.
- **New frontier**: the run now fails at hour 3,253 with a new, distinct signature (`RuntimeSoilPoreCapacityExceeded`, `cell=0 layer=1`) -- filed as `audit/issues/issue-078-hour-3253-runtime-soil-pore-capacity-exceeded.md`, deliberately not diagnosed in the same pass that implemented this fix.
- **What this does NOT resolve**: issue-024's own core round-1..7 hour-1/layer-1 chronically-elevated-water root cause remains open; this fix addresses the downstream hour-2,894 collapse, not that upstream cause. The new hour-3,253 frontier is a fresh, undiagnosed blocker on any further progress toward full production completion.

### The current open decision: `issue-078`, hour 3,253, `RuntimeSoilPoreCapacityExceeded` (cell 0, layer 1)

With the `issue-024`/`issue-068` pairing below now **RESOLVED/IMPLEMENTED**
(the fix described above), `issue-078` is the new, and only, open
architecture decision blocking further progress past hour 3,253. Its
diagnosis budget is fully spent (3 of 3 experiments) and it correctly was
**not** implemented autonomously, because both candidate fixes are genuine
design decisions rather than "restore an existing mechanism" safe fixes:

- `audit/issues/issue-078-hour-3253-runtime-soil-pore-capacity-exceeded.md`

**Root cause (confirmed by source-reading Fortran's `REDIST`, `redist.f:11277-11278`/`11900-12200`, plus two fresh-from-hour-1 instrumented reruns):** legacy has no separately named tillage subroutine -- the soil-mixing action lives inside `SUBROUTINE REDIST`, gated on that day's fixed `XCORP`/`CORP` mixing fraction (set once per calendar day in `day.f`, not reset mid-day). Because `REDIST` is called from inside the per-hour, per-substep loop (`soil.f:135-223`, `CALL WATSUB` then `CALL EROSION` then `CALL REDIST`, every substep of every hour), **the tillage-mixing block re-executes at every single substep of every hour of the whole tillage calendar day** (up to `24*NFH` = 96 times at the committed `NFH=4` baseline) -- each time moving only a small, `CORP`-weighted fraction of the imbalance, and each time immediately followed by another `CALL WATSUB` that gets a fresh chance to relieve any transient per-layer overfill that small step created. Legacy's mixing formula itself is algebraically just as capacity-unaware as Zig's (confirmed by reading the full water-mixing block; no term references pore capacity), so the safety net is architectural (repetition + interleaved relief), not a capacity check.

Zig's `applyDeferredTillageSoil` (`disturbance_management_dispatch`, invoked from `postScienceManagementAndGasAccounting`, confirmed by `stage_execution_census` to fire exactly twice in 3,252 hours) instead writes one single, full-strength deferred dose per tillage event, strictly after that hour's own WATSUB solve has already closed -- so there is no equivalent repeated-relief opportunity. Two fresh-from-hour-1 instrumented reruns traced the actual water movement precisely to this event at hour 3,252 (layer 0 loses ~1.81e-3 m3, layer 1 gains ~1.09e-3 m3 -- pushing it `8.6495e-4 m3` over its own capacity, matching the eventual hour-3,253 error's fields bit-for-bit; layer 2 also goes over capacity by ~2.96e-3 m3), refuting the original chronic-layer-0-overfill/relayering hypothesis directly.

**Two candidate fixes identified, neither implemented (both genuine architecture decisions):**
1. Make the single deferred dose itself capacity-aware and self-limiting (a new algorithm at the write site).
2. Restructure `applyDeferredTillageSoil`'s dispatch to interleave repeated, smaller-fraction applications across the substep loop for the tillage event window, each followed by a WATSUB-equivalent relief call -- mirroring Fortran's actual architecture (a substantial dispatch-design change, not a one-line reorder).

Moving the existing call earlier in the hour was checked and does **not** resolve this cleanly: both engines already run their mixing step after that timestep's own WATSUB-equivalent solve (matching intra-substep position), so the real mismatch is architecture/frequency, not call order. This decision is handed off for human/design review, same as the (now-resolved) pairing below was.

**Update, 2026-09-21 -- CONSOLIDATED, no longer just "diagnosis in progress":** three further bounded, separately-authorized diagnostic passes (six total on this issue) have since tested and closed out both of the two candidate fixes named above, plus a third (reuse of an existing redistribution mechanism): multi-dose splitting is blocked by a real ledger-accumulation bug in the tillage activity sidecar (not yet the hour-3,253 question itself); capacity-aware mixing-zone-only redistribution is proven mass-conserving but physically insufficient against the real deck (~60% shortfall across layers 0-3 at hour 3,252); and reusing an existing mechanism was correctly declined because the only candidate (`applyMechanicalFreezingDisplacement`) is Newton/Anderson solver-internal, not a standalone utility. All three low-risk options are now closed. What remains are two genuine new-design/implementation paths -- a new capacity-aware relief mechanism reaching beyond the mixing zone into deeper layers, or a ledger redesign so the activity sidecar accumulates (not overwrites) across sub-doses -- neither of which is a bounded diagnostic. See `issue-078`'s "Consolidated disposition (2026-09-21)" section (end of file) for full detail. This decision still requires a human choice between those two directions, or a dedicated implementation effort.

The original section text below (2026-09-20) is preserved verbatim for provenance -- it correctly framed the decision that has now been made and acted on.

## 3. The one specific decision needed from a human reviewer

**STATUS: RESOLVED/IMPLEMENTED, 2026-09-21 -- see the new Section 3 text above.** The universal `NFH=4` baseline fix was implemented, committed, and validated; the run now clears both hour 2,894 and hour 2,895 cleanly. The text immediately below is preserved verbatim for provenance only and describes the decision as it stood before that fix; it should not be treated as still-open. The current open decision is `issue-078` (above).

**`issue-024` and `issue-068` should be reviewed together, as one decision** --
per `issue-068`'s own tenth-round consolidation, which explicitly states this
should not be split into two independent calls.

- `audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md`
- `audit/issues/issue-068-hour-2895-soil-heat-solver-temperature-outside-physical-domain.md`

**Sharpened 2026-09-21, by `issue-077`'s round-2 validation (a separate,
already-fixed-and-committed defect at the same cell/layer -- see that issue
for the full evidence; summarized here only to sharpen this decision's
framing, not to reopen or substitute for it).** `issue-077` restored a
genuinely missing, correctly-derived Fortran cap (`EVAPGW`'s per-substep
fractional-of-available-liquid-water limiter, the `XNPHX` term) in
`ground_vapor_exchange.zig`, confirmed source-correct and zero-regression --
but a fresh-from-hour-1 validation run showed it is **structurally inert**
for hour 2,894/cell 0/layer 0 specifically, and diagnosed exactly why:
Fortran's substep subdivision is **proactive** -- every hour is
unconditionally subdivided into at least `NFH=4` substeps and further to
`NPH>=20` under `ICHKV` for a thin/low-heat-capacity top layer (this exact
layer), *before* the physics is attempted at all, regardless of whether a
full-hour step would have numerically "succeeded." Zig's substep escalation
(`recovery_substep_counts` in `heat_step.zig`) is **reactive** -- it always
tries `substep_count=1` (the whole hour, `time_step_hours=1.0`) first, and
only escalates if that attempt is flagged as a failure by its own
convergence/admissibility checks. At hour 2,894, the full-hour WATSUB-stage
attempt is accepted cleanly (no failure signal fires), so no escalation is
ever triggered -- even though a physically-absurd near-total evaporation of
the layer's water occurs within that single accepted step, exactly the kind
of event Fortran's unconditional per-hour subdivision exists to prevent from
ever being attempted in one piece. Any fractional-cap formula, however
correctly derived, is bit-for-bit inert whenever `substep_count=1`, because
the cap's own precondition (a substep shorter than the full hour) is never
met.

**This sharpens, but does not replace, the question below.** The
previously-tested hypothesis -- "the substep ceiling is too low, extend
`recovery_substep_counts` past 64" -- targets the *reactive* ladder's
maximum rung and has not itself been tried yet for issue-068's hour 2,895
(the eleventh round that would have tried it was explicitly declined,
reserved for this human decision). `issue-077`'s finding reframes what a
fix would actually need to be: not (only) a taller reactive ladder, but a
**proactive, `ICHKV`-equivalent pre-check** -- evaluated *before* the
substep_count=1 full-hour attempt is ever tried, for thin/low-heat-capacity
layers matching Fortran's `ICHKV` condition -- that forces subdivision
up front rather than waiting for a failure signal this specific scenario
(a numerically "clean" but physically absurd full-hour accept) never
produces. This points at a different location in the code for the change:
a pre-attempt gate ahead of `heat_step.zig`'s retry-ladder entry point,
not a tweak to the ladder's own post-failure escalation values.

**The exact question, sharpened:** at cell 0/layer 0 -- a chronically
near-desiccated, near-zero-heat-capacity top soil layer -- does Zig need a
**proactive** `ICHKV`-equivalent pre-check that forces substep subdivision
before attempting a full-hour step for thin/low-heat-capacity layers
(matching Fortran's actual always-subdivide architecture), **rather than or
in addition to** simply extending `recovery_substep_counts`'s reactive
ceiling past its current maximum of 64 (e.g. to 80, matching Fortran's
effective `NFH x NPH = 4 x 20 = 80` substeps/hour ceiling for this exact
scenario)? **If a taller reactive ceiling alone is tried**, this needs a
properly-controlled experiment that isolates substep count from the
iteration-budget confound `issue-015`'s own investigation already exposed
(a shared/starved iteration ceiling produced a misleading "more substeps
helps" signal there; any future substep experiment must control for that
before attributing an outcome to substep count alone) -- and, per
`issue-077`'s finding, should not be expected to help hour 2,894/2,895's
specific failure mode unless it is also made to trigger *proactively*
rather than only on a detected failure. **Or**, is a different, larger
algorithmic redesign of the phase solver's constrained-Newton feasibility
handling required instead -- because two safe, fully validated,
zero-regression backtracking/damping variants have already been tried
(`issue-068` round 9: uniform whole-step damping; round 10:
temperature-coordinate-only damping) and **neither resolved hour 2,895**,
both exhausting a conservative 6-attempt/0.5-halving budget without finding
a point simultaneously inside the physical temperature domain and within the
tight residual-admissibility tolerance. **These are not mutually
exclusive**: `issue-068`'s own ten rounds of solver-conditioning work (the
Newton/Anderson feasibility-vs-residual mismatch, a mass-side residual that
converges to machine-noise scale while the coupled endpoint-temperature
component overshoots the physical domain because the phase-enthalpy
relationship divides by a near-zero heat capacity) may still be a separate,
additional factor even if proactive subdivision were added -- `issue-077`'s
finding explains why a *specific already-tried translation fix* had no
effect at hour 2,894, and identifies where a not-yet-tried architectural
change would need to go; it does not by itself prove that change would
resolve hour 2,895, nor that it would make the Newton/Anderson conditioning
question moot.

`issue-068`'s own text: the mass-side residual for this layer converges
cleanly to machine-noise scale while the coupled endpoint-temperature
component overshoots 72-146 K past the [173.15, 373.15] K physical domain,
because the phase-enthalpy relationship divides an energy quantity by this
layer's near-zero heat capacity. An eleventh autonomous round (extending the
substep ladder to 80, exactly the question above) was requested and
**explicitly declined** by the tenth round's own stop order -- that specific
experiment is reserved for an authorized human decision, not another
autonomous pass. No source change is pending; the three safety guards and
two backtracking enhancements already committed do not need to be revisited
regardless of how this decision resolves. `issue-077`'s fix (the
`XNPHX`-equivalent fractional cap) is also already committed and does not
need to be revisited regardless of how this decision resolves -- it is a
correct, kept translation restoration that is simply inert as the *sole*
answer to hour 2,894, per its own round-2 validation.

**Added 2026-09-21: a second, NOT-YET-TESTED hypothesis, clearly distinct from
the just-tested-and-refuted conditional `ICHKV` pre-check above -- also
requiring human sign-off before any implementation attempt.** `issue-024`'s
own round 8 (see that issue's file) implemented and validated a *conditional*
proactive check: `ICHKV`-equivalent escalation to `NPH>=20` substeps, but only
for a layer already thin/low-heat-capacity *at the hour's start*. It correctly
does not resolve hour 2,895, because cell 0/layer 0's heat capacity is still
above the `ICHKV` threshold at the *start* of hour 2,894 -- the layer only
becomes degenerate *during* that hour's own within-hour collapse, which a
check evaluated at the hour boundary cannot foresee. That result is now
settled and does not need re-litigating.

The new hypothesis is a different, unconditional mechanism, already
established by this session's own earlier research (`issue-024` rounds 2-3,
`wthr.f:589-601`): Fortran's `NFH=4` is a **fixed, universal baseline**
substep count applied to *every* non-fire hour, for *every* layer,
unconditionally -- `ICHKV`'s escalation to `NPH>=20` is an *additional*,
conditional escalation layered *on top of* this universal `NFH=4` baseline,
not a replacement for it. Zig's `heat_step.zig`/`hourly_heat_water_solute.zig`
currently default every hour's *first* attempt to `substep_count=1`, not `4`
-- meaning Zig is missing the universal baseline entirely, not just the
conditional `ICHKV` escalation on top of it. This matters directly for hour
2,894: `issue-077`'s already-committed evaporation-cap fix computes its limit
as `owner_liquid_water_m3 * substep_fraction_of_hour` (`substep_fraction_of_hour
= 1/substep_count`); at `substep_count=1` this cap equals the *entire*
layer's water (no effective restriction). If Zig instead started every hour
at `substep_count=4` (matching Fortran's actual universal baseline, not
merely the conditional `ICHKV` tier), the same already-correct `issue-077`
cap would automatically limit each of those 4 substeps to at most 1/4 of the
layer's water -- a fundamentally different, more gradual within-hour
trajectory that might never reach the single-step near-total-desiccation
state observed at hour 2,894 at all.

**Why this is being documented, not implemented, this pass, and why it needs
human sign-off before any implementation attempt** -- unlike the
conditional `ICHKV` check (which by construction only affects rare,
already-identified degenerate hours), universally changing every hour's
starting substep count from 1 to 4 would affect **all 262,920 hours** of the
full 30-year simulation, not a narrow flagged subset. Two separate, serious
implications follow, and both require deliberate weighing rather than an
autonomous attempt:
1. **Performance.** Running every hour at a minimum of 4 substeps instead of
   1 could, roughly proportionally in the worst case, further increase the
   already-bad ~23.7x-slower-than-Fortran ratio (Section 5) for the vast
   majority of hours that currently converge fine at `substep_count=1`. The
   true impact is not knowable without measuring it, since most hours may
   still converge in fewer *effective* Newton iterations even when forced
   through 4 physical substeps -- but it could also be close to a flat 4x
   wall-time multiplier on top of an already-failing performance gate.
2. **Numerical behavior.** This would change the exact computed trajectory
   of *every* hour of the simulation, not just the currently-failing ones --
   a far broader output-fidelity change than a narrowly-scoped conditional
   fix, with implications for every already-completed comparison against the
   Fortran oracle (issue-024's own rounds 1-7, `feature-019`, and every
   output-comparison artifact keyed to the current `substep_count=1`
   baseline would need to be treated as potentially stale).

A full-run performance/behavior impact assessment is not knowable without
actually trying this across a broad hour range -- exactly the kind of
costly, consequential experiment (a blanket architectural change, not a
targeted diagnostic) that should be authorized deliberately by a human
reviewer, not run speculatively by an autonomous pass. No source change has
been made or attempted for this hypothesis. See `issue-024`'s round 8 section
for the short cross-reference pointer to this entry.

---

## 4. Remaining science-gap backlog

Unchanged by this session's production-run-focused work. See
`audit/handoff-issue-triage.md` Section 2 ("Tier 1 -- needs a human/scientist
decision") for the full list and evidence: `issue-018`, `022`, `026`, `030`,
`038`, `039`, `040`, `047`, `049`, `050`, `051`, `052`, plus the re-ranked
`issue-017` (Tier 3 item confirmed reachable on the validated deck). None of
these block the production run; they are science-parity/feature-attribution
judgment calls for whoever has the relevant domain expertise. This document
does not re-derive or re-rank them.

---

## 5. Performance status

**Note added 2026-09-21, not yet reflected in the numbers below: the universal `NFH=4` baseline fix (Section 3) unexpectedly improved wall-clock time to its new, later frontier rather than degrading it.** A single bounded, non-rigorous timing observation (not a repeated, controlled-power-state benchmark like `run-008` below) found the fix reaching hour 3,252 in ~4 min 46 s (diagnostic experiment) / ~4 min 44 s (committed-binary validation) -- 4-5x *faster* wall-clock than the ~17-25 minutes the pre-fix code needed to reach only the much-earlier hour 2,894/2,895 frontier. The likely mechanism: flooring every hour's first attempt at 4 substeps eliminates most of the costly reactive escalation-ladder retries (3 escalation events across the full 3,252-hour committed-binary run, versus 178 in the previous ~2,894-hour baseline window per `run-008` below). **This is one qualitative timing observation from the fix's own validation passes, not a rigorous re-benchmark**: no repeat runs, no logged/confirmed power-plan control, and no attempt to isolate this from other confounds. A full `run-008`-style remeasurement over the new, longer hour-1-through-3,252 window (matched Fortran-oracle window, multiple repeats, controlled power state) would be a good next step and has **not** been performed. The `run-008` numbers immediately below remain the most recent *rigorous* measurement, but they cover the old, now-superseded hour-2,894/2,895 window and should not be read as still describing the current frontier's performance.

**Superseded.** Most recent measurement: `audit/runs/run-008-longer-window-remeasurement-2026-09-20.md`,
a fresh same-day remeasurement over the **full currently-reachable window**
(hour 1 through the natural hour-2,894/2,895 boundary), superseding
`run-007`'s narrower hour-2,568-checkpoint numbers below. Key numbers:

- **The Zig/Fortran ratio over the full window is ~23.7x** (median 1,042.71 s
  Zig vs. 44.01 s Fortran; range across min/max repeat combinations
  22.0x-26.3x), measured with 3 repeats each side, on AC power with a
  confirmed/logged power plan. This is dramatically worse than `run-007`'s
  previously-reported ~2.0x (1.77x-5.68x) and **should not be quoted as
  superseded by, or interchangeable with, that older number** -- the two
  measure different windows, not the same workload at two points in time.
- **This is not a Zig performance regression.** Zig's own absolute wall time
  to the *same* hour-2894/2895 boundary is essentially unchanged from
  `run-007`'s own prior full-tail sample -- in fact ~6% *faster*
  (1,042.71 s here vs. 1,113.54 s in `run-007`), despite `run-008` running on
  top of the full `issue-058`-`issue-068` correctness-fix batch and reaching
  one more accepted hour (`last_hour=2894` vs. `run-007`'s `2893`) before
  failing on a harder, later frontier. The correctness fixes did not add net
  wall-time cost on this workload.
- **Why the ratio got so much worse, then: measurement-window scope, not
  code behavior.** `run-007`'s ~2.0x number was computed at a truncated
  hour-2,568 checkpoint that excluded almost the entire expensive tail.
  `run-008` measures the full tail out to the new, later hour-2,894/2,895
  frontier -- which is exactly where the real cost is concentrated. Fortran's
  own per-hour cost stays flat and small (~0.015 s/h) across the longer
  window, so extending the matched window by ~1,000 hours costs Fortran only
  a few extra seconds, while it costs Zig several hundred additional seconds
  concentrated in a handful of hard hours -- that asymmetry, not a uniform
  per-hour slowdown, is what drives the ratio from ~2x to ~24x.
- **The extra cost is concentrated, not spread evenly.** Only 178 total
  retry-ladder escalation events (92 rejected + 86 accepted) occur across the
  entire 2,894-hour run -- well under 10% of all hours. Day-boundary sampling
  found hour 2,592 alone costs ~14-16 s (the single largest sampled value,
  corroborated across all 3 repeats and cross-session against `run-007`'s
  independent 15.3 s finding at the same hour), with secondary spikes at
  hours 2,856, 2,880, and 2,808. `run-008` confirmed none of the newly-added
  solver-safety-guard diagnostics (including one new unconditional log line
  that is a quarter of the default log's volume) fire during ordinary
  full-hour steps -- they are structurally confined to already-rare
  sub-hour retry substeps.
- The acceptance bar (ratio <= 1) is **not met**, and is missed by a larger
  margin than any prior measurement in this series now that the full window
  is measured.
- **Speculative connection to the open reviewer decision (Section 3):** the
  specific hard hours driving this cost concentration (2,592, 2,856, 2,880,
  2,808) sit in the same newly-reachable stretch produced by, and share the
  same SOLUTE/phase-solver Newton-Anderson stiffness mechanism as, the
  degenerate cell-0/layer-0 scenario that `issue-024`/`issue-068`'s pending
  substep-schedule question (Section 3) is about. It is plausible that
  whichever way that reviewer decision resolves could also shift this
  performance picture -- but `run-008` did not test this, this is not an
  established causal link, and it should be treated as a hypothesis for a
  future run, not a claim that fixing correctness here would fix
  performance.
- Superseded prior reading, retained for provenance only: Zig, single-
  threaded, hour-2,568 checkpoint (matched to Fortran's day-108 marker):
  median 232.91 s (3 repeats, ~4.0% spread); Fortran oracle, same checkpoint:
  median 41.01 s that run, versus 131.46 s in the earlier `run-003` baseline
  (a disclosed, still-unresolved ~3.2-3.6x cross-session Fortran
  discrepancy, leading candidate sustained CPU thermal/power state, not
  confirmed) -- yielding the two-way-reported 5.68x/1.77x figures now
  superseded by `run-008`'s full-window ~23.7x above.

---

## 6. Where to look for detail

- `audit/handoff-issue-triage.md` -- master backlog triage; Section 9 has the
  full `issue-058` -> `issue-066` chain narrative and table.
- `audit/handoff.md` -- general project handoff / G0-G1 history.
- `audit/issues/issue-015-hour-2578-frontier-needs-human-design-decision.md`
- `audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md`
- `audit/issues/issue-058-*.md` through `issue-068-*.md` -- full evidence
  trail for each fix/round summarized above.
- `audit/issues/issue-069-*.md`, `issue-072-*.md`, `issue-073-*.md`,
  `issue-074-*.md` -- the water-carrier defect class's closing batch (see
  Section 2).
- `audit/issues/issue-024-top-layer-water-content-divergence-oracle-vs-zig.md`'s
  "Committed fix (2026-09-21)" section, and
  `audit/issues/issue-078-hour-3253-runtime-soil-pore-capacity-exceeded.md` --
  the hour-2,894->3,252 breakthrough and the new hour-3,253 frontier it now
  blocks on (see Section 1 and Section 3).
- `audit/runs/run-001-*.md` through `run-008-*.md` -- performance and
  diagnostic run history.
- `ecosys-audit/PROJECT_CONTRACT.md`, `ecosys-audit/EVIDENCE_GUIDE.md` --
  governing evidence discipline for any follow-up work.

---

## 7. Loose end found along the way (resolved and fully triaged)

**RESOLVED 2026-09-21 -- see `audit/issues/issue-075-pond-inventory-transfer-stale-carrier-volumes-literal.md`.**
Fixed: one missing `.cell_area_m2 = 1` field added to a single anonymous
`CarrierVolumes` struct literal in `pond_inventory_transfer.zig`'s test
`"pond sidecars count canonical gas and chemistry mirrors exactly once"`
(lines 465-477). Test-only change, no production logic touched. Confirmed
by targeted `zig test src/module_index.zig --test-filter ...` on that test
plus a broader sweep (`"carrier"` filter, 184/184 passed) and a full
untargeted `zig test src/module_index.zig` run (compiles cleanly now; see
below for the run's pass/fail counts and their full triage in issue-076).

**Provenance correction:** the original note below (preserved for
reference) claimed this break "predates and is unrelated to any of this
session's water-carrier work," citing a `git stash`/retest at HEAD
`ce0564e`. This pass checked that claim with
`git merge-base --is-ancestor 89e17ba ce0564e` (exit `0`) and found it does
**not** hold at that scope: `89e17ba` (`issue-069`, explicitly part of this
same session's water-carrier chain per Section 2 above) is what added the
required `cell_area_m2` field and is an ancestor of `ce0564e` -- so the
break was introduced by `issue-069`'s own commit missing one cross-file
call site, not something that predates this session. It does correctly
predate the *later* `issue-072`/`073`/`074` sub-chain, which is the
narrower claim the original `git stash` check actually supports. See
issue-075 for full detail.

**Follow-up (issue-076): the full untargeted suite is now fully accounted
for.** Fixing this compile break let `zig test src/module_index.zig` run to
completion for the first time this session: **4354 passed, 1 skipped, 7
failed**. All 7 failures were triaged in
`audit/issues/issue-076-crlf-checkout-breaks-hardcoded-lf-multiline-source-scan-tests-seven-failures.md`
to a single shared, benign root cause: this checkout's CRLF line endings
(`git config core.autocrlf=true`) break hardcoded LF-only multi-line
string-literal needles in a handful of source-text-scanning tests (spanning
`plant_symbiotic_fixation.zig`, `outer_hour_transaction.zig`,
`production_integration_test.zig`, and `solver_tests.zig`, all scanning
`ecosys_ng.zig`/`solver_solve.zig` for verbatim `\n`-only text). It is a
checkout/environment property, not a science, model, or production-logic
defect -- zero model execution is involved in any of the 7. This also
resolves, in part, `issue-032`'s long-open question about
`driver.outer_hour_transaction`'s failure mode: the failing binding is
confirmed to be the same CRLF mechanism under this invocation, not a hang;
`issue-032`'s separate, original 62,993-CPU-second hang-reproduction
question (under `zig build test`, earlier in the session) remains open.
**Net effect: the full test suite is now understood completely for the
first time** -- 4354 genuine passes, 7 fully-explained benign failures, zero
unexplained or hidden regressions anywhere in the codebase's test coverage.
One recommendation remains unactioned: a repo-wide `.gitattributes`
LF-normalization policy is flagged as a coordinator-level decision (not
performed this pass); the 7 literals could instead be fixed individually,
but the safe fix approach differs by file (the two `readFileAlloc`-based
sites are narrow/low-risk, the two `@embedFile`-based sites have a wider
blast radius) -- both left for follow-up, see issue-076.

Original note (preserved for provenance, superseded above):
- **`pond_inventory_transfer.zig`** has a pre-existing, unrelated compile
  break (a stale test literal missing `CarrierVolumes.cell_area_m2`),
  noticed by the `issue-074` implementing agent while working a different
  fix in a neighboring file. Reproduced even at commits before this
  session's fix chain started (confirmed via `git stash`/retest at git HEAD
  `ce0564e`), so it predates and is unrelated to any of this session's
  water-carrier work. It only affects the full, untargeted
  `zig test src/module_index.zig` (no filter) and `zig build test`; targeted/
  filtered tests and `zig build`/`zig build -Doptimize=ReleaseFast` are
  unaffected. Flagged by that agent as out of `issue-074`'s scope and left
  unfixed; not yet triaged into its own issue number. Whoever picks this
  project back up next should file it and assign it before relying on the
  full untargeted test suite.
