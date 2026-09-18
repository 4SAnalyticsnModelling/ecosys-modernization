# Feature ID: FEAT-014-EROSION-SEDIMENT-CONSTITUENT-TRANSPORT

Status: PARTIALLY_ASSESSED (source-audit; `erosion.f` is 1,329 lines and was FULLY read this pass -- ~700 lines are a near-verbatim 3x-repeated constituent-partition block)

## Scope and provenance

Legacy source: `f77src/erosion.f` (sha256 `F0F0D67673A21790E05752026C8F47BB67D1FB497C717553042639587E135E2E`), header confirms: detachment and overland transport of surface sediment from rainfall-impact energy and runoff-driven transport, gated on `IERSNG` disturbance-mode flag (`:35-47`, values -1..3).

### 1. Rainfall detachment -- `preserved`

`erosion.f:84-89` (`DETW=DETS*(1+2*VOLWM/VOLA)`; `DETR=min(BKVL*XNPXX, DETW*ENGYPM*AREA*FMPR*FSNX*(1-FVOLIM))`). Zig: `ecosys-ng/src/soil/profile/erosion.zig` (sha256 `A6A2E77516C388103EC6B73D968C3AE7E6B2E92FF2D374A2B5D0F82BA7D43ED7`, `calculateLocalStep:292-295`), functionally identical.

### 2. Deposition from immobile surface water -- `preserved`

`erosion.f:115-127` (`CSEDD=SED/XVOLWM`; `DEPI=max(-SED,VLS*(0-CSEDD)*AREA*FERSNM*FMPR*XNPHX)`). Zig: `erosion.zig:297-300,384-400`. Term-for-term match.

### 3. Runoff detachment/transport-capacity -- `preserved`

`erosion.f:158-177` (`STPR=100*QRV*|SLOPE|`; `CSEDX=PTDSNU*CER*max(0,STPR-0.4)^XER`). Zig: `erosion.zig:302-313,401-434`. Constants (100, 0.4) and functional form preserved. A separate, independently-verified-inert divergence (runtime-texture-derived vs. `HOUR1`-BKDS-ponded `D50/CER/XER/VLS`) is confirmed to never reach a live consumer (`erosion.zig:579-608`, all consumers gated on the same `BKDS>0` predicate) -- correctly traced to the call site, not just asserted; not a gap.

### 4. Downslope transport & lateral partition -- `preserved` (with added hardening)

`erosion.f:202-215,232-301` (`RERSED0=min(SEDX,CSEDE*QRM)`; WE/NS split via `FERM=QRMN/QRM`). Zig: `erosion.zig:270-278`, `erosion/sediment_routing.zig` (sha256 `85B14796CFF705B19810B66F0565F27F4729BFCF239196E645CB02379114AAF6`, `route:58-103`), which additionally validates finiteness/negativity/directional-sum-consistency absent from the Fortran.

### 5. Per-constituent erosion partitioning -- `preserved` as a fraction rule, but see confirmed defect below

`erosion.f:541-765` (and 2 structural repeats through `:1327`): `FSEDER=min(1,XSEDER/BKVLNU)`, `X*ER=FSEDER*pool` for ~60 mineral/fertilizer/exchange/precipitate/organic-matter pools. Zig: `ecosys-ng/src/erosion/eroded_constituents.zig` (sha256 `7FC00DA0105DEC93BA3C6BC1DFDDD005BBFA9E871C78332FBE64F4EF833A36F6`, `calculateFluxes/calculatePackedFluxes/applyFluxes:82-175`), consumed by five live bridges (`soil/profile/erosion_{mineral,fertilizer,chemistry,organic,mineral_fertilizer}_bridge.zig`), wired into production via `ecosys_ng.zig:10360-12437` and `stages/hourly_sediment.zig`.

## Confirmed legacy defect, correctly NOT reproduced, but justified by a FALSE premise -- see `audit/issues/issue-014-erosion-xer-directional-clobber-false-premise.md`

`eroded_constituents.zig:96-106` (tag `EROSION-XER-DIRECTIONAL-CLOBBER-001`) correctly identifies a genuine legacy bug: `erosion.f`'s `DO N=1,2 / DO NN=1,2` loop (`:541-765`) computes east/south-direction constituent transport `X*ER(N,2,...)` when `NN=1`, then the same cell's `ELSE` branch on the next `NN=2` iteration (`:676-763`) **zeroes those same slots** before the loop ends -- a genuine self-clobber that makes east/south-bound eroded-constituent transport permanently zero in the oracle (only west/north, `:766-901`, is live). Independently re-verified line-by-line this session -- the clobber is real.

The Zig comment claims this is "currently inert either way: no production site configuration selects an erosion-enabled disturbance mode" and deliberately applies the transported fraction symmetrically to all four directions instead (`eroded_constituents.zig:107-125`) -- **scientifically defensible**, but **the "inert" premise is FALSE**: the actual production site file `f25si98` (`f77example/.../f25si98` and staged `ecosys-ng-prod-examples/.../landscape/f25si98`, read via `readi.f:154`) has `IETYPG,ISALTG,IERSNG,...` = `33 1 3 1 1.0 0.0` -> **`IERSNG=3`**, which activates every `IF(IERSNG.EQ.1.OR.IERSNG.EQ.3)` branch in `erosion.f` (lines 49,328,476,502,1014). Independently corroborated by a sibling comment in `redistribution/erosion/organic_matter_apply.zig:66-67` confirming the same site-file fact for a different defect (`GEOM-SUBSIDENCE-001`). The `eroded_constituents` path is not dormant -- it is live-wired into the hourly step (`ecosys_ng.zig:10360-12437`, `hourly_sediment.zig:125,140`). The doc files the comment cites as support (`docs/discrepancy_register.md`, `docs/traceability/erosion_unbound_family_disposition.md`) do not exist anywhere in this repository (confirmed by glob).

**Net assessment**: the fix itself (symmetric application, not reproducing an asymmetric self-clobber bug) is very likely the scientifically correct choice -- but it currently rests on a false "this doesn't matter" justification rather than a reviewed defect-correction record. Since production DOES run in `IERSNG=3` mode, this creates a **predictable, real, and currently undocumented divergence from the Fortran oracle's actual output** for eroded-constituent east/south transport -- exactly the kind of thing that must be recorded as an approved intentional difference *before* G3 output comparison, or it will surface as an apparently-unexplained mismatch. **Disposition: `unresolved`** pending a proper `legacy-defect-corrected` review record (the fix looks right; the paperwork/premise does not).

## Secondary observation (not a finding)

`erosion.zig` uses the shared `core/numerics.zig` `newtonPicardFiniteDifference` bounded root-finder in place of the Fortran's explicit `DO 30 M=1,NPH` sub-hour repetition (`erosion.f:31,484`). This is the project's general shared numerical-architecture utility, not something introduced solely for erosion -- flagged for the coordinator to confirm this is consistent with whatever the dedicated nonlinear-solver audit already decided about Newton-Raphson/Anderson vs. Picard usage project-wide, rather than re-litigated here.

## Not covered this pass

The ~700 lines of near-verbatim structural repeats (internal E/S, internal W/N, external-boundary directions) were read but treated as one pattern, not independently re-verified three times.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file coverage). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Four equation groups `preserved`; one confirmed real finding requiring a proper review record before G3 (`issue-014`).
