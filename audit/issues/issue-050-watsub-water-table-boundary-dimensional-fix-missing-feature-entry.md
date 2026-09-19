# Issue 050: water-table/tile-drain boundary discharge-recharge dimensional fix has no feature-register entry

Status: OPEN -- NOT CLOSED as of 2026-09-19. Originally filed as low-severity
paperwork (missing feature-register entry only). A 2026-09-19 closing-pass
independent re-check found the issue's own "`RCHGFU`/`RCHGFA`~=0 in practice"
working assumption is **false** for the in-scope Ottawa deck's N/S lateral
boundaries (site file gives `RCHGNUG=RCHGSUG=10.0`, not 0), which the
production `recharge_frequency_divisor` hardcoding does not account for. See
the "Closing-pass discrepancy (2026-09-19)" section near the end of this
file for the full write-up. **A same-day bounded follow-up (see "Follow-up
resolution (2026-09-19)" section, further below) has now CONFIRMED both
open questions that section raised: the Ottawa deck is a true 1x1 grid where
every cell's N and S faces are boundary faces by construction, and the
site file's own N/S exchange-enable flags (`RCHGNTG=RCHGSTG=1.0`) are set,
so the hardcoded-divisor gap is reachable on the validated deck, not
hypothetical. Severity is escalated accordingly; do not treat this as
paperwork.**

## Impact/severity

**Escalated 2026-09-19 (see "Follow-up resolution" section below) --
NO LONGER low/paperwork.** Originally filed as: "Low/paperwork, code and
tests are internally consistent (same category as `issue-019`)," because
the contract requires "every intentional difference" to have an individual
feature-register entry, and this one did not, despite being framed as a
real, tested, reasoned departure from the legacy formula's own internal
inconsistency and dimensional defect.

**Superseded**: the "code and tests are internally consistent" framing
above refers only to the dimensional (`GRID-INV-001/002`) fix, which
remains sound. The separate `recharge_frequency_divisor` hardcoding is now
a confirmed, reachable-on-the-validated-deck discrepancy (a real per-site
`RCHGFU=RCHGFA=10.0` at Ottawa's N/S lateral boundaries, replaced in
production by a hardcoded `0`/`1`), not merely unverified paperwork. See
the "Follow-up resolution (2026-09-19)" section near the end of this file
for the full resolution of (a) grid dimensions and (b) the other gating
conditions, both now confirmed satisfiable for this deck.

## First bad time/cell/process

Not applicable -- this is a documentation/registration gap, not a runtime
defect. No build/run performed this pass (static source audit only).

## Reference and Zig source anchors

Legacy `f77src/watsub.f` (sha256
`8606E2EA96E52EE8109CF0EF78B6B49ABE0683E68BAA41FFACBEBAF1FE49DA95`) has six
structurally parallel boundary water-table/tile-drain flux formulas, all
active (non-commented) code, all of the shape
`driving_potential * conductivity * area * (geometry term) / <site modifier
term> * <exchange-fraction multiplier> * XNPHX`:

| Block | Lines | Divisor form |
|---|---|---|
| Micropore discharge above **natural** table | `:5819-5837` | `/(RCHGFU+1.0)` |
| Macropore discharge above **natural** table | `:5884-5893` | `/AMAX1(RCHGFU,1.0)` |
| Micropore discharge above **tile drain** | `:5934-5952` | `/(RCHGFA+1.0)` |
| Macropore discharge above **tile drain** | `:5994-6003` | `/AMAX1(RCHGFA,1.0)` |
| Micropore recharge below **natural** table | `:6048-6062` | `/AMAX1(RCHGFU,1.0)` |
| Macropore recharge below **natural** table | `:6116-6127` | `/AMAX1(RCHGFU,1.0)` |

This is an "N parallel blocks, 1 outlier" pattern repeated twice: in both the
natural-table and tile-drain families, the **micropore discharge** block is
the sole outlier using `/(RCHG+1.0)` while every other sibling (both
macropore-discharge instances and both recharge instances) uses
`/AMAX1(RCHG,1.0)`. These two forms are numerically identical only when
`RCHG=0`; they diverge for any other value. The commented-out predecessor
formula at `:5830-5831` (dead reference text, "`/AMAX1(RCHGFU,1.0)`") suggests
the micropore-discharge block's `+1.0` form is itself a drifted edit, not the
original intent.

Separately, none of these six formulas divide the driving potential by an
actual physical separation length before multiplying by conductivity and
area -- i.e. the legacy formula is dimensionally short one length power for a
proper Darcy gradient (`Q = K * (dPsi/L) * A`), a defect independently
confirmed by this session's own new unit tests (see below) demonstrating the
legacy-equivalent kernel does not scale as `c^1` under geometric rescaling.

Zig `ecosys-ng/src/soil/water/boundary.zig` (sha256
`E4C5B026D53AF293107E0DC40A1B76F8C283BFA71989098ECD7760ECAA285822`) fixes
both issues at once, already reviewed and tested, but **without a
feature-register entry**:

- `matrixDischarge` (`:69-83`) divides the driving potential by a real
  `external_separation_distance_m` (`:79`) -- documented `GRID-INV-001`/
  `GRID-INV-002` (`:55-59`, `:72-76`) -- restoring correct dimensional
  scaling (independently confirmed by
  `ecosys-ng/src/soil/water/boundary_dimension_tests.zig`'s `GRID-INV-R3`
  tests, which explicitly document: "Legacy `watsub.f` carries the same
  defect and absorbed it into site calibration of `recharge_frequency_
  divisor`, so legacy agreement is inadmissible evidence"
  `boundary_dimension_tests.zig:24-27`).
- The leftover legacy `RCHGFU`/`RCHGFA`-vs-`+1.0` inconsistency is
  neutralized by hardcoding `recharge_frequency_divisor` at each of the four
  production call sites in `ecosys-ng/src/soil/water/solver_residual.zig`
  (sha256 `F7C4EC006DAE315D0E9C162D2B580C8A5292343BC3975470146396D0616072E6`,
  `:474` `matrixDischarge` call passes `0`; `:498` `recharge` call passes
  `1`; `:513` `macroporeDischarge` call passes `1`; `:530` macropore
  `recharge` call passes `1`) rather than threading through a real per-site
  `RCHGFU`/`RCHGFA` value -- which is exact only for the `RCHG=0` case that
  the audit's own test-suite comment states is what site calibration
  produces in practice, but this equivalence has not been independently
  re-verified against the in-scope deck's actual site file this pass.

## Falsifiable cause

This is a genuine, deliberate, already-tested departure from the legacy
formula family (fixing both an internal legacy inconsistency and a
dimensional-scaling defect), not a translation accident -- but per contract
("Dall'Amico freeze-thaw ... Newton/Anderson and every other intentional
difference require individual entries in the feature register"), it needs
its own feature-register entry (parallel to `feature-001`/`feature-002`) and
was not found to have one during this pass's search of `audit/features/`.

## Minimal input/state to test

N/A for registration; for the underlying dimensional-fix's own validity, see
`boundary_dimension_tests.zig`'s existing `GRID-INV-R3` unit tests, which
already exercise this without a model run.

## Before/after results

N/A -- registration gap only; the underlying numerical fix already has
passing unit-level evidence in-repo (`boundary_dimension_tests.zig`).

## Suggested next action

Create `audit/features/feature-0NN-watsub-boundary-dimensional-scaling.md`
(next available feature number) documenting: the six-formula legacy
inconsistency table above, the dimensional defect, the `GRID-INV-001/002/R3`
fix, the `recharge_frequency_divisor` hardcoding rationale and its dependency
on `RCHGFU`/`RCHGFA` being effectively zero in valid site calibrations, and a
follow-up to independently confirm that assumption against the in-scope
deck's actual site file (not done this pass).

## Affected evidence invalidated

None -- the underlying fix's tests already exist and pass; only the
registration paperwork is missing.

## Independent review

Not yet done.

## Final disposition

`unresolved` -- **no longer paperwork-only as of the 2026-09-19 follow-up**
(see "Follow-up resolution" section below). The dimensional
(`GRID-INV-001/002`) fix remains a well-evidenced `legacy-defect-corrected`
candidate on its own. The separate `recharge_frequency_divisor` hardcoding
is now a confirmed-reachable discrepancy against the in-scope Ottawa deck's
own site file (`RCHGFU=RCHGFA=10.0` at N/S, not the `0` case the hardcoding
assumes) and needs a human/scientist decision (thread the real value
through, or document an approved rationale for the hardcode) before any
feature-register entry can be written for it.

## Closing-pass discrepancy (2026-09-19) -- DO NOT CLOSE, checked and disagrees with this issue's own working assumption

This issue was assigned for a routine "confirm and add a citation" closing
pass. Independent verification instead found that this issue's own stated
assumption -- "`RCHGFU`/`RCHGFA` is effectively zero in valid site
calibrations" -- **does not hold** for the in-scope Ottawa deck, on the
following evidence:

1. `f77src/readi.f:124-125` documents `RCHGNUG,RCHGEUG,RCHGSUG,RCHGWUG` as
   "distance from boundary grid cell to N,E,S,W external natural water table
   (m)" -- i.e. `RCHGFU` (assigned from one of these four per boundary
   direction at `watsub.f:5454,5471,5495,5512`) is a real, site-specific
   **distance in meters**, not a calibration knob that is normally zero.
2. `f77src/readi.f:155-156` reads these directly from site-file record 4.
   Both `f77example/Cool Temperate Maize-Soybean ON/f25si98` and the staged
   `ecosys-ng-prod-examples/.../landscape/f25si98` line 4 read
   `0.0 1.0 1.0 0.0 10.0 0.0 10.0 0.0 1.0 0.0 1.0 0.0 0.0 0.0`, which maps
   (in the exact order `readi.f:155-156` reads them) to `RCHGNUG=10.0`,
   `RCHGEUG=0.0`, `RCHGSUG=10.0`, `RCHGWUG=0.0`. **The N and S boundary
   directions have `RCHGFU=10.0`, not `0`.** Only E/W happen to be zero.
   This was checked directly against both copies of the actual site file,
   not assumed.
3. `watsub.f:5436-5540` shows `RCHGFU=1.0`/`RCHGFA=0.0` is hardcoded **only**
   for the vertical (`N=3`, lower/deep) boundary case (`:5533,5535`). For
   the four lateral directions (`N=1` E/W, `N=2` N/S), `RCHGFU`/`RCHGFA` are
   always read from the real per-cell `RCHGxU`/`RCHGxA` arrays -- there is
   no lateral-direction fallback to a default value in the Fortran.
4. Read `ecosys-ng/src/soil/water/solver_residual.zig:474,498,513,530`
   directly: all four production call sites pass a **literal constant**
   (`0` or `1`) for `recharge_frequency_divisor` -- none of them read a
   per-site, per-direction `RCHGFU`/`RCHGFA` value at all. There is no code
   path in `boundary.zig` or `solver_residual.zig` that threads the site
   file's `RCHGNUG`/`RCHGSUG`/etc. values through to this parameter.
5. Net effect if this boundary code is reachable for the N/S faces (grid
   dimensions not fully confirmed this pass, see below, but `f77example/Cool
   Temperate Maize-Soybean ON/runottawa`'s control-file line `1  1` is
   consistent with a single-column grid, which would make every lateral
   face a boundary face): legacy's micropore-discharge-above-natural-table
   divisor would be `RCHGFU+1.0=11.0` at the N/S faces, vs. Zig's hardcoded
   `0+1.0=1.0` -- an **~11x** difference in that term's magnitude. Legacy's
   macropore-discharge and both recharge divisors would be
   `AMAX1(RCHGFU,1.0)=10.0`, vs. Zig's hardcoded `1.0` -- a **~10x**
   difference. This is not the "`RCHGFU=0` in practice" case this issue's
   disposition was conditioned on; it is the opposite case, and it is
   real for this specific deck's N/S boundaries, not merely hypothetical.

**What this does NOT change**: the dimensional fix itself (`GRID-INV-001`/
`GRID-INV-002`, dividing by a real `external_separation_distance_m`) is a
separate, independently-motivated correction and is not undermined by this
finding -- `boundary_dimension_tests.zig`'s `GRID-INV-R3` tests check scaling
behavior, not the `recharge_frequency_divisor` substitution. The part that is
now in question is specifically the `recharge_frequency_divisor` hardcoding
described in this issue's own text, which this issue itself already flagged
as "not independently re-verified" -- that flag was warranted, and the
re-verification disagrees with the assumption needed to call it exact.

**What was not established this pass** (bounded scope, comment-only closing
pass, no `zig build`/run performed): (a) definitive confirmation of Ottawa's
grid dimensions (`NHW,NHE,NVN,NVS`) from the actual control-file parsing
code, to settle whether the N/S lateral boundary faces are genuinely present
in this deck's grid, not just plausible from the `1  1` control-file line;
(b) whether `matrix_discharge_enabled`'s other gating conditions
(`solver_residual.zig:458-471`, water-table depth relative to layer
midpoint) are ever actually satisfied at an N/S face for this deck at any
hour; (c) the actual magnitude of the resulting flux difference in physical
units (m3 of water), only the divisor ratio.

**Disposition: left as `unresolved`, NOT closed, NOT converted to
`legacy-defect-corrected`.** This issue should be escalated for a
dedicated, bounded follow-up (grid-dimension confirmation, then a
matched-state check of whether the N/S natural-water-table boundary path is
live for Ottawa) before any feature-register entry is written claiming the
`recharge_frequency_divisor` substitution is exact for this deck. No feature
file was created this pass. No comment was added to `boundary.zig`/
`solver_residual.zig` claiming a reviewed disposition, since that would
misrepresent this finding as settled. Traceability: `audit/traceability/
traceability.csv` already has a row for this issue (`TRC-223`) with
disposition `legacy-defect-corrected`; that recorded disposition should be
treated as **premature** in light of this finding and revisited by whoever
next has write access to `traceability.csv` (it was already
modified-but-uncommitted by a concurrent agent this session and was
therefore off-limits to edit directly this pass).

## Follow-up resolution (2026-09-19) -- (a) and (b) both CONFIRMED reachable; severity escalated

A dedicated, bounded, read-only follow-up (no `zig build`/run performed,
exactly as scoped) resolved the three open questions from the closing-pass
discrepancy section above.

**(a) Grid dimensions -- CONFIRMED, 1x1 single-cell grid, N and S are both
boundary faces simultaneously.** The closing-pass note above cited
`runottawa`'s `1  1` control line as suggestive evidence, but that specific
line is actually the `NAX,NDX` scenario-count record (`f77src/main.f:64`),
not the grid-dimension record. The real grid-dimension record is read one
line earlier and is unambiguous:

- `f77src/main.f:46`: `READ(5,*)NHW,NVN,NHE,NVS` is the *first* stdin read in
  the program.
- `f77example/Cool Temperate Maize-Soybean ON/runottawa` line 1 (the first
  line inside the `eor` heredoc): `1,1,1,1` -> `NHW=1,NVN=1,NHE=1,NVS=1`.
  This is a true 1x1 grid: one column, one row, no interior neighbors in
  any direction.
- Independently confirmed on the Zig side: `ecosys-ng-prod-examples/Cool
  Temperate Maize-Soybean ON/runottawa` line 3, `1,1,5` ->
  `horizontal_cell_count=1, vertical_cell_count=1, plant_species_count=5`
  (`ecosys-ng/src/driver/runscript.zig:1780-1793`, domain header parsing).
- `ecosys-ng/src/soil/profile/boundary_topology.zig:261` and `:263`:
  `if (row == 0) appendLateral(..., .north, ...)` and
  `if (row + 1 == rows) appendLateral(..., .south, ...)`. For a 1-row grid
  (`rows=1`), the single row satisfies **both** `row==0` and `row+1==rows`
  simultaneously -- the one and only cell is wired as a north boundary face
  **and** a south boundary face at the same time, by construction, not by
  edge case. There is no "most cells aren't boundary cells" escape here:
  100% of cells (i.e. the one cell) have live N and S boundary faces.

**(b) Gating conditions -- CONFIRMED satisfiable, from the deck's own site
file, independent of any run.** `f77src/readi.f:155-156`'s read order is
`RCHQNG,RCHQEG,RCHQSG,RCHQWG,RCHGNUG,RCHGEUG,RCHGSUG,RCHGWUG,RCHGNTG,RCHGETG,
RCHGSTG,RCHGWTG,RCHGDG`. Applying this order to `f25si98` line 4 (`0.0 1.0
1.0 0.0 10.0 0.0 10.0 0.0 1.0 0.0 1.0 0.0 0.0` -- checked in both
`f77example/Cool Temperate Maize-Soybean ON/f25si98` and
`ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa_input_
files/landscape/f25si98`) gives, in addition to the already-confirmed
`RCHGNUG=RCHGSUG=10.0`: **`RCHGNTG=1.0`, `RCHGSTG=1.0`** (N/S natural-table
subsurface exchange flag = "unimpeded flow", not "no flow"). In
`ecosys-ng/src/soil/water/solver_residual.zig` terms, this is
`boundary_face.natural_exchange_fraction` for the N/S faces -- nonzero,
so it does not trip the `exchange_fraction == 0 continue` skip at line 447,
and `distance_m=10.0` does not trip the `distance_m <= 0 continue` skip
(`GRID-INV-001`) at line 453. Both of the outer gates that would exclude
this face from the boundary-flux kernels entirely are open for Ottawa's N
and S faces.
  The remaining, finer gate is the choice between the discharge branch
(`:473-474`, `matrixDischarge`, hardcoded divisor `0`) and the recharge
branch (`:487-498`/`:526-530`, `recharge`, hardcoded divisor `1`), which
depends on `midpoint_m` (layer midpoint depth) vs. `external_depth_m`
(natural water-table depth) and, for the discharge branch only, the
moisture-dependent `matrix_discharge_enabled` sub-loop at `:458-471`. Site
file `f25si98` line 3 gives `DTBLIG=1.0` (natural water-table depth = 1.0 m
below the surface), and `f25sol98` line 2 gives the Ottawa soil profile's
cumulative layer-boundary depths as `0.01,0.025,0.075,0.125,0.175,0.225,
0.3,0.5,0.8,1.30` m -- a 10-layer profile extending to 1.30 m, straddling
the 1.0 m water-table depth around layer 9. This means, purely from
geometry (independent of any hour's moisture state): layers with midpoint
depth < 1.0 m (roughly the top 8-9 layers) are discharge-branch candidates
every hour the finer moisture gate also fires, and layers with midpoint
depth >= 1.0 m (the bottom of the profile) are recharge-branch candidates
*regardless* of the moisture-dependent `matrix_discharge_enabled` check,
since the recharge branch's condition (`:487`) requires
`!matrix_discharge_enabled`, which is the common/default case, not a rare
one. Over a 6-year, 8760-hour/year run, this is not a hypothetical corner
case -- it is a geometrically-guaranteed daily condition. (Precisely which
of the four call sites fires in which hour was not traced hour-by-hour --
that still requires a run -- but at least one of the four call sites firing
at the N/S boundary on many/most hours is established by geometry alone,
and all four call sites share the same hardcoded-divisor defect.)

**(c) Physical-unit magnitude -- NOT computed, correctly left undone.** (a)
and (b) confirm the code path is reachable, so per this task's own
instruction (c) should be attempted -- but the *m3* magnitude (as opposed to
the already-established ~10-11x *divisor ratio*, unchanged from the
closing-pass section above: legacy `RCHGFU+1.0=11.0` vs. Zig's hardcoded
`0+1.0=1.0` for the discharge branch; legacy `AMAX1(RCHGFU,1.0)=10.0` vs.
Zig's hardcoded `1.0` for the recharge/macropore branches) depends on the
hydraulic conductivity, matric-potential gradient, face area and time
fraction actually realized hour-by-hour, none of which can be read
statically from input files -- it requires executing the model. That
remains out of scope for this bounded, read-only pass and is **not**
estimated or fabricated here.

**Severity escalation.** This is no longer "low/paperwork." Both conditions
this issue's own disposition was waiting on are confirmed satisfied for the
in-scope, validated Ottawa deck: a genuinely 1x1 grid where every boundary
is simultaneously N and S, and a real, nonzero, site-calibrated
`RCHGNUG=RCHGSUG=10.0` with subsurface exchange enabled (`RCHGNTG=RCHGSTG=
1.0`), silently replaced in production by a hardcoded `0`/`1` at all four
`ecosys-ng/src/soil/water/solver_residual.zig` call sites (`:419,474,498,
513,530` -- note `:419` is the lower/vertical boundary's
`recharge_frequency_divisor=1`, correctly matching legacy's own
`RCHGFU=1.0` hardcode for the vertical case at `watsub.f:5533,5535`, and is
**not** part of this defect; only the four lateral-boundary call sites at
`:474,498,513,530` are implicated). This is now a live,
reachable-on-the-validated-deck numerical discrepancy in a boundary water
flux, not a dormant/latent one. (The `:419` `freeDrainage` call passes its
own hardcoded `recharge_frequency_divisor=1` for the lower/vertical
boundary, structurally separate from the four lateral call sites at
`:474,498,513,530` this issue is about; legacy also hardcodes
`RCHGFU=1.0` for the vertical case at `watsub.f:5533` -- but whether
`freeDrainage`'s formula shape actually matches one of the six RCHGFU/RCHGFA
divisor forms this issue catalogs, or is a structurally distinct
"unimpeded gravity drainage" formula that does not use this divisor the
same way, was not traced this pass and is left as a separate, untouched
question, not folded into this escalation.) It should be treated as a
**Tier 1/Tier 3 functional gap requiring a human/scientist decision**
(thread the real per-direction `RCHGFU`/`RCHGFA` value through
`recharge_frequency_divisor` at the four lateral call sites, or produce a
documented, reviewed rationale for why the hardcoded `0`/`1` is the
intended, approved behavior despite disagreeing with the site file), not
Tier 2/Tier 4 paperwork. No feature
file has been written and none should be until this decision is made, since
writing one now would misrepresent the substitution as reviewed and exact.
`audit/traceability/traceability.csv` has been updated: `TRC-223`'s row is
left untouched (preserving history) and a new row `TRC-293` has been added
recording `disposition=unresolved`, explicitly noting it supersedes
`TRC-223`'s premature `legacy-defect-corrected` disposition, with this
pass's evidence. `audit/handoff-issue-triage.md` has been updated to move
`issue-050` out of Tier 2/Tier 4 framing into a new escalation note (see
that file's own edit for the exact wording).
