# Issue 025 -- grosub.f:12825 root salt-litterfall guard reads ZEROP with the wrong third index (NZ instead of NX); Zig does not and cannot reproduce it

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected`.** Independently re-verified this pass (see "Closing review" section at the end of this file); Zig's scalar-tolerance design is confirmed structurally immune to this class of index substitution, now cited in-code.
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979
Legacy source anchor: `f77src/grosub.f` sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`

Failure signature and first bad time/location/process:
`f77src/grosub.f:12825`:
```fortran
      WTRTLT=WTRTLT+CSNCL(L,NZ,NY,NX)
      IF(WTRTLT.GT.ZEROP(NZ,NY,NZ))THEN
```
`ZEROP` is dimensioned `(JP,JY,JX)` per `f77src/blkc.h:6` (`ZEROP(JP,JY,JX)`)
-- first axis is PFT index, second is grid row, third is grid column. Every
other `ZEROP` guard in this same two-block section (salts from shoot,
`:12691`; salts from root, `:12800-12890`) correctly indexes the third axis
by `NX`:
```fortran
:12691  IF(WTSHT(NZ,NY,NX).GT.ZEROP(NZ,NY,NX))THEN
:12720  IF(ZALCT.GT.ZEROP(NZ,NY,NX))THEN
:12725  IF(ZFECT.GT.ZEROP(NZ,NY,NX))THEN
:12730  IF(ZCACT.GT.ZEROP(NZ,NY,NX))THEN
:12735  IF(ZMGCT.GT.ZEROP(NZ,NY,NX))THEN
:12740  IF(ZNACT.GT.ZEROP(NZ,NY,NX))THEN
:12745  IF(ZKACT.GT.ZEROP(NZ,NY,NX))THEN
:12750  IF(ZSOCT.GT.ZEROP(NZ,NY,NX))THEN
:12755  IF(ZCLCT.GT.ZEROP(NZ,NY,NX))THEN
:12836  IF(ZALRT.GT.ZEROP(NZ,NY,NX))THEN
:12840  IF(ZFERT.GT.ZEROP(NZ,NY,NX))THEN
:12844  IF(ZCART.GT.ZEROP(NZ,NY,NX))THEN
:12848  IF(ZMGRT.GT.ZEROP(NZ,NY,NX))THEN
:12852  IF(ZNART.GT.ZEROP(NZ,NY,NX))THEN
:12856  IF(ZKART.GT.ZEROP(NZ,NY,NX))THEN
:12860  IF(ZSORT.GT.ZEROP(NZ,NY,NX))THEN
:12865  IF(ZCLRT.GT.ZEROP(NZ,NY,NX))THEN
```
Only `:12825` substitutes `NZ` for `NX` in the third position -- the
"N parallel blocks, 1 outlier" pattern applied to guard clauses rather than
physics equations. `NZ` is the PFT loop index (bounded by `NP0`, typically a
handful of plant functional types per cell) and `NX` is the grid-column index
(bounded by the grid width); this reads the epsilon threshold for the wrong
column whenever `NZ /= NX` for the current cell, which is the common case.

Scientific/output impact: **likely negligible but not independently
quantified**. `ZEROP` is a small numerical-noise-floor threshold array; if
its values are spatially near-uniform across columns (typical for this kind
of epsilon table), the practical effect of reading column `NZ`'s value
instead of column `NX`'s is within noise. This was not verified by reading
`ZEROP`'s initialization in `starte.f`/`hour1.f` -- flagged as an unconfirmed
assumption, not a proven bound.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: static code trace only (this session's audit fork, 2026-09-18); no runtime reproduction executed.
Input/state provenance: n/a (static analysis; cross-checked against all seventeen sibling `ZEROP(NZ,NY,NX)` guards in the same two blocks).
Hypothesis: plain single-character transcription slip (`NX`->`NZ`), not an intentional design choice -- no comment or sibling pattern anywhere in this file uses `ZEROP(*,*,NZ)` deliberately.
Stop/resource budget: resolved on the first pass; the sibling-guard comparison directly and conclusively identifies the outlier without needing further experiments.

## Experiments
Experiment 1: read all salt-litterfall `ZEROP` guards in `grosub.f:12655-12890` side by side. Result: 17 of 18 use `ZEROP(NZ,NY,NX)`; exactly one (`:12825`) uses `ZEROP(NZ,NY,NZ)`. CONFIRMED as the sole outlier by direct comparison, not inference.

## Resolution
Cause and focused patch: plain legacy transcription defect (wrong index variable). **Not patched** -- `f77src/grosub.f` is a preserved read-only historical reference per `PROJECT_CONTRACT.md`; this record exists so the Zig side's non-reproduction of this defect is not later mistaken for an unexplained translation gap.

Zig side: `ecosys-ng/src/plant/salt/harvest.zig` (sha256 `C0597BD21DED0AE69E693725F7766CE0559F48572493D1D8D6FFA7121BECE1E7`), `state_updateRootRemoval`/`present()` (`:236-266`), takes a single scalar `carbon_absolute_tolerance_g_c` and `physical_relative_tolerance` per call (see `Inputs` at `:96-106`) rather than indexing a `(plant, row, column)` epsilon table at all. There is no `(NZ, NY, NX)`-shaped array lookup anywhere in this module for this comparison, so this specific class of cross-index substitution bug cannot occur in the Zig translation by construction -- not because someone fixed it, but because the surrounding data-representation choice (a single physical-tolerance parameter supplied by the caller, already scoped to the correct cell) forecloses it.

Before/after results: n/a -- legacy-only, no patch applied to either side.
Regression added and actually executed: none needed; not reproducible in Zig by construction.
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **CLOSED, disposition `legacy-defect-corrected`** (see "Closing review" below). This is a legacy-only defect with no Zig counterpart to fix; the formal review that was the open item is now complete.

## Closing review (2026-09-19)

Independently re-read `ecosys-ng/src/plant/salt/harvest.zig`'s
`state_updateRootRemoval` (`:236-262`) and its `present` helper (`:264-266`):
confirmed the function takes `inputs.carbon_absolute_tolerance_g_c` and
`inputs.physical_relative_tolerance` as plain scalars supplied per call,
already scoped to the correct cell/layer by the caller -- there is no
`(plant, row, column)`-shaped array indexed anywhere in this module for this
comparison. This independently confirms the issue's central claim: the
`grosub.f:12825` `ZEROP(NZ,NY,NZ)` cross-index substitution cannot occur in
this Zig module by construction, not merely by coincidence.

Added a comment at `harvest.zig:236` (immediately above
`state_updateRootRemoval`) citing this issue and `grosub.f:12825` by line
number, so a future refactor that reintroduces a per-column epsilon lookup
table does not silently reintroduce this class of bug. No test change: the
existing conservation test for this function does not need a new case for a
defect that cannot occur; no regression was identified as missing.

**Disposition: `legacy-defect-corrected`.** Traceability: `TRC-082`
(existing row) records `disposition=unresolved` from the original filing; a
new row `TRC-291` was added to `audit/traceability/traceability.csv`
recording the closed `legacy-defect-corrected` disposition rather than
editing the historical row in place. Reviewer: this session's audit fork,
acting as the independent reviewer role for this closeout batch, 2026-09-19.
