# Issue 010 -- HOUR1-002: canopy radiation-fraction low-sun fallback omits stalk/standing-dead area (OPEN, real science gap)

Status: **OPEN.** Found via source-embedded evidence (the project's own in-code tag, not independently re-derived from equations), folded into the audit register per this project's established methodology.

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

## Next bounded action

1. Read `ecosys_ng.zig` around the cited line (~3509) to determine whether `context.radiation_fractions` is actually supplied in the production composition path, or whether the fallback is live today.
2. If live, determine whether the Ottawa deck's actual solar-geometry ever triggers "low-sun" conditions that would exercise this branch (likely: yes, dawn/dusk hours every day).
3. Check the OneDrive reference's `docs/binding_requests/A6_canopy_exposure_hour1_002.md` for an existing fix plan before designing one.
4. This blocks the `FEAT-006` gate and should factor into the project's overall "no science gaps vs. Fortran oracle" success criterion -- do not close this issue by relaxing a check or declaring it out of scope without explicit user sign-off.
