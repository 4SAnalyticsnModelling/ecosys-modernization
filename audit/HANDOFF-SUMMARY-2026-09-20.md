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

**The exact question:** at cell 0/layer 0 -- a chronically near-desiccated,
near-zero-heat-capacity top soil layer -- does Zig's heat-solver
substep-recovery schedule need an `ICHKV`-equivalent compounding tier,
extending `recovery_substep_counts` past its current maximum of 64 (e.g. to
80, matching Fortran's effective `NFH x NPH = 4 x 20 = 80` substeps/hour
ceiling for this exact thin/low-heat-capacity scenario)? **And if so**, this
needs a properly-controlled experiment that isolates substep count from the
iteration-budget confound `issue-015`'s own investigation already exposed
(a shared/starved iteration ceiling produced a misleading "more substeps
helps" signal there; any future substep experiment must control for that
before attributing an outcome to substep count alone). **Or**, is a
different, larger algorithmic redesign of the phase solver's
constrained-Newton feasibility handling required instead -- because two
safe, fully validated, zero-regression backtracking/damping variants have
already been tried (`issue-068` round 9: uniform whole-step damping; round
10: temperature-coordinate-only damping) and **neither resolved hour 2,895**,
both exhausting a conservative 6-attempt/0.5-halving budget without finding
a point simultaneously inside the physical temperature domain and within the
tight residual-admissibility tolerance.

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
regardless of how this decision resolves.

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

## 7. Loose end found along the way (not yet triaged)

**RESOLVED 2026-09-21 -- see `audit/issues/issue-075-pond-inventory-transfer-stale-carrier-volumes-literal.md`.**
Fixed: one missing `.cell_area_m2 = 1` field added to a single anonymous
`CarrierVolumes` struct literal in `pond_inventory_transfer.zig`'s test
`"pond sidecars count canonical gas and chemistry mirrors exactly once"`
(lines 465-477). Test-only change, no production logic touched. Confirmed
by targeted `zig test src/module_index.zig --test-filter ...` on that test
plus a broader sweep (`"carrier"` filter, 184/184 passed) and a full
untargeted `zig test src/module_index.zig` run (compiles cleanly now; see
issue-075 for the run's pass/fail counts, which are governed by
already-tracked runtime issues, not this compile break).

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
