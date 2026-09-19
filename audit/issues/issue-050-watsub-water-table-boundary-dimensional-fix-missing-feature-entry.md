# Issue 050: water-table/tile-drain boundary discharge-recharge dimensional fix has no feature-register entry

Status: OPEN -- NOT CLOSED as of 2026-09-19. Originally filed as low-severity
paperwork (missing feature-register entry only). A 2026-09-19 closing-pass
independent re-check found the issue's own "`RCHGFU`/`RCHGFA`~=0 in practice"
working assumption is **false** for the in-scope Ottawa deck's N/S lateral
boundaries (site file gives `RCHGNUG=RCHGSUG=10.0`, not 0), which the
production `recharge_frequency_divisor` hardcoding does not account for. See
the "Closing-pass discrepancy (2026-09-19)" section near the end of this
file for the full write-up. Do not treat this as paperwork-only until that
section's open questions are resolved.

## Impact/severity

Low/paperwork, code and tests are internally consistent (same category as
`issue-019`). Filed because the contract requires "every intentional
difference" to have an individual feature-register entry, and this one does
not, despite being a real, tested, reasoned departure from the legacy
formula's own internal inconsistency and dimensional defect.

**Superseded in part, see bottom of file**: the "code and tests are
internally consistent" framing above refers only to the dimensional
(`GRID-INV-001/002`) fix, which remains sound. The `recharge_frequency_divisor`
hardcoding's exactness is now in question, not merely unverified paperwork.

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

`unresolved` (paperwork) -- the underlying numerical treatment is a
well-evidenced `legacy-defect-corrected` candidate, but cannot be marked
final in the feature register until the entry above exists and is reviewed,
and until the `RCHGFU=0` assumption is checked against the in-scope deck.

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
