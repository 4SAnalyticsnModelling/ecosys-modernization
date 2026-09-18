# Issue 012 -- PR-GEOM-01B / GEOM-SUBSIDENCE-001: uncancelled SOC-change input, currently latent (CONFIRMED OPEN, self-declared in-code)

Status: **OPEN.** Found via source-embedded evidence (the project's own in-code tag), not independently re-derived. Given the lesson learned this session on `issue-010`/HOUR1-002 (a stale-comment false alarm), this one was checked for the same possibility before filing -- see "Reachability check" below.

Owner: none currently assigned. Found by this session's audit fork, 2026-09-18.

## What the tag says

`ecosys-ng/src/soil/profile/geometry_disturbance_transaction.zig:112-114`, tag `PR-GEOM-01B`: "Production must not bind the uncancelled hourly SOC difference here." This is inside `state_updateOnce()`, the transactional soil-geometry-boundary update that combines four legacy boundary-shift legs (pond, freeze-thaw, erosion, **organic-carbon**) ported from `f77src/redist.f`'s `DO 245` loop (`:8163-10605`). The organic-carbon leg's real producer (the "biological SOC change," presumably from `grosub.f`/litter decomposition) is explicitly stated as not yet correctly wired.

## Resolved (2026-09-18, same session): CONFIRMED real and open, but currently LATENT -- registered elsewhere as `GEOM-SUBSIDENCE-001`

Checked for the HOUR1-002/SOLUTE-042 false-alarm pattern first, per this session's standing lesson. This one does NOT resolve that way -- it is genuinely open, and turns out to already have a much more thorough writeup elsewhere in the tree than the `PR-GEOM-01B` tag alone suggested.

**Full mechanism, traced end to end:**
1. `ecosys-ng/src/redistribution/erosion/organic_matter_apply.zig:1-55` (header comment) is an exceptionally thorough self-audit already in the codebase, registering this as **`GEOM-SUBSIDENCE-001`** (cross-referenced to `docs/traceability/geometry_subsidence_erosion_and_soc_datum_legs_are_dead.md` -- not present in this `D:` checkout, consistent with issue-005's established missing-`docs/` pattern; check the OneDrive reference for it before re-deriving).
2. Legacy policy (verified by that comment against `redist.f:6871-6873,6870`): `DORGC(L)=ORGCX(L)-ORGC(L)-ORGCC(L)`, with `+DORGE` added for the surface layer only, inside `IF(IERSNG.EQ.2.OR.IERSNG.EQ.3)`. Since `ORGCX` is the pre-change snapshot, this addition **cancels eroded (sediment-transported) carbon out of the subsidence driver** -- only biologically-driven carbon change may move a layer boundary; sediment-transported carbon is already accounted for by the erosion datum shift.
3. Production's actual publisher, `soil/organic/carbon_change.zig`'s `publishAcceptedHourlyChange`, forms a **plain hour-start-minus-current difference with no `+DORGE` term at all** -- i.e. the value that reaches `hourly_geometry_disturbance.zig:302`'s `context.soil_organic_carbon_change_g_c_per_h`, and from there `geometry_disturbance_transaction.zig`'s `organic_carbon_change_after_erosion_cancellation_g_c` field, is genuinely the **uncancelled** difference the field's own name and comment warn against -- confirmed by reading the actual call chain (`ecosys_ng.zig:9585,9677-9682,12282,13748` -> `hourly_geometry_disturbance.zig:191,302`), not just the comment.
4. **Why this is not observable today**: `soil/profile/relayering.zig:73-75` allocates the workspace's `organic_carbon` (SOC boundary-change) buffer and `@memset`s it to zero, and (per `organic_matter_apply.zig:38-39`'s own claim, consistent with what I read) it is never subsequently overwritten with the real per-hour value in production -- i.e. a *separate*, independent hard-wired-zero currently overrides whatever the uncancelled/miscancelled value would have been, before it can move a layer boundary. The bug is real and wired-in, but its effect is currently masked by an unrelated zero-override downstream.

**This is the opposite failure mode from HOUR1-002/SOLUTE-042**: those were cases where a stale comment claimed a bug that the actual (correct) production code had already fixed. This is a case where the code comment's warning is accurate and the bug is real, but a *different* zero-override happens to prevent it from causing observable divergence *today*. **It would become a live, observable defect the moment anyone wires the SOC/erosion boundary-datum legs to a real nonzero value without also porting the `+DORGE` cancellation.**

**Disposition: `unresolved`, confirmed OPEN.** Genuinely blocks nothing today (latent), but is exactly the kind of "trap for the next reader" the in-code comment itself warns about, and is relevant to "no science gaps" as a known, documented, currently-inert defect that must be fixed together with whoever eventually wires the SOC/erosion legs -- not fixed in isolation (the comment explicitly warns `DORGE` must be re-derived together with its reset in `redistribution/ecosystem/call_initialization.zig`, not lifted from either file alone).

## Next bounded action

1. Do not attempt a fix now -- there is nothing to fix yet in the sense of "wrong output," since the consuming legs are inert. Fixing the cancellation in isolation without also wiring the consuming legs (per the comment's own warning) risks introducing a *worse*, harder-to-find defect.
2. When `soil/profile/relayering.zig`'s SOC/erosion-datum legs are eventually wired to a real (nonzero) value by whoever owns that work, `+DORGE` cancellation must be ported in the same change, re-deriving `DORGE` together with its reset in `redistribution/ecosystem/call_initialization.zig`.
3. Check the OneDrive reference's `docs/traceability/geometry_subsidence_erosion_and_soc_datum_legs_are_dead.md` for any additional detail before that work begins.
4. Scoped to the soil-geometry-boundary transaction's SOC leg specifically -- does not block other dispositions in `feature-010`, and does not block the current production frontier since the leg is inert.
