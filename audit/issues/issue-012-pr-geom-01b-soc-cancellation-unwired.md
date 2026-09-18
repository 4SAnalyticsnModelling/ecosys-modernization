# Issue 012 -- PR-GEOM-01B: biological SOC-change input not yet wired into soil-geometry transaction (OPEN, self-declared in-code)

Status: **OPEN.** Found via source-embedded evidence (the project's own in-code tag), not independently re-derived. Given the lesson learned this session on `issue-010`/HOUR1-002 (a stale-comment false alarm), this one was checked for the same possibility before filing -- see "Reachability check" below.

Owner: none currently assigned. Found by this session's audit fork, 2026-09-18.

## What the tag says

`ecosys-ng/src/soil/profile/geometry_disturbance_transaction.zig:112-114`, tag `PR-GEOM-01B`: "Production must not bind the uncancelled hourly SOC difference here." This is inside `state_updateOnce()`, the transactional soil-geometry-boundary update that combines four legacy boundary-shift legs (pond, freeze-thaw, erosion, **organic-carbon**) ported from `f77src/redist.f`'s `DO 245` loop (`:8163-10605`). The organic-carbon leg's real producer (the "biological SOC change," presumably from `grosub.f`/litter decomposition) is explicitly stated as not yet correctly wired.

## Reachability check (learning from the HOUR1-002 false alarm)

Unlike HOUR1-002, this comment sits directly inside the function's own transactional-acceptance logic (`state_updateOnce`), not in an optional/fallback parameter's doc comment describing a *different* call site's behavior. This session did not find a second, correctly-wired call path that bypasses this leg the way `hourly_snow_energy.zig` bypassed `exposure.zig`'s stale fallback -- but this was **not exhaustively checked**; a targeted grep for other callers of the organic-carbon leg specifically (not just this file) was not performed. Treat this as OPEN but **verify reachability before spending fix effort** -- the same false-alarm pattern is plausible here too.

## Scientific/output impact

Not yet assessed. If genuinely unwired, this would mean the soil-layer-boundary geometry transaction (triggered by pond/freeze-thaw/erosion/SOC-driven boundary shifts) either omits the SOC-driven boundary-shift leg entirely, or uses an "uncancelled" (presumably meaning double-counted or not netted against something) value where the intent is a properly cancelled/netted difference. Exact consequence not traced -- would need to read `state_updateOnce`'s actual current implementation for that leg (only the tag comment was read, not the surrounding code in depth) and cross-reference against `redist.f:8163-10605`'s SOC-driven boundary-shift arithmetic (not yet deep-read either, per `feature-010`'s "not covered this pass" list).

## Next bounded action

1. Read `geometry_disturbance_transaction.zig`'s organic-carbon leg implementation in full (not just the tag comment) to determine current actual behavior (is it a placeholder/zero, or a real-but-wrong value?).
2. Grep for other callers/producers of whatever quantity feeds this leg, to rule out the HOUR1-002 pattern (correct value computed and wired elsewhere).
3. If genuinely unwired, trace `redist.f:8163-10605`'s SOC-driven boundary-shift arithmetic to establish the correct producer and cite it before attempting a fix.
4. This is scoped to the soil-geometry-boundary transaction specifically -- does not block other dispositions in `feature-010`.
