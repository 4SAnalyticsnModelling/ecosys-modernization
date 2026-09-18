# Issue 010 -- HOUR1-002: canopy radiation-fraction low-sun fallback omits stalk/standing-dead area

Status: **CLOSED (2026-09-18, same session) -- was a false alarm caused by stale documentation, not a live gap.** See "Correction" section below. Originally filed as OPEN based on `exposure.zig`'s own header comment; a direct trace of the actual call site proved the fix is already live in production and that comment simply was never updated after the fix landed elsewhere.

Owner: none currently assigned. Found by this session's audit fork, 2026-09-18.

## Failure signature

`f77src/hour1.f:4697-4736`+ computes `ARLSS` as leaf + stalk + standing-dead area summed over all layers/branches/PFTs above snow/surface-water depth, then derives `FRADT`/per-PFT `FRADP`/`FRADQ` as this leaf+stalk+dead-area-weighted share of absorbed+ground radiation.

`ecosys-ng/src/canopy/radiation/exposure.zig` (sha256 `017DB476283496C22219525141D92268090B2E48DF9D979A452E09D1ADDA1D99`), `applyTile`/`radiation_fractions` (`:59-113`). The file's own header comment explicitly tags this **`HOUR1-002`** and states it is **currently open**: the kernel's low-sun fallback branch computes radiation fraction from **leaf area only**, omitting stalk and standing-dead area -- understating canopy interception and overstating ground exposure fraction relative to the legacy `ARLSS` formula.

The faithful `ARLSS`-based quantity (leaf+stalk+dead) already exists elsewhere in the codebase -- `ecosys-ng/src/canopy/energy/precipitation_retention.zig`'s `refreshFromModel` correctly sums all three components (see `audit/features/feature-006-hour1-canopy-surface-physics.md` item 1) -- but `exposure.zig`'s fallback path is only bypassed when `context.radiation_fractions` is explicitly supplied by the composition root. Until that binding lands, the leaf-area-only fallback remains live in production.

`ecosys-ng/src/stages/hourly_snow_energy.zig:394` independently references the same `hour1.f:4713-4779` `ARLSS` sum, suggesting the correct formula is understood and implemented in more than one place -- the gap is specifically in `exposure.zig`'s fallback branch not being routed to it.

## Referenced but not found in this checkout

`exposure.zig`'s own comment points to `docs/binding_requests/A6_canopy_exposure_hour1_002.md` for the binding fix plan. This file does not exist under `D:\ecosys-modernization` (`docs/` is not present in this checkout at all, consistent with issue-005's established finding that this specific `D:` checkout is missing an entire class of non-`src`-core content -- documentation, scripts, validation fixtures -- present in the more complete OneDrive reference copy). **Before attempting a fix, check the OneDrive reference (`C:\Users\symon.mezbahuddin\OneDrive - Government of Alberta\ProjectsSymon\ecosys_modernization\ecosys-ng\docs\binding_requests\A6_canopy_exposure_hour1_002.md`, read-only) for the already-designed fix plan** -- do not re-design this from scratch if a specific plan already exists there.

## Scientific/output impact

Not yet measured. This affects canopy-vs-ground radiation partitioning specifically in the low-sun fallback branch (exact trigger condition for when the fallback fires vs. the correctly-wired path was not traced this pass). Given radiation partitioning feeds canopy energy balance and downstream boundary-layer/temperature calculations, this is plausibly a real, non-trivial science gap during low-sun conditions (e.g., early/late day, high latitude, overcast) -- but the magnitude and whether it's ever exercised by the Ottawa production deck specifically has not been assessed.

## Minimal reproducer and hypothesis

Not yet attempted. Hypothesis: the fallback fires whenever `context.radiation_fractions` is not supplied by the composition root (`ecosys_ng.zig`, per the cross-reference at `exposure.zig`'s own comment citing wiring near `ecosys_ng.zig:3509`/`exposure.zig:3775`) -- i.e., this may be entirely avoidable today by ensuring the composition root always supplies it, without needing a deeper fix to the fallback branch itself. This has NOT been verified against the actual composition root wiring in this pass.

## Stop/resource budget

No build/run attempted for this issue yet (read-only G1 pass). Per contract's three-experiment bound, this is hypothesis #0 (not yet tested) -- do not treat the paragraph above as a confirmed diagnosis.

## Correction (2026-09-18, same session): CLOSED -- the fix is already live in production; the "open" claim was stale documentation

Traced the actual (and, confirmed by grep, ONLY) call site of `ecosys.canopy_exposure.applyTile` in the whole codebase: `ecosys-ng/src/stages/hourly_snow_energy.zig:393-415`, inside `solveSnowSurfaceEnergyAndSoilTransport`. That function IS called from the live per-hour driver: confirmed via `Grep("solveSnowSurfaceEnergyAndSoilTransport")` returning `stages/hourly_process_driver.zig` as a caller (plus `atmosphere/atmospheric_solute_inputs.zig`, not investigated). The call site builds `exposure_context.radiation_fractions` as `if (context.canopy_precipitation_retention.*) |*retention| .{ .living_radiation_fraction = retention.living_radiation_fraction, .standing_dead_radiation_fraction = retention.standing_dead_radiation_fraction, .species_count = retention.species_count } else null` (`:410-414`) -- i.e., the ARLSS-faithful fractions ARE passed, unconditionally, whenever `canopy_precipitation_retention` state exists.

The surrounding comment at the call site (`:394-409`) reads as a resolution note, not an open-problem note: "Passing the retention owner's fractions retires `canopy_exposure`'s own leaf-area-only derivation... This RETIRES a producer rather than adding one... Ordering verified rather than assumed." This directly contradicts `exposure.zig`'s own header comment (which this issue was originally filed from), which says "Until that one field is passed, the leaf-area-only branch remains live and HOUR1-002 remains open" -- that comment was simply never updated after the fix landed at the call site.

**Reachability of the null fallback checked**: `canopy_precipitation_retention_state` (`ecosys_ng.zig:12962`) and `canopy_exposure_state`'s prerequisite `canopy_interception_state` (`:13247`) are both gated on plant-existence conditions (branch_count>0 / canopy_structure+optics non-null respectively) that in practice co-occur for any deck with plants -- including the Ottawa production deck. So the `null`-fractions fallback path is not exercised by the actual production configuration; it would only fire in a plant-less deck, where `canopy_exposure_state` itself would also be uninitialized (gated on `canopy_interception_state != null`, which itself needs plants), making the fallback effectively unreachable end-to-end.

**Disposition: `preserved`** (re-classified from `unresolved`). No code change made -- this is a documentation-accuracy finding, not a science fix. **Follow-up recommended (non-blocking): update `exposure.zig`'s stale header comment** (lines ~90-93) to stop claiming HOUR1-002 is open, so a future audit pass doesn't re-file this same false alarm. Not done in this session (out of scope for a read-mostly correction pass; flagged for whoever next touches that file).

## Lesson for the audit process

This is exactly the failure mode the project's own `docs/GOAL.md` (OneDrive reference, read-only) warns about: a ledger/comment declaring something open is a *declaration*, not a *measurement* of current staleness. **Before filing an issue from a comment alone, trace the actual live call site(s), not just the module that carries the stale claim.** The original `feature-006`/`issue-010` filing did read the module's own comment carefully and cited it accurately -- the comment itself was simply wrong/outdated, which only a call-site trace could catch.
