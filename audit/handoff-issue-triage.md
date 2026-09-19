# Issue backlog triage -- ecosys-ng v1.0.0 audit (G1 source-audit sweep)

Read-only synthesis of the 54 issue files that exist under `audit/issues/` as of
2026-09-19 (`issue-001` through `issue-056`; `issue-003` was drafted then folded
into `issue-005` per `audit/handoff.md`, and `issue-009` was never filed --
neither number should be recreated). This document does not change any
disposition, does not edit any of the 54 source files, and does not touch
`audit/traceability/traceability.csv`. It is a coordinator-facing map of the
backlog, not a new finding.

---

## 1. Executive summary

**54 issue files.** Of these:

- **11 are closed / no longer open**: `issue-001`, `issue-002` (CORRECTION,
  post-dates this triage pass: an independent gfortran oracle was built and
  ran this checkout's own 30-year Ottawa deck to full completion later the
  same session -- see `issue-002`'s own "Resolution" section and
  `audit/runs/run-002-*.md`; this triage document's Tier/priority text below
  still refers to it as open in a few places and should be read with that
  correction in mind), `issue-005`, `issue-007`,
  `issue-008`, `issue-010`, `issue-011`, `issue-016`, `issue-019`, `issue-023`
  (fixed-and-verified or confirmed-already-correct-with-a-record-added), plus
  `issue-006` (a working note whose content was folded into other issue files
  and the feature dossiers -- not a standalone open item).
- **1 is an infrastructure/process blocker, not science content**:
  `issue-032` (a `zig build test` hang, reported against `outer_hour_transaction`;
  2026-09-19 diagnosis static-analysis-confirmed the named test's own body cannot
  hang and a bounded dynamic rerun did not reproduce the hang -- root cause still
  unconfirmed, see issue file's Diagnosis section; currently worked around by
  using `zig test --test-filter`).
- **42 are genuinely open** and require a disposition (`preserved`,
  `replaced-by-approved-feature`, `legacy-defect-corrected`,
  `retired-with-explicit-scope-approval`, or a fix) before G1 can be called
  complete. These are triaged into Tiers 1-4 and the standalone Tier 7 item
  below.

**Single most important fact for the stated success criteria** (no science
gaps; production run completes; outputs comparable to oracle; performant):
**`issue-015` is a functional BLOCKER for "the production run completes."**
The Ottawa deck fails at hour 2,578/262,920 (0.98%) with
`SoluteReactionSolverDidNotConverge`, a stiff Al/Fe/Ca-hydroxide-phosphate
reaction-network disequilibrium. Two independent, well-evidenced fix attempts
have already been tried and refuted; the issue's own conclusion is that this
needs a human numerical-methods design decision, not another autonomous
guess. Nothing else in this backlog blocks the run from completing -- every
other open item is either latent (never yet observed to change the run's
outcome), narrow-scope (fires only under conditions not yet confirmed present
in the validated deck), or a documentation/traceability gap on top of
already-correct code.

**Correction (post-dates this triage pass): `issue-002` is now RESOLVED, not
open.** A genuine, independently-built gfortran oracle exists and has run
this checkout's own 30-year Ottawa deck to full completion (exit code 0,
1,138 output files) -- see `issue-002`'s own "Resolution" section and
`audit/runs/run-002-independent-gfortran-oracle-build-2026-09-18.md`. This
data has already been used for real comparison work this session
(`feature-019`, `issue-024`). The remaining limitation is durability only:
the 1.33GB of actual output lives in the session scratchpad, not committed --
a future session needing the raw files (not just the build recipe) must
rebuild and rerun (~2h40m), or the user should decide whether to preserve a
copy durably. This is a housekeeping/storage question, not a blocker for
"outputs comparable to oracle."

**Correction (2026-09-19, post-dates this triage's initial pass): `issue-050`
is re-ranked from Tier 4 (paperwork) to Tier 1 (human decision needed).** A
bounded follow-up confirmed, from the deck's own input files and source
alone (no run needed), that Ottawa's grid is a true 1x1 cell (every face is
a boundary face) and that the site file sets a real, nonzero, exchange-
enabled `RCHGFU=RCHGFA=10.0` at the N/S lateral boundaries -- exactly the
condition needed to make the issue's `recharge_frequency_divisor`
hardcoding (`0`/`1` in production instead of the real site value) a live,
reachable ~10-11x divisor discrepancy on the validated deck, not a dormant
or paperwork-only gap. See `issue-050`'s own "Follow-up resolution
(2026-09-19)" section and the Tier 1 table entry added below.

Of the remaining 40 open items (excluding 015 and 002): the large majority are
**real but low-materiality** -- either a legacy quirk that Zig's cleaner,
generic architecture already avoids (just needs a sign-off and a citation), or
a narrow, conditionally-dormant gap. A smaller set (Tier 3, ranked below) are
**genuine functional gaps** worth prioritizing for "no science gaps."

**Correction (2026-09-19, post-dates this triage's initial pass):** the
executive summary originally singled out `issue-037` here as affecting the
validated Ottawa deck "today," on the strength of `issue-053`'s claim that
Ottawa is an `ISALTG=0` (static-salt) deck. That claim was independently
re-checked and found to be **wrong, unverified against either deck's input
file**: `f77src/readi.f:154` maps site record 3's second field to `ISALTG`,
and both `f77example/Cool Temperate Maize-Soybean ON/f25si98` line 3 and the
modern `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/.../f25si98`
line 3 read `ISALTG=1` (dynamic-salt), confirmed on the Zig side too via
`ecosys-ng/src/state/site.zig`'s `salinity_enabled`/`salinity_enabled_by_cell`
wiring. Because Ottawa's own legacy oracle also runs the dynamic-salt
formulas, Zig's current always-dynamic production behavior is the *correct*
match for this deck, not a divergence from it. `issue-037` is downgraded
accordingly -- see Section 4's corrected Tier 3 list and Section 8 item 3
below; it no longer belongs in the "affects the validated deck today" framing.

**Correction (2026-09-19, same day as the above):** the four Tier 3 items
this document previously called out as "harder-to-scope... need an
input-file check before anyone can even judge urgency" (`issue-028`,
`issue-031`, `issue-044`, `issue-056`) have now had exactly that check run,
using the same bounded, read-only, input-file/reachability method
demonstrated on `issue-050`. All four came back decisively **not reachable**
for the in-scope Ottawa deck (or, for `issue-056`'s rainfall side,
reachable-but-immaterial): `issue-028`'s manure-N amendment operates on a
soil file where manure C/N/P are exactly zero at every layer; `issue-031`'s
CH4 combustion sits behind a fire gate that never opens because no
`ITILL=22` burn event is scheduled anywhere in the deck's 1998-2002 tillage
files; `issue-044`'s irrigation-gas-flux mechanism never fires because every
year's land-management manifest specifies no irrigation file at all; and
`issue-056`'s rainfall/irrigation ion-pairing network's irrigation side is
moot for the same reason while its rainfall side's actual chemistry inputs
(Al/Fe/Ca/Mg/Na/K/SO4/Cl) are zero in every weather-file year checked. None
of these four needed a run to resolve -- all four verdicts came from the
deck's own input files alone. See each issue's own "Follow-up resolution
(2026-09-19)" section, the re-ranked Tier 3 list in Section 4, and the
updated Section 8 item 5/8 below. No other issue's disposition or ranking
changed as part of this pass.

**Correction (2026-09-19, later same day): `issue-040` is re-ranked from
Tier 3 (this section's former #1, "cheap to fix") to Tier 1 (human decision
needed).** A bounded scoping check (same read-only method as the corrections
above) found `issue-040` does **not** match the `issue-054` pattern this
document previously implied for it. First, the three legacy inputs the
missing root osmotic/turgor formula needs (`TKS`/temperature, `CCPOLR`/
nonstructural-solute concentration, `CSALTR`/salt concentration) are not
currently plumbed into `state_updateRootHydraulicsWithCanopyPotential`
(`ecosys-ng/src/plant/root/water_balance.zig:821-889`) or its sole caller
(`ecosys-ng/src/stages/hourly_snow_energy.zig:654`) -- the fix needs real
cross-module plumbing (the concepts exist elsewhere, e.g.
`plant_root_nutrient_uptake.zig`, `plant_root_salt_exchange.zig`, but are not
wired to this call site), not a one-field substitution. Second, unlike
`issue-050`/`028`/`031`/`044`/`056`, this term's reachability for Ottawa
cannot be settled from static site/weather/management input files -- it
depends on emergent simulated root-water-potential/temperature/solute
trajectories that only a run or a matched-state kernel test could produce,
neither performed this pass (and no full-season run exists yet; `issue-015`
still blocks completion at hour 2,578). See `issue-040`'s own "Scoping check
(2026-09-19)" section for the full evidence chain and the Tier 1 table entry
added below.

---

## 2. Tier 1 -- needs a human/scientist decision, not resolvable by more static analysis

For each: what the two sides do differently, and the decision needed.

| Issue | What differs | Decision needed |
|---|---|---|
| `issue-015` | Ottawa deck fails to converge at hour 2,578; same failure class the mature reference project needed a human decision on after 6+ refuted hypotheses. Two fixes already tried and refuted here too. | Numerical-methods input on the stiff reaction-network solver, or a scope decision on what "production run completes" requires for v1.0.0. **Already the user's own prior decision point** -- flagged here only for completeness. |
| `issue-018` | Legacy's flawed macropore/micropore diffusive-exchange cap (`XFRS=0.05`) was replaced with better physics for **salts** (documented, tested) but the **gas/dissolved-nutrient** pathway still runs the literal, admittedly-flawed legacy formula. | Should the salt-side physics fix extend to gases, or is there a domain-specific reason (e.g. Henry's-law equilibration dominating) it was scoped to salts only? |
| `issue-022` | A well-documented "exact GROSUB" grazing-removal helper (faithfully reproduces a legacy ear/grain leftover-demand-dropping quirk) is dead code; the live path uses a structurally different algorithm that never truncates carried-forward demand. | Adopt the live algorithm as the approved replacement (retire the dead helper), or restore literal-cascade fidelity. Not a mass-balance issue, but changes the relative organ split under partial grazing. |
| `issue-026` | Same shape as `issue-022` for fire/combustion: a second, fully-"exact"-cited combustion implementation is dead code; a structurally different live path (different files, different internal representation) appears to compute the same equations but has never been proven numerically equivalent. | Confirm equivalence with a matched-state test, then retire the dead helper -- or, if a divergence is found, treat as a design decision like `issue-022`. |
| `issue-030` | Legacy suppresses re-initialization / forces a checkpoint reload at multi-scene/year-boundary discontinuities via the `IDAYR`/`IOLD` gate; Zig's own source comment admits it has no confirmed equivalent action-taking gate, only a census that measures whether the boundary is crossed. | Determine whether Zig's continuous-state architecture makes the legacy suppression unnecessary by construction, or whether a real state-continuity gap exists at the six-year-repeat boundaries this project's own validation deck crosses. |
| `issue-038` | Zig's production silicate-weathering path shares one local hydrogen budget between natural- and ground-rock dissolution of the same mineral -- physics with **no legacy counterpart at all**. The faithful (no shared budget) translation exists only in a self-test, unused in production. | Is the added H+-budget-sharing an intentional, reviewed robustness improvement (needs its own feature entry) or should production call the faithful translation instead? |
| `issue-039` | Legacy always substitutes the root domain's (N=1) primary-axis count/depth for the mycorrhizal domain too (mycorrhizal axis count is frozen/dead state in legacy `grosub.f`). Zig grows each domain's axis count independently and uses each domain's own value. | Materiality gated on whether any in-scope PFT sets `mycorrhizal_type=2` (not checked). If yes: fix Zig to substitute domain 0's value everywhere, or approve independent mycorrhizal-axis growth as a reviewed feature. |
| `issue-047` | Legacy caps an annual root-to-stalk phosphorus transfer using the **nitrogen** pool (`ZPOOLR`) instead of the phosphorus pool (`PPOOLR`) -- a copy/paste slip that can drive `PPOOLR` negative. Zig faithfully reproduces the same (wrong) cap but fails loudly instead of silently going negative. | Preserve the exact legacy formula (`preserved`, accepting the bounded risk the runtime guard already catches) or correct the clamp to `PPOOLR` (`legacy-defect-corrected`, a real physics change needing sign-off). |
| `issue-049` | Legacy's domain-boundary (lateral grid-edge) snow drift is entirely commented-out/dead in the Fortran; Zig's snow-drift routing reuses the runoff/erosion boundary-openness mask and genuinely exports mass/heat/solutes across an open, downhill lateral boundary during snow-bearing, windy hours. | Check whether the in-scope deck's site file ever has a nonzero open+downhill lateral boundary during snow cover. If live: gate Zig's snow-drift boundary path permanently closed to match legacy exactly, or register this as an approved feature (legacy's dead skeleton suggests an unfinished original feature, not a deliberate physical choice). |
| `issue-051` | Legacy's own macropore freeze-thaw block is internally inconsistent: its eligibility **gate** correctly uses the pure-water freezing point (273.15 K) but its **driving-force formula** reuses the micropore's matric-depressed freezing point. Zig reproduces this inconsistency bit-for-bit, undocumented on either side. | Correct Zig's formula to relax toward the pure-water freezing point for the macropore path (a `legacy-defect-corrected` candidate), or find/document a physical rationale for the legacy behavior and keep it as `preserved`. Sits in the same freeze-thaw physics area as the already-high-scrutiny Dall'Amico feature. |
| `issue-052` | Legacy's ground/snow surface roughness `ZS` is "sticky": recomputed only on a rare disturbance/restart event, otherwise held fixed all season. Zig recomputes it from live state every hour, unconditionally. | Is Zig's continuous recompute a deliberate improvement (needs a feature entry + matched-state test) or does exact-parity require an `IFLGS`-equivalent gate in Zig's driver? Feeds the canopy/surface energy-balance chain already under scrutiny in `issue-024`. |
| `issue-040` (added 2026-09-19, re-ranked down from Tier 3) | Root osmotic/turgor water potential (`PSIRO`/`PSIRG`) from `uptake.f`'s temperature- and nonstructural-solute-dependent Van't Hoff term was never ported; Zig substitutes a static per-plant trait constant. A 2026-09-19 scoping check found the fix needs new cross-module plumbing (temperature, nonstructural-solute-concentration and salt-concentration arrays are not currently passed into `water_balance.zig`'s root-hydraulics call, though the underlying concepts exist elsewhere in the plant/root modules), and that reachability for Ottawa cannot be bounded from static input files the way `issue-050`/`028`/`031`/`044`/`056` were -- it depends on emergent simulated root-water-status trajectories. | Port the full `FDMR`/`TKS`/`CCPOLR`/`OSWT`/`CSALTR` formula (mirroring the already-correct canopy-side `water_osmotic_potential.zig`), including the new plumbing, and validate with a matched-state kernel test; or obtain explicit scope approval to keep the constant-turgor simplification with its own feature-register entry and scientific rationale. Either path needs coordinator/scientist sign-off, not another autonomous static-analysis pass. |
| `issue-050` (added 2026-09-19, re-ranked up from Tier 4) | The `recharge_frequency_divisor` half of this issue (distinct from its still-paperwork-only `GRID-INV-001/002` dimensional fix) hardcodes `0`/`1` at `solver_residual.zig:474,498,513,530` where legacy uses a real, site-calibrated `RCHGFU`/`RCHGFA`. Confirmed for Ottawa: the deck's own site file gives `RCHGNUG=RCHGSUG=10.0` with N/S exchange enabled, and the deck's 1x1 grid makes every cell's N/S faces boundary faces by construction -- both preconditions the issue needed to matter are now independently confirmed true, not merely possible. | Thread the real per-direction `RCHGFU`/`RCHGFA` value through `recharge_frequency_divisor` at the four lateral call sites (a `legacy-defect-corrected`-shaped fix once reviewed), or produce a documented, reviewed rationale for keeping the hardcode despite disagreeing with the site file (`preserved`/`retired-with-explicit-scope-approval`-shaped). Either way this needs a decision before a feature-register entry can be written; a run to establish the actual m3-scale flux impact is a reasonable next step but the divisor-level ~10-11x discrepancy is already established without one. |

---

## 3. Tier 2 -- confirmed legacy defects already avoided/fixed in Zig, just need sign-off

In every item below, Zig's current behavior is plausibly or demonstrably the
scientifically correct one; the only remaining action is a reviewer
confirming the disposition (usually `legacy-defect-corrected` or
`preserved`-deliberate) and, where noted, adding a citation/comment so a
future refactor doesn't accidentally reintroduce the legacy defect. None of
these block anything today.

**Group A -- "N parallel blocks, one outlier" typos that Zig's per-species/
generic-kernel architecture already cannot reproduce** (see Section 6):
`issue-020` (nitro.f litter NO3 clamp direction), `issue-021` (starte.f/
solute.f litter Gapon exchange valence weighting), `issue-025` (grosub.f
litterfall salt `ZEROP` wrong grid-index -- legacy-only, no Zig counterpart
exists to even carry the bug), `issue-029` (trnsfr.f/trnsfrs.f vertical
macropore netting applied to only one flow direction, confirmed in both the
gas and salt sibling files), `issue-033` (redist.f macropore H2 relayering
silently dropped, five siblings correct), `issue-036` (solute.f litter
cation-exchange closure reads a stale soil-layer leftover), `issue-041`
(trnsfr.f H2 macropore diffusive flux reuses the NH4/NH3 diffusivity
constant), `issue-042` (trnsfrs.f macropore boundary branch coverage misses
one of four discharge/recharge cases), `issue-043` (trnsfr.f: three co-located
defects -- six inorganic gases hardcoded to zero at the subsurface macropore
boundary; a recharge-branch variable mix-up; a "reset the wrong species
family" zero-branch), `issue-045` (solute.f: 2 of 4 closing-block minerals
missed the same-iteration-freshness exemption their siblings got), `issue-046`
(solute.f litter `RHCO3` clamp reads a stale, unrelated carboxyl-exchange
scratch variable), `issue-048` (watsub.f under-snow soil freeze-thaw uses the
litter's heat capacity instead of the soil's -- Zig's non-reproduction is
**plausible but not yet confirmed** by tracing the actual call site; treat as
provisionally in this group pending that trace).

**Group B -- other already-favorable, undocumented deviations or paperwork-only gaps:**
- `issue-027`: `starte.f` reads a never-declared, never-assigned local
  (`FIONX`) in 3 reactions -- genuinely undefined legacy behavior (stack
  garbage under the historical `-auto-scalar` build flag). Zig normalizes to
  the one sensible constant (`FIONS`) uniformly. Needs a reviewer sign-off,
  not a fix.
- `issue-034`: `redist.f`'s surface-litter ion-inventory diagnostic
  double-counts one adsorption term. Zig **deliberately** reproduces this
  bit-for-bit (with an in-code comment already naming it) to keep a legacy
  diagnostic quantity in exact parity. Needs a reviewer to confirm this
  parity choice is still wanted and to add the missing line-number citation.
- `issue-035`: `redist.f`'s erosion/SOC top-of-profile boundary-carry
  statement is missing (present for the other 3 of 4 mechanisms). Zig's
  uniform-boundary-assignment design already avoids the gap; currently
  latent regardless (the consuming legs are separately zeroed, see
  `issue-012`).
- `issue-050`: **RE-RANKED to Tier 1, see correction below -- this bullet's
  "pure paperwork" framing is stale.** The dimensional fix to the
  water-table/tile-drain boundary formulas (`GRID-INV-001/002`) is still a
  real, already-tested, paperwork-only gap on its own. But a same-day
  closing-pass discovery, since confirmed by a dedicated follow-up
  (2026-09-19), found that this issue also bundles a second, unrelated
  substitution (`recharge_frequency_divisor` hardcoded to `0`/`1` at
  `ecosys-ng/src/soil/water/solver_residual.zig:474,498,513,530`) that is
  demonstrably **not** paperwork: the in-scope Ottawa deck's own site file
  sets the real `RCHGNUG=RCHGSUG=10.0` (not `0`) with N/S exchange enabled
  (`RCHGNTG=RCHGSTG=1.0`), and Ottawa's grid is a true 1x1 cell where every
  face -- including N and S -- is a boundary face by construction
  (`f77src/main.f:46` reads `NHW,NVN,NHE,NVS=1,1,1,1` from
  `runottawa`'s first line; independently confirmed via
  `ecosys-ng/src/soil/profile/boundary_topology.zig:261,263` where a
  1-row grid's sole row satisfies both the north-face and south-face
  conditions at once). See `issue-050`'s own "Follow-up resolution
  (2026-09-19)" section for the full evidence chain.
- `issue-014`: a real legacy self-clobber bug (east/south-bound eroded-
  constituent transport is permanently zero in the Fortran) is correctly
  **not** reproduced by Zig -- but the code comment justifying that choice
  claims the path is "inert," which is false (`IERSNG=3` is selected by the
  actual Ottawa site file, and the path is live-wired). Needs the comment
  corrected and a proper feature-register entry made **before** G3 output
  comparison, or this will be misdiagnosed later as an unexplained
  translation bug.

---

## 4. Tier 3 -- confirmed real gaps (Zig missing something legacy has, or vice versa)

Ranked by confidence x likely impact, per each issue file's own materiality
discussion; ranking is based on reachability/scope, not measured magnitude.

**Re-ranked 2026-09-19**: a bounded, read-only, input-file/reachability
follow-up (the same method demonstrated on `issue-050`, see Section 1's
correction) was run on the four items this section previously flagged as
"harder-to-scope... need an input-file check before anyone can even judge
urgency" (`issue-028`, `issue-031`, `issue-044`, `issue-056`). All four came
back **decisively NOT reachable** (or, for `issue-056`'s rainfall side,
reachable-but-immaterial) for the in-scope Ottawa deck, from its own input
files alone -- no run needed. Each issue file's own "Follow-up resolution
(2026-09-19)" section has the full evidence chain. This moves all four down,
below the three items with a confirmed-or-plausible-live materiality
(`issue-040`, `issue-054`, `issue-017`) and alongside the pre-existing
dormant/latent items (`issue-012`, `issue-055` Part B, `issue-037`). No
other item's ranking changed.

1. ~~`issue-040`~~ **RE-RANKED to Tier 1, 2026-09-19 -- see Section 1's
   correction and the Tier 1 table above.** Root osmotic/turgor water
   potential (`PSIRO`/`PSIRG`) was never ported; Zig substitutes a static
   per-plant trait constant that never responds to root water status,
   temperature, or solute concentration. The already-correct canopy-side
   sibling shows the intended formula was known and portable. Silently
   weakens a designed drought-response feedback on root extension growth.
   High confidence, plausible real impact, not yet quantified -- but a
   bounded scoping check found the fix requires new cross-module plumbing
   (not a simple wire-up) and that reachability cannot be bounded from
   static input files alone, so this no longer belongs in this tier's
   "concrete, well-localized, cheap to fix" framing (see Section 8 item 5's
   correction).
2. **`issue-054`** -- This is the one Tier-3 item that is a **Zig-introduced**
   translation bug, not an avoided legacy defect: legacy correctly uses two
   different band/non-band volume fractions for the NH3-oxidizer's own NH4
   fallback vs. the NO2-oxidizer's own NO2 fallback; Zig's `makeZone` collapses
   both into one shared field, wiring the ammonia-oxidizer to the wrong
   (nitrate-zone) fraction. Reachable at minimum on hour 1 of every layer and
   after any demand-history reset. Inert only if the deck's NH4/NO3 band
   geometries coincide (not checked).
3. **`issue-017`** -- Two pool families (adsorbed cations/anions/precipitates;
   root gases) behave differently between Fortran's pond and soil relayering
   branches; Zig applies the soil-branch rule uniformly to both. Confirmed
   **production-live** (pond boundary changes are real, not dormant) --
   distinguishes this from most other Tier-3/Tier-2 items. **Follow-up
   (2026-09-19): CONFIRMED REACHABLE for Ottawa**, from the deck's own input
   files (no run needed), using the same bounded reachability method as
   `issue-050`/`028`/`031`/`044`/`056`. The Fortran pond branch's actual
   trigger (`redist.f:8530-8531`'s `NN>1 AND IFLGL(L,NN)=1` disjunct) fires
   whenever hourly surface water+ice exceeds the site's `VOLWD` ponding-
   capacity threshold (`hour1.f:2373`), which for Ottawa's flat, unfrozen
   ground works out to only ~4.7mm depth (`ZSX=0.025` m, `hour1.f:118`).
   Ottawa's own `gbf98h` weather file records single-hour precipitation of
   10mm (day 198), 12.6mm (day 269) and 14.8mm (day 270) in 1998 alone, each
   more than double that threshold. This re-ranks `issue-017` up from a
   generic Tier-3 "confirmed real gap" to a Tier-1-shaped item (needs a
   scientist/conservation decision on materiality, not more static analysis)
   -- see `issue-017`'s own "Reachability check (2026-09-19)" section for the
   full evidence chain and an honest caveat (this is a threshold comparison
   against raw precipitation, not a run-observed trace of `IFLGL` actually
   firing inside the hydrology solve).
4. **`issue-012`** (`GEOM-SUBSIDENCE-001`/`PR-GEOM-01B`) -- A real, live-wired
   uncancelled-SOC-change defect in the soil-geometry-boundary transaction,
   but currently **latent**: a separate, independent hard-wired zero
   downstream prevents it from moving any layer boundary today. Explicitly
   flagged "do not fix in isolation" by its own in-code comment.
5. **`issue-028`** (re-ranked down 2026-09-19, was #3) -- `starte.f`'s
   one-time "50% of initial manure protein-N becomes ammonium" amendment has
   no Zig counterpart at all -- confirmed a missing routine, not a
   mistranslated one. **Follow-up (2026-09-19): CONFIRMED NOT REACHABLE.**
   `f25sol98`'s manure C/N/P fields (`RSC(2,...)`/`RSN(2,...)`/`RSP(2,...)`)
   are exactly zero at the surface and every one of the 10 soil layers, in
   both the legacy and modern copies of the input file. The amendment
   operates on a confirmed-zero quantity for this deck; the missing routine
   remains tracked, not closed.
6. **`issue-031`** (re-ranked down 2026-09-19, was #5) -- `redist.f`'s
   ground-surface secondary CH4 combustion mechanism (Michaelis-Menten-
   limited, O2-budget-capped) has no confirmed Zig counterpart. **Follow-up
   (2026-09-19): CONFIRMED NOT REACHABLE.** The mechanism sits behind an
   outer fire gate (`ICHKF`) that requires either a scheduled `ITILL=22`
   burn event or an ambient 100 degC temperature; neither ever occurs across
   the deck's full five-file, 1998-2002 tillage schedule (`ITILL` codes used:
   `10,10,8,4,1,1,5,1,1,5,2,8,1,5` -- no `22`), so this sub-block (nested at
   an even higher 200 degC gate) never executes on either side.
7. **`issue-044`** (re-ranked down 2026-09-19, was #6) -- Zig's
   irrigation-water-chemistry schema has no gas species field at all
   (CO2/CH4/O2/N2/N2O/H2), a broader gap than the single legacy H2-only
   omission this issue started from. **Follow-up (2026-09-19): CONFIRMED NOT
   REACHABLE.** Every one of the deck's six yearly land-management manifests
   (`f25m98`..`f25m03`) specifies `NO` in the irrigation-file slot -- no
   irrigation is ever scheduled, so the `FLU`-driven flux this whole
   mechanism depends on is zero every hour regardless of implementation. The
   three mechanism-identity/scope questions the issue raises remain open in
   principle but are no longer urgent for this deck.
8. **`issue-056`** (re-ranked down 2026-09-19, was #7) -- `starte.f`'s
   rainfall/irrigation ion-pairing/complexation network (Al/Fe/Ca/Mg/Na/K/
   SO4/CO3) has no confirmed Zig counterpart beyond a narrow closed-form
   NH4/phosphate piece. **Follow-up (2026-09-19): CONFIRMED NOT REACHABLE/
   immaterial.** The irrigation (`K=2`) side is moot (no irrigation
   scheduled, same finding as `issue-044`); the rainfall (`K=1`) side fires
   every year but the weather files' own rainfall-chemistry record gives
   `CALRG=CFERG=CCARG=CMGRG=CNARG=CKARG=CSORG=CCLRG=0` for every year
   checked (1998, 1999, both legacy and modern copies) -- the omitted
   complexation reactions converge trivially to zero on both sides.
9. **`issue-055` (Part B only)** -- For `ISALTG!=0` decks (not currently used
    by any deck in this project), the litter-specific cation-exchange/carboxyl
    Newton solve (`starte.f:1726-1906`) has no Zig implementation at all.
    Currently dormant, lowest priority in this tier. (Part A of the same
    issue -- a real legacy stale-scalar defect that Zig's unconditional zero
    happens to sidestep -- belongs with the Tier 2 pattern; see Section 6.)
10. **`issue-037`** (re-ranked down from this section's former #1 -- see
    "Correction" in Section 1 above) -- The restricted/static-salt
    (`ISALTG=0`) variants of soil cation-exchange, NH4-NH3 dissociation, and
    phosphate exchange are translated and unit-tested but have **zero
    production callers**; the full dynamic-salt formulas run instead,
    unconditionally. Originally ranked #1 in this tier on the strength of
    `issue-053`'s claim that Ottawa is an `ISALTG=0` deck. That claim is
    **wrong**: a definitive re-check of `f77src/readi.f:154` against both
    `f77example/Cool Temperate Maize-Soybean ON/f25si98` line 3 and the
    modern `ecosys-ng-prod-examples/.../f25si98` line 3 confirms Ottawa is
    `ISALTG=1` (dynamic-salt) on both the legacy and Zig sides (Zig's own
    `site.zig` parses this field into `salinity_enabled_by_cell`, which
    resolves `true` for Ottawa). Because the legacy oracle itself runs the
    dynamic-salt formulas for Ottawa, Zig's always-dynamic production
    behavior is the *correct* match for this deck -- not a divergence from
    it. This is now the same shape as `issue-055` (Part B) directly above:
    dormant, correctly-translated reference code for an `ISALTG=0`
    condition not exercised by any deck currently in scope. Retained in
    Tier 3 (not demoted to Tier 4) only because the code itself is a real,
    reachable-if-a-future-deck-sets-`ISALTG=0` gap worth a documented scope
    decision (per `issue-037`'s own "Disposition": document as intentionally
    dormant reference translations, per the contract's "dormant branches
    remain in the inventory" clause) -- it is lowest priority in this tier
    and does **not** affect the validated Ottawa deck today.

---

## 5. Tier 4 -- low-materiality / cosmetic / paperwork-only

- `issue-004` (topography/site-file consolidation -- unresolved input-mapping question, never shown to be an actual defect)
- `issue-006` (embedded-tag working note, superseded/folded into other issues and feature dossiers)
- `issue-013` (audit-tooling metadata bug: a stage-execution census mischaracterizes a stage as unprovable-as-executed when it is trivially provable; zero science/output impact)
- ~~`issue-050`~~ **REMOVED from Tier 4, 2026-09-19 -- see Tier 1 addition below and Section 1 correction.** The `GRID-INV-001/002` dimensional-fix half of this issue is still feature-register paperwork, but the issue also bundles a confirmed-reachable `recharge_frequency_divisor` hardcoding gap that is not paperwork; the issue as a whole is re-ranked to Tier 1.

---

## 6. Cross-cutting patterns (stated once, applies throughout)

**Pattern A -- "N parallel blocks, one outlier."** By far the most common
defect shape found this session (15+ confirmed instances: `issue-017`,
`018`, `020`, `021`, `025`, `029`, `033`, `034`, `035`, `036`, `041`, `042`,
`043`, `045`, `046`, `047`, `048`, `050`, `051`, `054`, `055`). A legacy
author hand-duplicated a block of statements for a sibling species/direction/
domain/organ and either forgot to update one variable name, forgot one member
of a species family, or never wrote the mirror-image branch at all. When you
see "confirmed by direct comparison against N structurally identical sibling
locations" in an issue file, this is the pattern; it does not need to be
re-explained per item above.

**Pattern B -- "Zig's generic/architectural design incidentally avoids a
legacy defect without a documented review."** The second most common shape
(most of Tier 2 above). Because Zig frequently replaced N hand-unrolled
Fortran call sites with one generic, per-species/per-domain-parameterized
kernel, many Pattern-A legacy defects are architecturally *impossible* to
reproduce in Zig -- not because anyone found and fixed that specific
statement, but as a side effect of the kernel's genericity. This is
scientifically favorable but creates two risks the contract's evidence
discipline exists to catch: (1) no record exists distinguishing "reviewed and
approved" from "nobody has looked," and (2) a future refactor toward a more
"optimized," per-species-unrolled version of the same kernel could silently
*reintroduce* the exact legacy defect with no test flagging it as a
regression against the Fortran (only against Zig's own prior behavior).
Every Tier 2 item's recommended action is some version of "add the citation/
comment so this is protected against that refactor."

---

## 7. Still-open, actively-tracked investigation: `issue-024`

`issue-024` (top 1-2 soil layers' water content diverges from the oracle,
growing from -53% at hour 1 to +124% by hour 2,578) is not a simple defect
report -- it is a live, multi-round (5 rounds, 11 numbered experiments)
investigation, and should be read as such, not re-derived. Current state:

- **Ruled out** (rounds 1-3): baseline/initialization mismatch; the
  already-known `SOIL-INITSAT-001` water-table-saturation gap (doesn't touch
  this layer); evaporation as the dominant hour-1 term (it's freeze-thaw,
  not evaporation); a raw air-temperature forcing/parsing mismatch (proven
  byte-identical inputs and a correct Zig parser).
- **Ruled out** (round 4, bounded 2-experiment follow-up on `issue-048`):
  the litter-heat-capacity substitution bug is real and would matter *if*
  reachable, but is structurally unreachable at hour 1 for this specific deck
  (zero snowpack, zero hour-1 precipitation) -- so it does not explain this
  issue's hour-1 finding, though it remains open for later snow-covered
  hours.
- **Substantially deprioritized, not eliminated** (round 5, bounded
  follow-up on `issue-053`): a real Zig production-path osmotic potential was
  hand-derived for the exact cell/hour for the first time (`~-0.0076 MPa`), and
  a sensitivity check shows this magnitude (and any plausible value the
  still-unobtained Fortran-side number could take, for this non-saline deck)
  is roughly 3 orders of magnitude too small to explain the observed >=15 degC
  effective freeze-threshold gap by itself.
- **Two live candidates remain**: (1) the **matric** (not osmotic) component
  of the potential feeding the verified-textually-identical freezing-point
  formula on each side -- still requires one instrumented log line on each
  side, never yet added; (2) a possible structural gap where Zig's flat
  substep-recovery schedule doesn't compound the way Fortran's `NFH x NPH`
  (4 x >=20 = >=80 substeps/hour for this thin, low-heat-capacity top layer)
  does.
- **What's needed next**: a genuinely new instrumented short run (both sides
  logging the matric potential at the point it feeds the freezing-point
  formula) -- everything obtainable from existing captured logs and hand
  computation has now been extracted. This is explicitly *not* the same
  frontier as `issue-015` (different hour, different mechanism family), but
  both eventually route through the same reaction/phase-change machinery, so
  a fix to either should be re-checked against the other before being
  declared complete.

---

## 8. Recommended order of attention

Opinionated, given limited reviewer time:

1. **`issue-015` first, and only via a scope/design decision, not another autonomous fix attempt.** This is the sole item standing between the project and "the production run completes." Two well-evidenced experiments are already spent; a third blind guess is against the contract's own discipline. Get the human/numerical-methods input the issue itself asks for, or make the scope call (shorter validated horizon vs. full 262,920-hour run) explicitly rather than by default.
2. **`issue-002` is already resolved (correction, post-dates this triage's initial pass) -- the remaining action is only deciding whether to preserve the 1.33GB oracle output durably outside the session scratchpad**, not building/running anything further. Low urgency, pure housekeeping.
3. **`issue-024`, next, because it is a live investigation one instrumented run away from real progress**, and because its outcome (matric-potential value or substep-schedule gap) plausibly also matters for #1's stiff-solver frontier -- these two investigations should not proceed in total isolation from each other.
4. **Batch the Tier 2 sign-offs in one reviewer pass**, grouped by the two cross-cutting patterns (Section 6) rather than one-by-one -- most of these need the same 30-second judgment ("Zig's generic kernel avoided this, agreed, add the citation") repeated ~16 times; a single reviewer session covering all of Tier 2 will be far more efficient than 16 separate reviews.
5. **`issue-054`** next among the remaining Tier-3 items -- concrete, well-localized, plausibly consequential, and cheap to fix once a reviewer signs off (a one-field wiring fix). **Correction (2026-09-19): `issue-040` (a formula port) is removed from this bullet and re-ranked to Tier 1** -- a bounded scoping check found it needs new cross-module plumbing (temperature/nonstructural-solute/salt-concentration arrays not currently threaded into the root water-balance call) and that its reachability cannot be bounded from static input files the way the items below were, so it is not "cheap to fix" in the way this bullet originally implied; see `issue-040`'s own "Scoping check (2026-09-19)" section and the Tier 1 table entry above. Separately, this bullet previously also called `issue-028`, `issue-031`, `issue-044`, `issue-056` "harder-to-scope... need an input-file check before anyone can even judge urgency." this bullet previously called `issue-028`, `issue-031`, `issue-044`, `issue-056` "harder-to-scope... need an input-file check before anyone can even judge urgency." A bounded follow-up has since done exactly that check for all four and found each one decisively **not reachable** (or, for `issue-056`'s rainfall side, reachable-but-immaterial) for the in-scope Ottawa deck -- see each issue's own "Follow-up resolution (2026-09-19)" section and the re-ranked Tier 3 list in Section 4. They no longer need scoping; they need only routine backlog scheduling, same as the other confirmed-dormant items.
6. **`issue-032` (test hang) before anyone leans on `zig build test` as a release gate.** It costs little to triage and its risk (masking an unrelated real failure under a CI timeout) is exactly the kind of thing that should not still be open when G2/G3 evidence starts depending on the test suite being trustworthy.
7. **Tier 1's remaining items (`issue-018`, `022`, `026`, `030`, `038`, `039`, `047`, `049`, `050`, `051`, `052`)** are all real judgment calls but none currently block anything -- schedule them as a standing backlog for whoever has the relevant domain expertise (solute chemistry for 018/038/045-adjacent; plant/root physiology for 039/047; land-surface/snow physics for 049/051/052; soil-water boundary calibration for 050, added 2026-09-19), rather than trying to force them through this audit's own general-purpose passes.
8. **`issue-037`, `issue-055` (Part B), `issue-028`, `issue-031`, `issue-044`, and `issue-056` last among Tier 3, alongside Tier 4** -- all six are now confirmed-dormant-or-immaterial for the in-scope Ottawa deck (the first two were already known dormant; the last four were confirmed by the 2026-09-19 follow-up, see Section 4 and item 5 above). `issue-037`/`issue-055`(B) need only the documentation-scope decision `issue-037`'s own "Disposition" section already describes (document as intentionally-dormant reference translations per the contract's dormant-branches clause); `issue-028`/`031`/`044`/`056` need only ordinary backlog scheduling for whoever eventually ports the missing routines, not an urgent wiring fix.
9. **Tier 4 items last** -- true paperwork, address whenever convenient, no urgency.
