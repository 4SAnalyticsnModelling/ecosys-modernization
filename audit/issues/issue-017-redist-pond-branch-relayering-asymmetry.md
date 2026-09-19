# Issue 017 -- redist.f pond-branch layer relayering: two pool families are unconditional/active in the Fortran pond branch but Zig applies the soil-branch rule (gated/dead) uniformly

Status: **OPEN, reachability CONFIRMED for the Ottawa deck (2026-09-19 follow-up) -- still needs conservation/feature-attribution review before a defect disposition can be assigned.** Both findings below are real code-vs-code asymmetries verified against actual production call sites (not inferred from a stale comment) -- the Zig comments accurately describe current behavior; they simply don't address the pond-branch divergence from the legacy reference. The 2026-09-19 reachability check (see section below) found, from the deck's own input files and source alone, that Ottawa's precipitation regularly exceeds the small (~4.7mm-depth) surface ponding-capacity threshold that gates the Fortran pond-relayering branch, so this is a live, recurring code path for this deck, not a dormant/paddy-only one. This raises this issue's priority (Tier-1-shaped: needs a human/scientist decision, not more static analysis) but does not by itself prove the asymmetry is scientifically wrong -- see "Why both need review" below, unchanged.

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

`unresolved` for both findings, pending review. Not treated as confirmed defects -- the audit fork that found these was appropriately careful to distinguish "a real asymmetry exists" from "this asymmetry is wrong." **Updated 2026-09-19**: reachability for the Ottawa deck is now CONFIRMED (not just "production-active" in the abstract, as the original finding already asserted from the Zig call-graph side) -- the triggering condition is met by ordinary rainfall in the deck's own weather files, not merely by construction. This does not change the disposition itself (still `unresolved`, still needs a scientist/conservation reviewer per "Why both need review" above) but it does mean the issue can no longer be deprioritized as latent or hypothetical; it should be treated as a live Tier-1 item.

## Reachability check (2026-09-19)

**Conclusion: CONFIRMED REACHABLE for the Ottawa deck.** This is an input-file/source-threshold inference (the same bounded, read-only method used this session for `issue-050`/`028`/`031`/`044`/`056`), not a run-observed trace of `IFLGL`/`FX` actually firing -- see caveat at the end.

**What gates the Fortran pond branch.** The branch that finding 1 and finding 2 both describe is entered at `f77src/redist.f:8530-8531`:
```
IF((BKDS(L0,NY,NX).LE.ZERO.AND.BKDS(L1,NY,NX).LE.ZERO)
 .OR.(NN.GT.1.AND.IFLGL(L,NN).EQ.1))THEN
```
i.e. pond-branch entry requires *either* both endpoints already being pond layers *or* (the disjunct that actually fires for this deck) `NN>1` and `IFLGL(L,NN)==1` for the boundary-change type being processed this hour. `IFLGL(L,3)=1` is set at `redist.f:8306-8314` ("RESET POND SURFACE LAYER NUMBER IF SURFACE LAYER REAPPEARS WITH PRECIPITATION") whenever
```
XVOLWP = MAX(0, VOLW(0)+VOLI(0) - VOLWD(NY,NX)) > VHCPNX(NY,NX)/4.19  [effectively > 0]
```
-- i.e. whenever the surface litter/pond node's water+ice content exceeds the site's surface ponding-capacity threshold `VOLWD`. When this fires, the subsequent generic `L0`/`L1`/`FX` computation (`redist.f:8481-8496`, since `IFLGL(L,3).EQ.1` selects the `ELSE` branch) sets `L0=0` (the pond node, `BKDS(0,...)` is by construction `<=0`) and `L1=NU(NY,NX)` (the real, `BKDS>0` topsoil layer), with `FX = XVOLWP/(VOLW(0)+VOLI(0)) > 0`. Because `L1` is a real soil layer, the branch's *first* disjunct (`BKDS(L0)<=0 AND BKDS(L1)<=0`) is false here, but the *second* disjunct (`NN=3>1 AND IFLGL(L,3)=1`) is true -- so this is precisely the "pond branch fires via ordinary precipitation-driven surface ponding" path, not a flooded-paddy-only path.

**Is `VOLWD` ever exceeded for Ottawa?** `VOLWD` is computed every hour at `f77src/hour1.f:2373`:
```
VOLWD(NY,NX)=AMAX1(ZSW,0.112*ZS(NY,NX)+3.10*ZS(NY,NX)**2-0.012*ZS(NY,NX)*SLOPE(0,NY,NX))*AREA(3,NU(NY,NX),NY,NX)
```
with `ZS=ZSX=0.025` m for ordinary (unfrozen, not-snow-loaded) ground and `ZSW=0.005` m otherwise (`f77src/hour1.f:118`). For Ottawa's flat field (`SLOPE~0`), this gives a ponding-capacity **depth** of `0.112*0.025 + 3.10*0.025^2 ~= 0.0047 m`, i.e. **~4.7 mm** of surface water+ice before the pond-reappearance branch fires. This is a generic microtopographic-storage threshold present at every site in the model (not a paddy-specific parameter) and it is small.

`ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa_input_files/weather/gbf98h` (byte-identical column layout to the legacy `f77example/.../gbf98h`) records single-**hour** precipitation values well above this ~4.7mm threshold within 1998 alone, e.g.:
- day 198, hour 1000: `10` mm in one hour (`gbf98h:4742`)
- day 269, hour 1800: `12.63` mm (`gbf98h:6454`)
- day 270, hour 0000: `14.83` mm (`gbf98h:6460`)

Day 198 (mid-July) falls squarely inside the Ontario maize/soybean growing season (planted May, harvested Sept/Oct per the deck's own management files), which also plausibly satisfies finding 2's additional per-plant root-presence gate (`WTRTL(1,L0,...)>0 AND WTRTL(1,L1,...)>0`) at the same time the pond branch fires, though root presence in the exact `L0`/`L1` pair was not traced hour-by-hour.

Any of these single-hour events, on their own, is more than double the ~4.7mm capacity -- and this ignores the additional, likely larger effect of multi-day accumulation (e.g. days 269-270 are consecutive) and spring snowmelt pulses, which were not separately inventoried here.

**Caveat (why this is "confirmed" from inputs, not run-proven).** This is a threshold comparison between a static per-hour capacity (`VOLWD`, depends only on `ZS`/`AREA`/`SLOPE`, all fixed per hour) and the deck's raw hourly precipitation. It does not simulate same-hour infiltration competing with the incoming rain, so it does not prove `VOLW(0)+VOLI(0)` actually exceeds `VOLWD` at those specific hours inside the real hydrology solve -- only that the input forcing is large enough, relative to the small fixed threshold, that this is very likely. A run-based confirmation (grep the legacy oracle's own diagnostic write at `redist.f:8329-8334`/`5597` format, if enabled, or add an instrumented counter on `IFLGL(L,3)` on either side) would close this definitively; no such run was performed here per this task's read-only scope.

**Evidence**: `D:\ecosys-modernization\f77src\redist.f:8291-8342,8437-8531`; `D:\ecosys-modernization\f77src\hour1.f:105-120,2338-2381`; `D:\ecosys-modernization\ecosys-ng-prod-examples\Cool Temperate Maize-Soybean ON\runottawa_input_files\weather\gbf98h:4742,6454,6460`.

## Evidence

`D:\ecosys-modernization\f77src\redist.f:8560-10607` (multiple cited sub-ranges above); `D:\ecosys-modernization\ecosys-ng\src\soil\profile\relayering.zig:457-575`; `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_layer_remap.zig:4-172`; `D:\ecosys-modernization\ecosys-ng\src\soil\chemistry\layer_remap.zig:41-131`; `D:\ecosys-modernization\ecosys-ng\src\redistribution\ecosystem\pond_domain_transaction.zig:255`.

## Secondary, unconfirmed follow-up noted by the same fork (not filed separately)

`redist.f:9670-9693`'s fertilizer-band transfer uses `AMIN1(FX*pool(L,...), pool(L0,...))` (multiplicand is the *moving* layer `L`, capped by what's actually available in `L0`) -- a legacy self-referential-fraction idiosyncrasy. `ecosys-ng/src/soil/nutrients/fertilizer_layer_remap.zig:9-31`'s exact cap semantics were not verified to full depth this pass. Flagged for a future targeted check, not confirmed as a gap.
