# Issue 050: water-table/tile-drain boundary discharge-recharge dimensional fix has no feature-register entry

## Impact/severity

Low/paperwork, code and tests are internally consistent (same category as
`issue-019`). Filed because the contract requires "every intentional
difference" to have an individual feature-register entry, and this one does
not, despite being a real, tested, reasoned departure from the legacy
formula's own internal inconsistency and dimensional defect.

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
