# Issue 020 -- nitro.f litter-surface NO3 mineralization uses AMAX1 where all 7 sibling blocks use AMIN1 (likely legacy typo); Zig's correct-looking deviation is undocumented

Status: **OPEN, needs a review/approval record.** Zig's behavior is very likely the physically-correct one, consistent with 7 sibling blocks and the Fortran's own header comment -- but per contract, a deviation from the literal legacy source needs its own evidence/approval record, not a silent "obviously correct" retranslation.

Owner: found by this session's audit fork, 2026-09-18, during a `nitro.f` follow-up pass.

## What was found

`nitro.f`'s litter-surface (`L.EQ.0`) NH4/NO3/H2PO4/HPO4 mineralization-immobilization blocks are the surface sibling of the already-audited soil-layer blocks (`feature-005`). Comparing all eight nutrient x zone capacity-clamp statements:

| Block | Line | Clamp |
|---|---|---|
| NH4 soil-layer | `:2101` | `RINHX=AMIN1(RINHP, BIOA*OMA*TFNG*Z4MX*XNFH)` |
| NO3 soil-layer | `:2158` | `RINOX=AMIN1(RINOP, BIOA*OMA*TFNG*ZOMX*XNFH)` |
| H2PO4 soil-layer | `:2217` | `RIPOX=AMIN1(RIPOP, BIOA*OMA*TFNG*HPMX*XNFH)` |
| HPO4 soil-layer | `:2273` | `RIP1X=AMIN1(RIP1P, BIOA*OMA*TFNG*HPMX1*XNFH)` |
| NH4 litter | `:2329` | `RINHOR=AMIN1(RINHPR, BIOA*OMA*TFNG*Z4MX*XNFH)*(...)` |
| **NO3 litter** | **`:2377`** | **`RINOOR=AMAX1(RINOPR, BIOA*OMA*TFNG*ZOMX*XNFH)*(...)`** |
| H2PO4 litter | `:2419` | `RIPOOR=AMIN1(RIPOPR, BIOA*OMA*TFNG*HPMX*XNFH)*(...)` |
| HPO4 litter | `:2467` | `RIPO1R=AMIN1(RIP1PR, BIOA*OMA*TFNG*HPMX1*XNFH)*(...)` |

Seven of eight parallel blocks use `AMIN1` (demand capped by microbial uptake capacity -- the physically sensible reading: mineralization/immobilization cannot exceed what the microbial community can actually process). The eighth, surface-litter NO3 (`RINOOR`, `nitro.f:2377`), uses `AMAX1` (a floor, not a cap) -- contradicting its own header comment at `:2359` ("RINOOR=microbial limitation to NO3 demand," i.e. should cap, not floor) and its own NH4 sibling three lines above in the same block.

**Triangulated to rule out an intentional design choice**: checked the "opposite direction" (soil-layer NH4 vs. NO3, both `AMIN1` -- symmetric), the "same-litter-block" direction (NH4 vs. NO3 in litter -- asymmetric), and a third pole (both P blocks, both zones, all `AMIN1` -- no N-vs-P systematic pattern). This triangulation makes a legacy Fortran typo the most likely explanation, not a faithfully-preserved intentional asymmetry.

## What Zig does

`ecosys-ng/src/surface/microbial_mineral_exchange_step.zig` (sha256 `877DE675C756553527C7DDDE3DFE1DDEDC6AEF7E27F43B4D04CEDAB03DBE45C2`), `calculateExchange`/`calculateAcceptedExchange` (`:119-145`), applies `@min(demand, uptake_capacity)` **uniformly** for both ammonium and nitrate -- it does NOT reproduce the Fortran's `AMAX1` in the NO3 branch. The soil-layer Zig sibling (`nitrogen_exchange_step.zig:75,92`) likewise uses `@min` uniformly, matching the (also-`AMIN1`) soil-layer Fortran.

## Why this needs a record despite Zig almost certainly being right

Unlike this session's other confirmed-corrected findings (`GAS-METHANOGENESIS-DOUBLE-0.111-001`, `NITRO-N2FIX-SUPPLY`, both found in the same `nitro.f` pass with explicit tags/doc references/regression tests), this specific deviation from the literal Fortran source has **no in-code tag, no comment, no `docs/model_changes.md` entry, and no feature-register entry**. Per `PROJECT_CONTRACT.md`: "A discovered legacy defect needs evidence and review; do not silently change the reference or reproduce undefined behavior just to match it" -- the corollary is that NOT reproducing a legacy defect also needs evidence and review, on the record, not an implicit "obviously correct" retranslation that happens to look right on inspection.

## Disposition

`unresolved` pending a formal review/approval record. Practical risk assessed as low (Zig's behavior is arguably the safer, more physically sensible of the two, and is internally consistent with 7 other parallel blocks) -- this is a paperwork/evidence gap, not a suspected runtime defect, but it should not be left informally assumed-correct.

## Next bounded action

1. Independently re-verify `nitro.f:2359,2377` against a fresh read (done once already this pass, recommend a second independent check per the contract's review discipline before closing).
2. If confirmed a legacy typo, file the disposition as `legacy-defect-corrected` with this issue (or a promoted feature entry) as the record, citing the triangulation evidence above.
3. If there turns out to be a reason for the Fortran's asymmetry not yet found, document that reason and reconsider whether Zig's uniform `@min` needs adjustment.

## Evidence

`D:\ecosys-modernization\f77src\nitro.f:2101,2158,2217,2273,2329,2359,2377,2419,2467`; `D:\ecosys-modernization\ecosys-ng\src\surface\microbial_mineral_exchange_step.zig:119-145`; `D:\ecosys-modernization\ecosys-ng\src\soil\microbial\nitrogen_exchange_step.zig:75,92`.
