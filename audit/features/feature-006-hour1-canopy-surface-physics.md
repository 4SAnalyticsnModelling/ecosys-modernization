# Feature ID: FEAT-006-HOUR1-CANOPY-SURFACE-PHYSICS

Status: PARTIALLY_ASSESSED (first-pass source-audit; `hour1.f` is ~183KB, only ~150-200 lines of dense physics read out of several thousand)

## Scope and provenance

Legacy source: `f77src/hour1.f` (sha256 `BC5F02433C47E31ABFBB04128D2F1C2764029E50AB18B3BD1FF812DA4C2DA859`). Scope of this pass: canopy precipitation retention, ground/water surface roughness selection, canopy zero-plane/roughness/Richardson/boundary-layer resistance, canopy/ground radiation fractions. NOT read this pass: fertilizer application/banding chemistry (~L216-950, ~L4884+), full sunlit/shaded canopy radiative-transfer scattering cascade (~L955-1780, banners only), litter/soil hydraulic-property resets (~L1891-2246, ~L3673-4700).

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
