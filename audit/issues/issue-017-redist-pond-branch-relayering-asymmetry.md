# Issue 017 -- redist.f pond-branch layer relayering: two pool families are unconditional/active in the Fortran pond branch but Zig applies the soil-branch rule (gated/dead) uniformly

Status: **OPEN, candidate gap -- needs conservation/feature-attribution review, not yet confirmed as a defect.** Both findings below are real code-vs-code asymmetries verified against actual production call sites (not inferred from a stale comment) -- the Zig comments accurately describe current behavior; they simply don't address the pond-branch divergence from the legacy reference.

Owner: found by this session's audit fork, 2026-09-18, during a `redist.f` DO-245 deep-dive (~76% of the 8244-10604 block read).

## Finding 1: adsorbed cations/anions/precipitates -- soil-branch upward-only gate applied to the pond branch too

**Fortran soil branch** (`BKDS(L0)>0 AND BKDS(L1)>0`): `redist.f:9905` (`IF(L0.GT.L1)THEN`) gates ALL of adsorbed cations (`XCEC,XN4,...,XHC`, `:9905-9939`), adsorbed anions (`XAEC,XOH0,...,XH2PB`, `:9941-9976`), and precipitates/geochemical solids (`PALOH,...,PCPMB`, `:9978-10058`) -- closed by `ENDIF` at `:10059`. These pools move **only when the source layer index exceeds the destination** (upward transfer); a downward-deepening boundary does not move them.

**Fortran pond branch** (either side `BKDS<=0`): `redist.f:8984` ("POND ADSORBED CATIONS"), `:8991` ("...ANIONS..."), `:9014` ("...PRECIPITATES...") -- same pool set, transferred **unconditionally** whenever `FX>0`, no `L0.GT.L1` restriction in that block.

**Zig**: `relayering.zig:508-511` computes one rule for ALL callers: `const solid_transfer_fraction = if (src_layer > dst_layer) fx else 0;` (comment: "REDIST moves adsorbed/precipitated/geochemical solids only upward (L0>L1). Downward physical relayering still rebases concentrations onto the new carriers with a zero transfer.") Feeds `chemistry_remap.transferSolidLayerFraction` and `mineral_remap.transferLayerFraction`. Only one production call site exists (`relayering.zig:511/540`) -- no alternate pond-specific dispatch found anywhere in `ecosys-ng/src`. `pond_domain_transaction.zig:255` feeds live, nonzero `pond_m` into this same path, so the pond case is production-active, not dormant -- this rule genuinely applies to real pond-driven boundary changes.

**Implication**: Zig applies the Fortran *soil-branch* upward-only gate uniformly to pond-driven boundary changes too, where the Fortran pond branch has no such restriction.

## Finding 2: root gases -- pond branch active in Fortran, gas-inclusive Zig path is dead code

`redist.f:10413-10450` ("SOIL ROOT GASES"): every statement is commented out (`C` prefix) -- dormant in the soil branch, correctly and faithfully mirrored as excluded in Zig. But `redist.f:8800-8825` ("POND ROOT GASES") is **active** code in the pond branch, gated per-plant on `WTRTL(1,L0,...)>0 AND WTRTL(1,L1,...)>0` (`:8796-8797`).

Zig (`plant/root/plant_root_layer_remap.zig:57-84`) explicitly documents excluding gas fields from the *soil* relayer transaction (correctly matching the dormant soil branch), with a separate `domain_layer_extensive_fields` (gas-inclusive) list existing in the same file. But the only production call site (`relayering.zig:575`) routes through `transferPondedCellLayerFraction -> transferSoilRootLayerFraction`, which **always excludes gas fields for both pond- and soil-driven boundary changes**. The gas-inclusive `transferLayerFraction`/`transferCellLayerFraction` functions exist but are exercised only by the module's own unit tests -- confirmed dead in production by exhaustive grep of `root_remap.`/`transferLayerFraction(` across `ecosys-ng/src`.

**Implication**: the Fortran pond branch's active root-gas transfer has no live production Zig call path.

## Why both need review, not an immediate fix

Both findings share a shape: Zig's soil-branch rule (upward-only gating; gas exclusion) is faithful to the Fortran *soil* branch, but the Fortran *pond* branch behaves differently (unconditional transfer; active gas transfer) and Zig does not reproduce that difference -- it applies one unified rule to both. This could be:
(a) a genuine translation gap (an approved-or-not-yet-reviewed simplification that collapsed two legacy branches into one), or
(b) an intentional simplification with a rationale not yet documented (e.g. if pond-domain adsorbed/gas pools are negligible or handled by an equivalent mechanism elsewhere -- not checked in this pass).

Given the pond branch is confirmed production-active (not dormant), this is not a moot/inert finding like some others this session -- it is a real, live code path. It needs a scientist/conservation reviewer to determine (a) whether it is scientifically material for the Ottawa deck's actual pond dynamics, and (b) if so, whether to port the pond-specific unconditional-transfer/gas-active behavior.

## Disposition

`unresolved` for both findings, pending review. Not treated as confirmed defects -- the audit fork that found these was appropriately careful to distinguish "a real asymmetry exists" from "this asymmetry is wrong."

## Evidence

`D:\ecosys-modernization\f77src\redist.f:8560-10607` (multiple cited sub-ranges above); `D:\ecosys-modernization\ecosys-ng\src\soil\profile\relayering.zig:457-575`; `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_layer_remap.zig:4-172`; `D:\ecosys-modernization\ecosys-ng\src\soil\chemistry\layer_remap.zig:41-131`; `D:\ecosys-modernization\ecosys-ng\src\redistribution\ecosystem\pond_domain_transaction.zig:255`.

## Secondary, unconfirmed follow-up noted by the same fork (not filed separately)

`redist.f:9670-9693`'s fertilizer-band transfer uses `AMIN1(FX*pool(L,...), pool(L0,...))` (multiplicand is the *moving* layer `L`, capped by what's actually available in `L0`) -- a legacy self-referential-fraction idiosyncrasy. `ecosys-ng/src/soil/nutrients/fertilizer_layer_remap.zig:9-31`'s exact cap semantics were not verified to full depth this pass. Flagged for a future targeted check, not confirmed as a gap.
