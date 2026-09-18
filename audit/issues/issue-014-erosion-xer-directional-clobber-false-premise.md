# Issue 014 -- EROSION-XER-DIRECTIONAL-CLOBBER-001: real legacy bug correctly not reproduced, but justified by a false "inert" premise; needs a proper review record before G3 output comparison

Status: **OPEN.** Not a suspected translation defect in the Zig code's actual behavior (which is likely the scientifically correct choice) -- the problem is that the choice rests on a false factual claim in its own justifying comment, and this creates a real, predictable, currently-undocumented divergence from the Fortran oracle that must be recorded before output comparison, per contract.

Owner: found by this session's audit fork, 2026-09-18, during a full-file `erosion.f` read.

## The legacy bug (confirmed real, independently re-verified)

`f77src/erosion.f:541-765`'s `DO N=1,2 / DO NN=1,2` loop computes east/south-direction eroded-constituent transport `X*ER(N,2,N5,N4)` when `NN=1`, then the `ELSE` branch on the `NN=2` iteration for the **same cell** (`:676-763`) zeroes those same `X*ER(N,2,N5,N4)` slots before the loop closes. Net effect: east/south-bound eroded-constituent (mineral/fertilizer/exchange/precipitate/organic-matter pool) transport is **permanently zero** in the legacy oracle -- only the west/north leg (`:766-901`) is ever live. Verified line-by-line this session, independent of the Zig comment that first surfaced it.

## The false premise

`ecosys-ng/src/erosion/eroded_constituents.zig:96-106` (tag `EROSION-XER-DIRECTIONAL-CLOBBER-001`) documents this bug accurately, then justifies deliberately NOT reproducing it (applying the transported fraction symmetrically to all four directions instead, `:107-125`) on the grounds that it is "currently inert either way: no production site configuration selects an erosion-enabled disturbance mode."

**This is false.** The actual required production site file, `f25si98` (present identically at `f77example/Cool Temperate Maize-Soybean ON/f25si98` and the staged `ecosys-ng-prod-examples/.../landscape/f25si98`), read via `readi.f:154` (`IETYPG,ISALTG,IERSNG,NCNG,...`), has record 3 = `33 1 3 1 1.0 0.0` -- i.e. **`IERSNG=3`** ("freeze-thaw + erosion + SOM gain/loss"), the exact value that activates every `IF(IERSNG.EQ.1.OR.IERSNG.EQ.3)` branch in `erosion.f` (lines 49, 328, 476, 502, 1014). Independently corroborated by a sibling comment for a *different* defect in the same codebase, `redistribution/erosion/organic_matter_apply.zig:66-67`: "The deck does select an erosion-enabled mode (`f25si98` record 3 gives `erosion_mode=3`), so the path is reachable." The `eroded_constituents` code path itself is not dormant either -- it is wired into the live hourly step via `ecosys_ng.zig:10360-12437` and `stages/hourly_sediment.zig:125,140`, through five active bridge modules. The two doc files the comment cites as support (`docs/discrepancy_register.md`, `docs/traceability/erosion_unbound_family_disposition.md`) do not exist anywhere in this repository (confirmed by glob) -- they may exist in the OneDrive reference copy; check there before assuming they were ever real.

## Why this matters for the "no science gaps" / output-comparison goal

The production Ottawa deck runs in `IERSNG=3` mode. That means:
- The Fortran oracle's real output has east/south eroded-constituent transport permanently zero (the bug's actual effect).
- `ecosys-ng`'s current code applies transport symmetrically in all four directions -- a **different, intentional, but unreviewed** choice.
- When G3 output comparison eventually runs, eroded-constituent mass distribution between cells will **predictably differ** from the oracle in a way that has a known cause (this defect/decision) -- but that cause is not currently documented anywhere reviewable, only in a comment whose supporting claim is false.

Per `PROJECT_CONTRACT.md`: "A discovered legacy defect needs evidence and review; do not silently change the reference or reproduce undefined behavior just to match it" -- the Zig side has correctly chosen not to reproduce a legacy defect, but the *evidence and review* half of that requirement has not happened. An unreviewed intentional difference is exactly the kind of thing that gets misdiagnosed as a translation bug during output comparison if nobody wrote it down properly first.

## Disposition

`unresolved` -- not blocking today (nothing is currently producing wrong output that wasn't already reviewed as "we're choosing not to reproduce this legacy bug"), but must be resolved with a proper record before G3.

## Next bounded action

1. Correct `eroded_constituents.zig:96-106`'s comment to remove the false "inert" claim and cite the actual `f25si98`/`IERSNG=3` reachability fact (do not just delete the false claim -- replace it with the truth, since a future reader needs to know this IS live).
2. Open (or upgrade this issue into) a proper `audit/features/` entry with disposition `legacy-defect-corrected`, citing the review rationale for why symmetric application is the scientifically preferred choice over reproducing the asymmetric self-clobber (this session's dossier, `feature-014`, has the raw citations; a dedicated feature entry should make the acceptance case explicitly).
3. When G3 output comparison eventually runs, expect and pre-document eroded-constituent east/south-vs-west/north asymmetry as an *approved* explained difference, not a mystery to re-diagnose from scratch.

## Evidence

`D:\ecosys-modernization\f77src\erosion.f:541-901`; `D:\ecosys-modernization\f77src\readi.f:152-158`; `D:\ecosys-modernization\ecosys-ng-prod-examples\Cool Temperate Maize-Soybean ON\runottawa_input_files\landscape\f25si98`; `D:\ecosys-modernization\ecosys-ng\src\erosion\eroded_constituents.zig:96-125`; `D:\ecosys-modernization\ecosys-ng\src\redistribution\erosion\organic_matter_apply.zig:66-67`; `D:\ecosys-modernization\ecosys-ng\src\ecosys_ng.zig:10360-12437`; `D:\ecosys-modernization\ecosys-ng\src\stages\hourly_sediment.zig:125,140`.
