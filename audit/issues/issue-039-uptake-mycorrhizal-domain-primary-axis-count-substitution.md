# Issue 039 -- UPTAKE.F always substitutes the root domain's (N=1) primary-axis count/depth for BOTH root and mycorrhizal domains; Zig's `refreshRootWorkspace` uses each domain's own, independently-grown copy instead (undocumented deviation, mycorrhizal-domain-only)

Status: **OPEN, needs a coordinator materiality/scope decision.**

Owner: found by this session's audit fork, 2026-09-19, auditing the canopy-energy-balance body assignment (`f77src/uptake.f:400-1090`), while re-verifying the already-`preserved`-flagged root-hydraulic-resistance network (`:665-775`) against its Zig counterpart.

## What was found (Fortran side)

`uptake.f`'s root/mycorrhizal domain loop runs `DO N=1,MY(NZ,NY,NX)` (N=1 is the root, N=2 is the mycorrhizal domain when `MY=2`; comment at `:680`, `N:1=root,2=mycorrhizae`). Three places in the canopy-energy-balance/root-uptake body read the **primary root axis count or primary root depth by a literal index of `1`, never by the loop variable `N`**, so both domains' calculations are driven by the root domain's own value even while N=2 (mycorrhiza) is being processed:

- `:497-500`: `RTDPZ=AMAX1(RTDPZ,RTDP1(1,NR,NZ,NY,NX))` -- primary root depth always read from domain 1.
- `:687`: the `ILYR` (rooted/not-rooted) gate includes `RTN1(1,L,NZ,NY,NX).GT.ZEROP(NZ,NY,NX)` -- always domain 1, regardless of which N is being gated.
- `:738,740`: `RSR1(N,L)=(RSRA(N,NZ,NY,NX)*DPTHZ(L,NY,NX)/(FRAD1*RTN1(1,L,NZ,NY,NX)/PP(...))+RSRA(1,NZ,NY,NX)*HTSTZ(...)/(FRADW*RTN1(1,L,NZ,NY,NX)/PP(...)))` -- axial-resistance denominator (both terms) always divides by domain 1's axis count, even for N=2's own resistance value `RSR1(2,L)`.

This is not an accident: `grosub.f:6438-6445` grows `RTN1` only `IF(N.EQ.1)THEN ... RTN1(N,L,NZ,NY,NX)=RTN1(N,L,NZ,NY,NX)+XRTN1 ... ENDIF` -- **`RTN1(2,...)` (the mycorrhizal domain's own copy) is never incremented after its initial seeding value; it is dead/frozen state.** `uptake.f` therefore has no choice but to always substitute domain 1's actively-tracked axis count/depth wherever a primary-axis quantity is needed for either domain -- reading `RTN1(2,...)` would silently use a stale, never-updated number. `startq.f:402-403` shows the same domain-sharing pattern applied to the *resistivity constants* themselves (`RSRR(2,...)=RSRR(1,...)`; `RSRA(2,...)=RSRA(1,...)` at initialization), confirming the domains are intentionally treated as sharing one physical primary-axis pathway, not two independent ones.

## What Zig does

`ecosys-ng/src/plant/root/water_balance.zig`, `refreshRootWorkspace` (`:220-349`), loops `for (0..biological_domain_count_by_plant[plant]) |domain|` (`:275`) and, for **each** domain, calls `roots.refreshLayerMorphologySourceOrder(plant, domain, layer, ...)` (`:293`) to get that domain's **own** `topology.primary_axis_count`, then uses it directly, per domain, in three places mirroring the three Fortran sites above:

- `:279-287`: `deepest_primary_root_m` is computed from `roots.axis_primary_count[layerAxisIndex(plant, domain, layer, axis)]` -- this domain's own axis presence, not domain 0's.
- `:296`: the layer-active gate includes `topology.primary_axis_count <= 0` -- this domain's own count.
- `:334`: `.primary_axis_count_per_plant = topology.primary_axis_count / population`, fed into `hydraulicResistance`'s `primary_axial` term (`:531`) -- this domain's own count, for both the below-ground and stalk-relative sub-terms.

Crucially, unlike Fortran, Zig's `axis_primary_count` **is actively grown for every domain**, not just domain 0: `stages/root_processes_metabolism.zig:223` loops `for (0..traits.biologicalDomainCount()) |domain| { ... }` with no `domain==0` restriction, and inside that loop `plant/root/plant_root_metabolism_state_update.zig:536` unconditionally sets `roots.axis_primary_count[axis_layer] = parameters.primary_axis_count_multiplier;` whenever `workspace.secondary_active[axis]` is true, for whichever `domain` is currently being iterated. So for a species with `mycorrhizal_type==2` (`biologicalDomainCount()==2`), Zig's domain-1 (mycorrhizal) `axis_primary_count` is a live, independently-evolving quantity -- not a frozen copy of domain 0's initial value, and not forced equal to domain 0's current value either.

The resistivity constants (`root_axial_resistivity_mpa_h_per_m2`, `root_radial_resistivity_mpa_h_per_m3`) are, correctly, stored **once per plant** (`water_balance.zig:118,326,331`, indexed `[plant]` not `[plant,domain]`) -- this matches `startq.f:402-403`'s domain-sharing of `RSRA`/`RSRR` and is *not* part of this defect.

## Why this needs a record

For the root domain itself (domain 0 / N=1) there is no divergence: both models always read domain 0's own value. The divergence is confined to the **mycorrhizal domain's** (domain 1 / N=2) rooting-depth term, `ILYR`-equivalent gate, and axial-resistance denominator: Fortran always substitutes the root's own actively-tracked axis count/depth for this domain too (by design, per the `grosub.f:6438` growth gate), while Zig computes and uses the mycorrhizal domain's own, independently-grown axis count/depth. Whenever a plant's mycorrhizal-domain primary-axis growth diverges numerically from its root-domain primary-axis growth over a simulation (both are driven by the same shared `primary_axis_count_multiplier` per hour, but accumulate into separate per-domain, per-axis-layer state that can be reset/scaled independently by senescence, disturbance, and layer-crossing bookkeeping elsewhere in the root lifecycle), the mycorrhizal domain's water-uptake resistance network (and its active/inactive layer gating) will disagree with the legacy formula.

This is an undocumented physics deviation in a faithfully-translated-looking function, in the same general family as this session's other domain-substitution findings (`issue-036`), but here the mechanism is "each side reads its own domain's copy of a quantity the source deliberately always reads from one fixed domain" rather than a stale-carryover read.

## Materiality (not resolved this pass)

Static analysis only. Not checked this pass:
- Whether any species/PFT file used by the current v1.0.0-scope example deck(s) (`ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON`) actually sets `mycorrhizal_type=2`. If no in-scope PFT enables mycorrhizae, this defect is real but currently dormant for v1.0.0's validated scope (still counts in the audit denominator per `PROJECT_CONTRACT.md`'s "dormant branches remain inventoried" rule).
- The actual magnitude of root-domain-vs-mycorrhizal-domain primary-axis-count divergence over a growing season, if mycorrhizae are enabled anywhere in scope.
- Whether `plant_root_gas_exchange.zig` / `plant_root_nutrient_uptake.zig` (siblings consuming the same root-geometry primitives for gas exchange and nutrient uptake, per `feature-004`'s existing audit) have the identical domain-substitution pattern; not traced this pass.

## Disposition

`unresolved`. Needs a coordinator decision: (a) confirm no in-scope PFT uses `mycorrhizal_type==2`, in which case this stays a dormant-but-inventoried gap; (b) fix `refreshRootWorkspace` to substitute domain 0's `primary_axis_count`/rooting depth for every domain's axial-resistance and gating terms, matching source exactly; or (c) obtain explicit scope approval to treat independent mycorrhizal-domain axis growth as a deliberate, reviewed improvement (would need its own feature-register entry, since it currently has none).

## Evidence

`D:\ecosys-modernization\f77src\uptake.f:497-500,680,687,736-743` (sha256 `D60132510BB9AB8DD79D62D3770F8BFB9A1984D7C480E388D3F33FE4D8281B2B`); `D:\ecosys-modernization\f77src\grosub.f:6438-6445` (sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`); `D:\ecosys-modernization\f77src\startq.f:402-403` (sha256 `F117240373D88D95D8204AC8241A4F8DD30BA3B6F864E7BFB5581080E0532CCB`); `D:\ecosys-modernization\ecosys-ng\src\plant\root\water_balance.zig:220-349,531` (sha256 `D324AE80966B1F02D629AB102981A3EBDF4812EEA3CF59A92AF20A14D8F65405`); `D:\ecosys-modernization\ecosys-ng\src\stages\root_processes_metabolism.zig:223` (sha256 `AE91A24A5A86697C2DFEBC7C686398BFBC1348BB29D68B110554999391421C20`); `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_metabolism_state_update.zig:530-538` (sha256 `EA396A021C4E6E4ABA9AE7BDFF5E2F1B532603B97BB85878CBFCFEDC8C9E8406`); `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_metabolism_growth.zig:177-179` (`biologicalDomainCount`, sha256 `DAEACE7CA6C7AE5315CF667242338B00CD5144563093A99A2C189810D8CFA302`).
