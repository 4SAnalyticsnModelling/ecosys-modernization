# Handoff summary -- ecosys-ng v1.0.0 audit, 2026-09-20

Single entry point for this session's production-run work. Read this first;
it points to the detailed evidence trail rather than repeating it. This
document is itself read-only synthesis -- it changes no disposition, source
file, or prior issue file.

---

## 1. Executive summary

This session's production-run work moved the Ottawa deck's blocking frontier
from **hour 2,578** to **hour 2,894**, a real, validated ~317-hour advance,
by finding and fixing more than a dozen genuine defects (a stiff-solver
iteration-budget starvation bug, two substep-ladder consistency/overflow
crash risks, and a family of ~10 "exact-zero water-carrier" mass-conservation
substitution bugs across water/nitrogen/phosphorus/ammonia carrier bridges).
The run now advances to **hour 2,895** before failing, and a further
same-session fix (issue-067) cleared one more layer of that new frontier
(a water-closure-tolerance provenance bug). What remains blocking hour 2,895
is a **chronic, near-desiccated single soil layer (cell 0, layer 0)** whose
phase-enthalpy Newton/Anderson solve cannot find a state that is
simultaneously residual-admissible and inside the physical temperature
domain -- ten rounds of diagnosis and two independently safe, zero-regression
algorithmic enhancements (two different Newton-backtracking variants) did
not resolve it, and the issue's own tenth round explicitly and formally
escalated this to a human numerics reviewer rather than continuing further
autonomous iteration. This blocker is described precisely in Section 3
below; it is not more autonomous guessing that is needed next.

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

## 3. The one specific decision needed from a human reviewer

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
