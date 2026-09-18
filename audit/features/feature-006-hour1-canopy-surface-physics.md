# Feature ID: FEAT-006-HOUR1-CANOPY-SURFACE-PHYSICS

Status: PARTIALLY_ASSESSED (first-pass source-audit; `hour1.f` is ~183KB, only ~150-200 lines of dense physics read out of several thousand)

## Scope and provenance

Legacy source: `f77src/hour1.f` (sha256 `BC5F02433C47E31ABFBB04128D2F1C2764029E50AB18B3BD1FF812DA4C2DA859`). Scope of this pass: canopy precipitation retention, ground/water surface roughness selection, canopy zero-plane/roughness/Richardson/boundary-layer resistance, canopy/ground radiation fractions. NOT read this pass: fertilizer application/banding chemistry (~L216-950, ~L4884+), full sunlit/shaded canopy radiative-transfer scattering cascade (~L955-1780, banners only), litter/soil hydraulic-property resets (~L1891-2246, ~L3673-4700).

## Addendum 2026-09-18 (same session, follow-up pass): fertilizer chemistry section (216-951, ~100% read) and canopy scattering cascade (1050-1289, ~23% sample) -- all clean

### Fertilizer/banding chemistry -- all `preserved`/`legacy-defect-corrected`

1. **Band-geometry volume-fraction redistribution** (`:290-495`) -- application-time reset and pro-rata pool redistribution (distinct from the separate hourly diffusion-driven band-growth routine at `:4888-5155`, correctly NOT conflated). Zig: `ecosys-ng/src/management/fertilizer_band_production.zig` (sha256 `26E273E6E2409DFB6FD7E762C36FB9846E7BBA27B092714DCF9C8ABCC783EAE5`), `consumeUndissolved`/`repartitionConcentrations`/`repartitionExtensivePair` (`:122-267`), conservation verified by the file's own tests. **Disposition: preserved.**
2. **Fertilizer mass-to-mole conversion** (`:522-544,581-589`) -- `/62.0` (Ca(H2PO4)2), `/93.0` (apatite), `/40.0` (calcite/gypsum Ca basis), ground-rock `/92.0/6.0` six-way silicate split. Zig: `ecosys-ng/src/management/mineral_fertilizer_inventory.zig` (sha256 `D293F2E2FFA51D4ECAC497FA1BBAF802521A5F00194B9345FFAAD6582DAD19A9`, `applyEvent:79-103`), identical constants and branch structure, tests use the exact source constants as literal inputs. **Disposition: preserved.**
3. **Urea hydrolysis/nitrification-inhibitor activity reset** (`:907-952`) -- hard reset of `ZNHU0/ZNHUI`/`ZNFN0/ZNFNI` across every soil layer at application. Zig: `ecosys-ng/src/management/fertilizer_nitrogen_inventory.zig` (sha256 `47D5F948126E32395A2519360BAA06720A82D7C14F03A8F14B29188039BFC75E`), `applyEventNitrogen` (`:138-171`), tagged `FERT-002` documenting two prior translation defects (stale non-target-layer values; nitrification-inhibitor never written at all) both now fixed with dedicated regression tests (`:197-233,235-275`). **Disposition: `legacy-defect-corrected`** (closed, verified via live code+tests, not just a comment).
4. **Litter/manure allocation fractions by residue type** (`CFOSC` table, `:648-750`) -- Zig: `ecosys-ng/src/management/organic_fertilizer_material_fractions.zig` (sha256 `68C2E6B20703EB979D29772630336AE146C9B1C76BAC8C3FCB00D5AF459553AA`) reproduces every fraction exactly. Notable: this file documents that HOUR1's own litter-type codebook diverges from the separate `starts.f:847-916` codebook at codes 4/5/8, and deliberately reads HOUR1's own table rather than the STARTS runtime array -- a correctly-resolved cross-file ambiguity, not a bug. **Disposition: preserved.**

### Canopy scattering cascade (partial, 23% sample) -- one more stale-comment false alarm caught

Skimmed `:1050-1289` (top-down diffuse/direct sweep, per-species albedo absorption, sun/sky leaf-angle geometry, recursive diffuse cascade). **Standing-lesson pattern recurred**: `ecosys-ng/src/canopy/radiation/layer_transmission_finalization.zig` carries a long comment history describing an open issue `CANOPY-BURIAL-001` claiming production `interception.zig` "applies no burial gate at all." That same file's own banner says "SUPERSEDED BY BOUND BURIAL-AWARE OWNER" -- verified against live call sites: `ecosys-ng/src/canopy/energy/interception.zig` (sha256 `2BAFFDCD6B60990CE2B32DFE0E33285B871749DA24271516405941B011EC61F2`) implements `BurialInputs`/`layerIsExposed` (`:147-202`) and exposes `*WithBurial` variants, gated correctly and tested (`:709-766`). Production calls the `WithBurial` variants: `stages/hourly_process_driver.zig:462-474`, `stages/hourly_vegetation.zig:824-825`. **Disposition: preserved (already fixed)** -- another instance of stale historical comment text not reflecting current, correct production behavior.

**Not covered**: lines 1290-1780 of the scattering cascade (per-species/per-angle absorption accumulation, ascending backscatter sweep) -- flagged for a follow-up pass, not claimed complete.

### 1. Canopy precipitation retention `FLWC`/`FLWD` -- `hour1.f:1844-1864`

Per-PFT living/standing-dead canopy water storage, bounded by capacity `XVOLWC`, driven by each PFT's radiation-interception share (`FRADP`/`FRADQ`) of hourly precipitation+irrigation.

Zig: `ecosys-ng/src/canopy/energy/precipitation_retention.zig` (sha256 `7D891E59F0666536979F7994C488F8D399D7783BEB4B9D4AE2984A7436082B9F`), `refreshFromModelInternal`/`retentionFlux`, header comment (`:231-239,359-393`) cites `hour1.f:4713-4779,4733-4771`. **Documents an already-fixed prior translation defect**: an earlier version divided each species' absorbed radiation by its own denominator instead of the cell-shared `TRADT`/`ARLSS` total, letting co-occurring species each claim near-100% of a cell's precipitation and fabricate water mass. Fixed via `sharedRadiationInterceptionFraction`, regression tests at `:440-523` (tagged "HOUR1-004-validated single-species case").

**Disposition: `legacy-defect-corrected`** (a real Zig-side translation bug, since fixed and regression-tested).

### 2. Water/snow surface roughness `ZS` -- `hour1.f:2367-2372`

`IF(BKDS(NU).LT.ZERO .OR. VHCPW(1).GT.VHCPWX) THEN ZS=ZSW ELSE ZS=ZSX` -- selects water/snow roughness on zero-density surface OR first-snow-layer heat capacity exceeding an activation threshold; NOT on mere positive snow depth.

Zig: `ecosys-ng/src/surface/aerodynamics.zig` (sha256 `ED1F0702E9DCFBB62540C11068685EAC83F7F473EC8C3CCFD8656C42B4734A4C`), `sourceGroundSurfaceRoughnessHeightM` (`:117-143`), cites `HOUR1 2367--2371 'ZS'`, explicit comment warning a merely-positive snow depth is not the source predicate. Test "HOUR1 ZS uses snow heat capacity and zero-density surface, not snow depth" (`:160`) directly discriminates this.

**Disposition: `preserved`**, with a dedicated regression test guarding against a depth-vs-heat-capacity substitution error.

### 3. Canopy zero-plane displacement/roughness/Richardson/boundary-layer resistance -- `hour1.f:4829-4874`

`ARLSG/ZX/ZY/ZD/ZE/ZZ/ZR/RIBX/RABX` chain; `RIBX=1.27E+08*(ZZ-ZD)/UA**2`, `RABX=(LOG((ZZ-ZD)/ZR))**2/(0.168*UA)`.

Zig: same `aerodynamics.zig`, `applyTile` (`:77-115`), header comment: "HOUR1 `ARLSG/ZX/ZY/ZD/ZE/ZZ/ZR/RIBX/RABX` update." Constants `1.27e8`/`0.168` confirmed bit-for-bit via a unit test that hand-computes expected values to `1e-12` (`:145`). Degenerate `IETYP<0` branch (`RIBX=0,RABX=RABM`) preserved. Fortran's `IFLGW` branch generalized to a boolean parameter; explicit finiteness/positivity input validation added (contract's safety policy, not a physics change).

**Disposition: `preserved`.**

### 4. Canopy/ground radiation fractions `FRADT`/`FRADG`/`FRADP`/`FRADQ` (`ARLSS`) -- `hour1.f:4697-4736`+ -- **REAL OPEN GAP, see `issue-010`**

`ARLSS` sums leaf + stalk + standing-dead area over all layers/branches/PFTs above snow/surface-water depth; `FRADT`/per-PFT `FRADP`/`FRADQ` is the leaf+stalk+dead-area-weighted radiation share.

Zig: `ecosys-ng/src/canopy/radiation/exposure.zig` (sha256 `017DB476283496C22219525141D92268090B2E48DF9D979A452E09D1ADDA1D99`), `applyTile`/`radiation_fractions` (`:59-113`). Header comment claims this is HOUR1-002/open (a leaf-area-only fallback), but **this claim is stale documentation, not current behavior**: the actual (and only) call site, `stages/hourly_snow_energy.zig:393-415` inside `solveSnowSurfaceEnergyAndSoilTransport` (confirmed live-production-called from `stages/hourly_process_driver.zig`), unconditionally passes the ARLSS-faithful `radiation_fractions` whenever `canopy_precipitation_retention` state exists -- which it does for any deck with plants, including the Ottawa production deck. The null-fractions fallback is not reachable in practice for a plant-bearing deck.

**Disposition: `preserved`** (corrected same session from an initial `unresolved` filing -- see `audit/issues/issue-010-hour1-002-canopy-radiation-fraction-fallback.md` for the full correction trail). Non-blocking follow-up: `exposure.zig`'s stale header comment should be updated so it stops claiming HOUR1-002 is open.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (first-pass, explicitly scoped). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Three items `preserved`, one `legacy-defect-corrected`. No confirmed open science gap in this dossier as of the correction above (the initial finding was a documentation false alarm, caught and corrected same session).
