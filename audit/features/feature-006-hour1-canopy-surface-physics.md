# Feature ID: FEAT-006-HOUR1-CANOPY-SURFACE-PHYSICS

Status: PARTIALLY_ASSESSED (fifth pass this session closes out the file's last
named gap, `:2489-3673`; cumulative statement-level coverage of executable
code is now essentially 100% of the file's 5,204 lines -- see "Coverage and
closing summary" below for the final tally. Independent review still not
done for any pass, so this remains PARTIALLY_ASSESSED/NOT_ASSESSED for gate
purposes per the contract, not a release decision)

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

**Disposition revised 2026-09-19 (this pass): `unresolved`** (was `preserved`).
The branch formula/constants remain bit-for-bit correct (that part of the
original finding stands, backed by the existing regression test). What this
pass found and the prior pass missed: this entire `ZS` assignment is nested
inside `IF(IFLGS(NY,NX).NE.0)THEN...ENDIF` (`hour1.f:1900-2388`), and
`IFLGS` is set nonzero only at simulation start (`starts.f:388`), on an
active erosion/redistribution event (`redist.f`/`redist_utf8.f:8524,11056,
11428`), or on checkpoint restart (`routs.f:44`) -- never on ordinary
within-season snow accumulation/melt. Legacy's `ZS` is therefore "sticky"
between those rare events; Zig's `ecosys.surface_aerodynamics
.sourceGroundSurfaceRoughnessHeightM` is instead called unconditionally
every hour from live snow-heat-capacity/bulk-density state
(`stages/hourly_process_driver.zig:408-417`, confirmed by direct reading, no
disturbance-equivalent gate present). This is a genuine update-frequency
divergence with a plausible path into the canopy/surface energy-balance
chain (`ZS` feeds `feature-006` item 3's `ZE`/`ZR` and `watsub.f:825`). Full
write-up, evidence and suggested resolution paths: `audit/issues/issue-052
-hour1-zs-surface-roughness-update-frequency-gated-by-disturbance-flag.md`.
Requires reviewer/coordinator scientific judgment (approved-improvement vs.
translation defect), not something this pass can close unilaterally.

### 3. Canopy zero-plane displacement/roughness/Richardson/boundary-layer resistance -- `hour1.f:4829-4874`

`ARLSG/ZX/ZY/ZD/ZE/ZZ/ZR/RIBX/RABX` chain; `RIBX=1.27E+08*(ZZ-ZD)/UA**2`, `RABX=(LOG((ZZ-ZD)/ZR))**2/(0.168*UA)`.

Zig: same `aerodynamics.zig`, `applyTile` (`:77-115`), header comment: "HOUR1 `ARLSG/ZX/ZY/ZD/ZE/ZZ/ZR/RIBX/RABX` update." Constants `1.27e8`/`0.168` confirmed bit-for-bit via a unit test that hand-computes expected values to `1e-12` (`:145`). Degenerate `IETYP<0` branch (`RIBX=0,RABX=RABM`) preserved. Fortran's `IFLGW` branch generalized to a boolean parameter; explicit finiteness/positivity input validation added (contract's safety policy, not a physics change).

**Disposition: `preserved`.**

### 4. Canopy/ground radiation fractions `FRADT`/`FRADG`/`FRADP`/`FRADQ` (`ARLSS`) -- `hour1.f:4697-4736`+ -- **REAL OPEN GAP, see `issue-010`**

`ARLSS` sums leaf + stalk + standing-dead area over all layers/branches/PFTs above snow/surface-water depth; `FRADT`/per-PFT `FRADP`/`FRADQ` is the leaf+stalk+dead-area-weighted radiation share.

Zig: `ecosys-ng/src/canopy/radiation/exposure.zig` (sha256 `017DB476283496C22219525141D92268090B2E48DF9D979A452E09D1ADDA1D99`), `applyTile`/`radiation_fractions` (`:59-113`). Header comment claims this is HOUR1-002/open (a leaf-area-only fallback), but **this claim is stale documentation, not current behavior**: the actual (and only) call site, `stages/hourly_snow_energy.zig:393-415` inside `solveSnowSurfaceEnergyAndSoilTransport` (confirmed live-production-called from `stages/hourly_process_driver.zig`), unconditionally passes the ARLSS-faithful `radiation_fractions` whenever `canopy_precipitation_retention` state exists -- which it does for any deck with plants, including the Ottawa production deck. The null-fractions fallback is not reachable in practice for a plant-bearing deck.

**Disposition: `preserved`** (corrected same session from an initial `unresolved` filing -- see `audit/issues/issue-010-hour1-002-canopy-radiation-fraction-fallback.md` for the full correction trail). Non-blocking follow-up: `exposure.zig`'s stale header comment should be updated so it stops claiming HOUR1-002 is open.

## Addendum 2026-09-19 (third pass, this session): full-file structural sweep plus statement-level read of the canopy scattering cascade, disturbance-gated litter/soil property resets, and fertilizer band-geometry-growth triple; one significant new finding (`issue-052`, above)

**Scope of this pass.** Read-only, static-analysis-only per this task's
constraint (no `zig build`, no execution). First did a full-file (1-5,204)
banner/comment-header sweep of every section (see "Structural map" below),
then read the following ranges at full statement level:

- `:955-1789` -- the multilayer canopy direct/diffuse SW+PAR radiative
  transfer cascade (sunlit/shaded leaf surfaces, leaf/stalk/standing-dead
  triples, backscatter/forward-scatter, ground-surface reflection, canopy
  layer height rebalancing). Previously only 23% sampled (`:1050-1289`); now
  **100% read** for `:955-1789`, closing out the "Not covered" range from the
  2026-09-18 addendum (`:1290-1780`).
- `:1891-2388` -- disturbance-gated (`IFLGS.NE.0`) surface-litter and soil
  physical/hydraulic property resets (bulk density, field capacity/wilting
  point defaults, hydraulic conductivity function from Ksat and water
  release curve, macropore dimensions, the `ZS` branch discussed in item 2's
  revision above, ponded-water storage capacity). Previously flagged "NOT
  read"; now fully read. This is the disturbance/init-only counterpart to
  the every-hour soil physical-property recompute at `:3660-3739`+ (see
  "Not covered" below -- only sampled, not fully read, this pass).
- `:2434-2487` -- canopy/precipitation/irrigation gas-concentration unit
  conversions (CO2/CH4/O2/N2/N2O/NH3/H2, canopy air vs. precipitation
  vs. irrigation). Clean, straightforward unit-conversion algebra, no branch
  asymmetry found.
- `:4713-4780` -- independently re-read `FRADT`/`FRADG`/`FRADP`/`FRADQ`/
  `FLAIP`/`FLAIQ` (item 4's `ARLSS`-based radiation-fraction chain, including
  the three-branch `SSIN>0.05` / `ARLSS>0`/ neither structure feeding
  `FRADT`/`FRADG`). Confirms the existing item 4 finding; no new issue.
- `:4884-5200` -- the hourly diffusion-driven fertilizer-band-geometry-growth
  routine (NH4/NO3/PO4 band width/depth/volume-fraction evolution and
  amalgamate-on-band-loss reset), explicitly distinguished in this dossier's
  item 1 from the separate application-time banding chemistry already
  covered. **Now read in full.** Clean three-way parallel (`N` parallel
  blocks, one outlier` check): NH4 and NO3 blocks are structurally identical
  under variable substitution; PO4's block has additional adsorbed/
  precipitated-species bookkeeping (`H1PO4`/`H2PO4`/`XOH*`/`PALPO`/`PFEPO`/
  `PCAP*`, conditional `ISALTG` salt-chemistry pools) which is genuine P-chemistry
  complexity (P has precipitation/sorption reactions N does not), not a
  translation asymmetry. No outlier found in this triple.

**One notable non-finding worth recording so a future pass doesn't re-flag
it:** the canopy layer's forward-scatter accumulator `RAFSL`/`RAFPL`
(`:1560-1563`) adds a `RADST*TAUR(NZ,NY,NX)` transmittance term for the
**leaf** component only -- no analogous `*TAUW`/`*TAUD` term exists for
stalk/standing-dead. Verified this is **not** an "N parallel blocks, one
outlier" bug: `readq.f:116-120,247-252` shows `TAUR`/`TAUP` (leaf SW/PAR
transmission) are read from input and used to derive `ABSR=1-ALBR-TAUR`,
while `hour1.f:116-117`'s `PARAMETER` statement defines stalk/standing-dead
absorptivity as `ABSRW=1.0-ALBRW`/`ABSRD=1.0-ALBRD` with **no transmittance
term at all** -- legacy's own physics treats stalks and standing dead as
fully opaque (reflect-or-absorb only), and only leaves transmit light. The
Zig counterpart should be checked for the same asymmetry (not done this
pass -- see "Not covered" below), but the legacy asymmetry itself is
confirmed intentional, not a defect.

**One significant new finding this pass**: see the revision to item 2 above
and `audit/issues/issue-052-hour1-zs-surface-roughness-update-frequency
-gated-by-disturbance-flag.md` in full. Filed `unresolved`.

**Zig counterparts found for this pass's ranges** (not written this pass):
- Canopy scattering cascade: the existing `feature-006` addendum's citations
  (`layer_transmission_finalization.zig`, `interception.zig`) plus
  `ecosys-ng/src/canopy/radiation/exposure.zig` for the `FRADT` chain --
  already covered by items 1-4 above, re-verified not re-derived from
  scratch for the parts already covered.
- Fertilizer band-geometry growth: `ecosys-ng/src/management
  /hourly_fertilizer_band_geometry.zig` (sha256
  `7136099BC70B0E65076E52F4D7B216822AB4A89B5E05A4A9027223C623AC644F`),
  self-citing header "Traceability: HOUR1 (`hour1.f`) lines 4888-5151"
  (`:87-90`). Not independently re-derived term-by-term this pass (found and
  cited, disposition left as a follow-up -- see below).
- Disturbance-gated litter/soil property resets (`:1891-2388`): no
  counterpart search performed this pass (structural read only; a Zig-side
  search for the disturbance-triggered soil physical-property reset path is
  a follow-up item).

**Disposition for this pass's newly-read ranges** (pending independent
review, consistent with the dossier's existing NOT_ASSESSED gate status):
- `:955-1789` canopy scattering cascade: `preserved` (no new defect found;
  the `TAUR`-only transmittance asymmetry is confirmed intentional legacy
  physics, not a bug).
- `:1891-2388` disturbance-gated property resets: not yet disposed --
  read at statement level but Zig counterpart not searched this pass.
- `:2434-2487` gas-concentration conversions: `preserved` (Zig counterpart
  not searched this pass; formula itself is simple unit algebra, low risk).
- `:4884-5200` fertilizer band-geometry growth: `preserved` (Zig counterpart
  found and cited above; not independently re-derived term-by-term).
- Item 2 `ZS`: `unresolved` (revised, see above and `issue-052`).

## Structural map (full-file banner sweep, this pass)

Approximate section boundaries from the comment-header sweep (all 5,204
lines scanned for section-introducing comments; line numbers are the comment
header, not necessarily the first executable statement):

| Range | Content | This pass's statement-level status |
|---|---|---|
| `:1-155` | Header, `include`s, dimension/PARAMETER declarations, gas diffusivity/solubility/activity constants | Declarations only, not "read" as physics |
| `:156-215` | Outer `DO NX/DO NY` grid-cell loop start | mapped only |
| `:216-951` | Fertilizer application/banding chemistry | Read in full, 2026-09-18 pass (see above addendum) |
| `:955-1789` | Canopy multilayer direct/diffuse SW+PAR radiative transfer cascade | **Read in full, this pass** |
| `:1789-1829` | Canopy layer height rebalancing (equal-LAI division) | Read in full, this pass |
| `:1829-1878` | Canopy precipitation retention `FLWC`/`FLWD` | Read in full, 2026-09-18 pass (item 1) |
| `:1891-2388` | Disturbance-gated (`IFLGS`) litter/soil physical/hydraulic property resets, incl. `ZS` (item 2) | **Read in full, this pass** |
| `:2390-2433` | Per-subhourly-cycle accumulator resets | mapped only (mechanical zeroing) |
| `:2434-2487` | Canopy/precipitation/irrigation gas-concentration conversions | **Read in full, this pass** |
| `:2489-2913` | "RESET FLUX ARRAYS USED IN OTHER SUBROUTINES" -- water/snow/solute/erosion/gas/band/macropore flux-array zeroing (matches the subroutine's own docstring: "REINITIALIZES HOURLY VARIABLES USED IN OTHER SUBROUTINES") | Sampled (`:2489-2660`) and characterized as mechanical zero-initialization, not dense physics; **not read line-by-line in full** |
| `:2913-3221` | Surface roughness parameters for runoff (`ZM`, particle-size effects) | mapped only |
| `:3221-3673` | Microbial residue/SOC pool array handling | mapped only |
| `:3660-3739`+ | Every-hour (not disturbance-gated) soil physical/thermal property recompute: bulk density->porosity, `VHCM`/`STC`/`DTC` heat capacity/thermal conductivity from SOC+texture, charcoal effects on FC/WP/CEC/AEC, `EHUM` | **Sampled** (`:3660-3739`), not fully read; flagged as a high-value follow-up target (feeds `watsub.f` soil thermal conductivity every hour, unlike the disturbance-gated `:1891-2388` analog) |
| `:3739-4679` | Continues soil property recompute, litter ion concentration/EC, litter osmotic/gravimetric/matric water potentials, litter NH4/NH3/NO3/NO2/HPO4/H2PO4 concentrations, litter gas concentrations, gaseous/aqueous diffusivity in litter | mapped only (banner sweep), **not read this pass** |
| `:4679-4696` | Vapor diffusivity in air/litter/snowpack for `watsub.f` vapor-flux calculations | Read (short, 18 lines) |
| `:4697-4780` | `ARLSS`/`FRADT`/`FRADG`/`FRADP`/`FRADQ`/`FLAIP`/`FLAIQ` canopy/ground radiation fractions (item 4) | Re-read in full, this pass (confirms prior finding) |
| `:4781-4884` | Canopy air temperature/vapor pressure aggregation; canopy zero-plane/roughness/Richardson/boundary-layer resistance (items 3 and the `TKCT`/`TKQT`/`VPQT` aggregation) | Read in full, 2026-09-18 pass (item 3); `TKCT`/`TKQT`/`VPQT` aggregation lines specifically re-read this pass |
| `:4884-5200` | Hourly fertilizer NH4/NO3/PO4 band width/depth/volume-fraction growth and amalgamate-on-loss reset | **Read in full, this pass** |
| `:5200-5204` | `RETURN`/`END` | n/a |

## Addendum 2026-09-19 (fourth pass, this session): full statement-level read of `:3660-4679`, the every-hour soil/litter thermal-property and water-potential recompute -- this dossier's own previously-flagged top-priority gap

**Scope of this pass.** Read-only, static-analysis-only per this task's
constraint (no `zig build`, no execution, no runs). Read `hour1.f:3660-4679`
(1,020 lines) in full at statement level -- the range the third pass's "Not
covered" section flagged as "**Recommended top priority for the next
pass**" because it is the every-hour (non-disturbance-gated) counterpart to
the disturbance-gated `:1891-2388` litter/soil property resets, and because
it directly feeds `watsub.f`'s soil thermal conductivity and (via `PSISM`/
`PSISO`) freezing-point calculations. Also read `audit/issues/issue-024`'s
current state first per this pass's brief, without reopening its paused
rounds 1-4 diagnosis loop.

**What this range covers, confirmed by direct read:**
- `:3660-3672` -- per-layer sand/silt/clay concentration finalization
  (`CSAND`/`CSILT`/`CCLAY`), specific-surface-area `SSA` when `ISALTG.NE.0`.
- `:3673-3739` -- soil solid-phase heat-capacity/thermal-conductivity
  formulation from SOC+texture (`VORGC`/`VMINL`/`VSAND`, `STC`/`DTC`,
  `POROS`), charcoal FC/WP/CEC/AEC increment, `EHUM` humus-allocation
  fraction. Legacy's own `VHCM` line here (`:3697-3698`) is commented-out
  dead code (VHCM is actually owned by `starts.f`); confirmed this is
  already correctly understood on the Zig side (`soil/heat/solver_residual.zig:398-407`
  explains the same fact independently).
- `:3754-3892` -- soil gaseous (`CO2G..H2GG`, 7-way parallel) and aqueous
  (`CO2S..H2GS`, 6-way parallel) concentrations from mass/volume; NH4/NH3/
  NO3/NO2/HPO4/H2PO4/total-P concentrations in non-band and band zones
  (fully parallel non-band/band pair, each internally consistent).
- `:3894-4000` -- previous-timestep substrate-uptake carryover reset
  (mechanical); gaseous/aqueous diffusivity temperature scaling (`TFACG`/
  `TFACL`) for every tracked gas/solute, `ISALTG`-conditional salt-species
  extension.
- `:4001-4078` -- total soil ion strength/activity coefficients/electrical
  conductivity (`CSTR`/`CION`/`A1`/`A2`/`A3`/`ECND`), extended Debye-Huckel
  law over three charge classes -- **see new finding below, `issue-053`.**
- `:4080-4106` -- Ostwald solubility coefficients (CO2/CH4/O2/N2/N2O/NH3/H2)
  temperature- and ionic-strength-adjusted.
- `:4107-4170` -- three-branch log-log matric water potential `PSISM` for
  soil layers (below-wilting / field-capacity-to-wilting / near-saturation
  branches), plus a fourth branch for the zero-bulk-density/ice-only case.
- `:4171-4195` -- osmotic/gravimetric/total water potential (`PSISO`/
  `PSISH`/`PSIST`).
- `:4197-4326` -- root-penetration resistance `RSCS` (entirely commented
  out in legacy itself -- dead code, hard-set to `0.0`, "NOT CURRENTLY
  USED"); hydraulic conductivity `CNDU`; active-layer depth `DPTHA`; water-
  table depth `DPTHT`.
- `:4329-4562` -- the dedicated surface-litter (layer 0) physical/water/ion
  block: volume/porosity/water-content geometry from `RC0`/`BKRS`, then a
  three-way branch for litter matric/osmotic/total water potential and ion
  activity (litter present+wet / litter present+dry, falling back to the
  top soil layer's `PSISM`/`PSISO`/`PSISH`/`PSIST` / no litter volume at
  all, same fallback) -- verified complete, no missing `ELSE`, no
  stale-state gap.
- `:4564-4649` -- litter gas concentrations, litter gas solubility, litter
  aqueous concentrations, litter gaseous/aqueous diffusivity (parallel
  structure to the soil-layer version above, confirmed).
- `:4651-4679` -- litter substrate-uptake carryover reset (mechanical,
  parallel to `:3894-3932`'s soil version); start of the vapor-diffusivity
  section (already read/disposed by the third pass).

**N-parallel-blocks / one-outlier check, this pass's specific focus:**
- Soil-layer PSISM (`:4127-4170`) vs. litter-layer PSISM (`:4386-4400`):
  structurally parallel three/four-branch log-log forms, correctly using
  each layer's own `THETW`/`THETWR`. No asymmetry found in the *branch
  structure* itself.
- **Confirmed, by independent re-derivation, the pre-existing open
  `SOIL-THETY-001` finding** (found by a prior pass, not new this pass):
  the below-wilting-point branch (`HCN=0.50` log-log extrapolation) is
  applied identically to soil layers (`:4131-4134`) and litter (`:4386-
  4389`) in legacy, but production is asymmetric -- litter
  (`surface/litter_geometry.zig:35`) keeps the legacy extrapolation while
  soil layers (`soil/water/retention.zig:680`) invert their own Mualem-
  van-Genuchten curve instead. This pass's direct statement-level read of
  both `hour1.f` branches independently corroborates the finding's premise
  (the two legacy branches genuinely are identical in form); does not
  newly resolve it.
- Gas concentration blocks (7-way gaseous, 6-way aqueous, NH4/NO3/PO4 non-
  band vs. band pairs): all internally parallel and complete, no missing
  member found in either soil-layer or litter-layer versions.
- Litter's three-way PSISM fallback branch (wet / dry-with-fallback / no-
  litter-with-fallback): verified complete against the soil-layer
  analog's own `ELSE` (`:4168-4170`) -- no outlier.

**One significant new finding this pass:** the legacy `CION`/`CSTR`
extended-Debye-Huckel computation (`:4001-4078`), which is PSISO's sole
input and therefore directly upstream of `issue-024`'s still-open "matric-
plus-osmotic potential" candidate, has two structurally different Zig
implementations -- a never-production-bound, byte-for-byte source-order
translation kept as a test oracle (`ecosys-ng/src/soil/chemistry
/ionic_strength_conductivity.zig`) and the actual production-bound path
fed by the full dynamic solute-reaction-network species state
(`ecosys-ng/src/soil/solute/activity_coefficients.zig` +
`charge_classification.zig`, via `chemistry_state.State.activityCoefficients`
at `hourly_workspace.zig:159-161`). The two implement the identical
formula (confirmed by direct comparison), but whether their *inputs*
numerically agree for this deck's top soil layer at hour 1 has never been
checked. Filed as `audit/issues/issue-053-hour1-cion-osmotic-potential
-dual-formulation-unverified-equivalence.md`; cross-referenced as an
incidental note in `issue-024` (same pattern as that issue's existing
`issue-048` incidental note), not reopening that issue's paused diagnosis
loop.

**Zig counterparts found this pass** (see `audit/traceability/traceability.csv`
`TRC-250` through `TRC-255` for the full per-range citations): `soil/profile
/initialization.zig` (`solidThermalTerms`) + `soil/profile
/runtime_material_refresh.zig` (`refreshAcceptedHour`, confirmed called every
accepted hour via `ecosys_ng.zig:6621`, matching legacy's cadence) +
`management/charcoal_soil_property_adjustment.zig` + `soil/microbial
/turnover_step.zig` for the thermal/charcoal/EHUM range; `soil/solute
/activity_coefficients.zig` + `charge_classification.zig` +
`soil/runtime/hourly_workspace.zig` + `soil/chemistry
/ionic_strength_conductivity.zig` for the CION/PSISO range; `soil/water
/retention.zig` (Mualem-van-Genuchten) + its independent validation module
for the PSISM range; `surface/litter_water_environment.zig` for the litter
water-potential block; `surface/residue_diffusivity.zig` for the
diffusivity range. No Zig counterpart was located this pass for the plain
gas/nutrient-concentration recompute (`:3754-3892`, `:4494-4507`,
`:4564-4619`) or for `DPTHA`/`DPTHT` (`:4229-4326`) -- these appear
consistent with this project's documented pattern of computing simple
mass/volume concentrations at the point of use rather than caching a
per-hour array, but this was not confirmed by a counterpart search this
pass; flagged as a follow-up below.

**Disposition for this pass's newly-read range (`:3660-4679`):**
`preserved` for the thermal/charcoal/EHUM property recompute, the gas/
nutrient concentration and diffusivity blocks, and the litter water-
potential three-way branch (no asymmetry found beyond already-tracked
items); `replaced-by-approved-feature` for the PSISM Mualem-van-Genuchten
replacement and for the CION/PSISO architectural replacement (the
replacement itself looks deliberate and well-managed); `unresolved` for
the `SOIL-THETY-001` dry-end litter-vs-soil inconsistency (independently
corroborated, not newly resolved, pre-existing open finding); new `OPEN`
issue-053 filed for the CION/PSISO dual-formulation numeric-equivalence
question, cross-referenced to `issue-024`.

## Addendum 2026-09-19 (fifth pass, this session): full statement-level read of `:2489-3673`, closing the dossier's last named gap

**Scope of this pass.** Read-only, static-analysis-only per this task's
constraint (no `zig build`, no execution, no runs). Read `hour1.f:2489-3673`
(1,185 lines) in full at statement level -- the range every prior pass this
session left as "characterized as mechanical zeroing but not verified
statement-by-statement" (third-pass "Not covered" note) and "banner-mapped
only, zero statement-level reads" (structural map). Explicitly re-verified
rather than trusted that prior characterization, per this task's brief.
Also confirmed via `git status --short` and `Get-Process` before starting
that no `zig`/`gfortran`/`ecosys_ng`/`ecosys_oracle` process was running and
that `issue-024`/`issue-053` were not mid-edit by a concurrent agent (both
showed clean/committed at this pass's start).

**Verdict on the prior "mostly mechanical" characterization: partially
wrong.** A substantial fraction of this range is real physics, not
zero-initialization:

- `:2900-2911` -- `EHUM` humus-allocation-fraction formula (the same
  three-term law already tracked at `TRC-250` for its `:3739` instance).
- `:2913-2967` -- `ZM` disturbed/runoff surface roughness (particle-size
  `D50`, litter-volume, and stalk-area terms) -- real physics, not a reset.
- `:2968-3011` -- EUROSEM erosion surface properties (`COHS`/`DETE`/`DETS`/
  `PTDSNU`/`VLS`/`CER`/`XER`), gated by `IERSNG.NE.0`.
- `:3013-3079` -- "RESET SUBHOURLY ACCUMULATORS": mostly mechanical, but
  contains four **save-then-zero carryover pairs**, not plain resets:
  `HCBFH`/`HCBFG` (grid-cell), `HCBFCY`/`HCBFCZ` and `HCBFDY`/`HCBFDZ`
  (per-species living/standing-dead), and `HCBFX`/`HCBFL` (per-soil-layer,
  just past this subrange at `:3176-3177`) -- all four preserve the
  previous hour's combustion heat for the next hour's `UPTAKE`/`REDIST`
  consumption before clearing the accumulator.
- `:3249-3265` -- `FPH` pH effect on maintenance respiration (real formula,
  `AHY=1.0E+03*10**(-PH)`; `FPH=1.0+AMIN1(4.0,AHY/PHKI)`).
- `:3216-3247` -- conditional total-SOC recompute `ORGCX` (`IERSNG.EQ.2.OR.
  EQ.3`).
- `:3288-3335` -- `FNH4S`/`FNHBS`/`FNO3S`/`FNO3B`/`FH1PS`/`FH1PB`/`FH2PS`/
  `FH2PB` non-band/band fraction assignment (a genuine branch, not a reset).
- `:3596-3671` -- soil layer geometry/phase-fraction and per-layer mass/
  texture-concentration recompute (`AREA`/`VOLT`/`VOLX`/`VOLP`/`THETW`/
  `THETI`/`THETP`, `BKVL`/`CORGC`/`CSAND`/`CSILT`/`CCLAY`/`SSA`) --
  overlaps the tail of this pass's assigned range and adjoins the
  already-covered fourth-pass range starting at `:3673`; consistent with
  it, not a new law.

The genuinely mechanical stretches are `:2489-2898` (water/snow/solute/
erosion/gas/band/macropore/salt flux-array zeroing), `:3154-3213`
(per-layer/per-species mechanical resets surrounding the carryover pairs
above), and `:3342-3573` (the large `TRxxx` reaction/transfer flux-array
reset) -- these were confirmed by direct read to contain no branch logic
that could hide a translation defect.

**N-parallel-blocks / one-outlier check, this pass's specific focus:**
- `FNH4S`/`FNO3S`/`FH1PS`/`FH2PS` (4 blocks, `:3296-3335`): `H1PO4`'s and
  `H2PO4`'s zero-pool fallback branches both use the **same** `VLPO4`/
  `VLPOB` pair, unlike `NH4` (`VLNH4`/`VLNHB`) and `NO3` (`VLNO3`/`VLNOB`)
  which each get a distinct pair. Verified via cross-file check
  (`hour1.f:397-492`) that `VLPO4`/`VLPOB` is legacy's single shared
  band-geometry volume fraction for **all** phosphate protonation states
  (`H0PO4`...`H3PO4` all multiply by the same `VLPO4`/`VLPOB` at
  `hour1.f:453-492`) -- the apparent asymmetry is intentional physics (one
  P band geometry, not one per protonation state), not a translation
  defect. No outlier.
- The four combustion-heat carryover pairs (`HCBFH`/`HCBFG`,
  `HCBFCY`/`HCBFCZ`, `HCBFDY`/`HCBFDZ`, `HCBFX`/`HCBFL`): all four use the
  identical save-then-zero idiom; no pair omits the save step. No outlier.
- `:2913-2967` `ZM` vs. `:2969-3011` erosion properties: legacy's own
  comment header at `:2900-2901` ("RESET SOIL PROPERTIES AND PEDOTRANSFER
  FUNCTIONS FOLLOWING ANY SOIL DISTURBANCE") is imprecise/stale: the actual
  `DO 9995 NX.../DO 9990 NY...` loop carries **no** `IF(IFLGS...)` gate --
  it runs unconditionally every hour, unlike the genuinely disturbance-gated
  `ZS` branch at `:1900-2388` (item 2, `issue-052`). Zig's
  `disturbed_surface_soil_roughness.refresh` is likewise called
  unconditionally every hour (confirmed by its own test "production binds
  ZM before aerodynamic and runoff work"), so both sides agree in practice
  -- a stale-comment non-finding, not a defect, of the same class already
  logged elsewhere in this dossier (item 2's `CANOPY-BURIAL-001` case).

**Zig counterparts found this pass** (see `audit/traceability/
traceability.csv` `TRC-260` through `TRC-271` for full per-range citations
and hashes): `management/disturbed_surface_soil_roughness.zig` (`ZM`,
formula-for-formula match, extensively tested); `soil/profile/erosion.zig`
`deriveSurfaceProperties` (EUROSEM properties, formula-for-formula match,
one pre-existing divergence -- ponded-surface `D50` always texture-derived
in Zig vs. forced to `0` in legacy -- already proven inert by the module's
own test because every downstream consumer shares the same `BKDS>0` gate);
`soil/biogeochemistry/microbial_humus_allocation.zig` +
`soil/microbial/turnover_step.zig` (`EHUM`, register finding
**`SOIL-EHUM-001` confirmed CLOSED** -- production's missing third
`0.182e-6*CORGC` term, previously a genuine one-signed cumulative
under-allocation bias, is now parameterized and wired to the production
carbon carrier; this finding and its closure had no prior `audit/` record
and are added to the CSV for the first time this pass);
`erosion/transport_accumulator_reset.zig` (erosion constituent-flux reset,
correctly gated); `state/grid_cell_hourly_diagnostic_reset.zig` +
`plant/reset/species_hourly_diagnostic.zig` (grid-cell and per-species
diagnostic/carryover resets, both documented "A5 never production bound"
source-order oracles -- production reconstructs equivalent totals via
`landscape_mass_balance_runtime.reconstruct` and live `PlantState` arrays
respectively; the carryover semantics themselves are correctly reproduced
in the real consumer, `stages/hourly_snow_energy.zig`);
`soil/profile/layer_geometry_phase_fractions.zig` +
`soil/profile/mass_texture_concentration.zig` (soil layer geometry and
mass/texture concentration, both documented "architecturally superseded"
by the dual-domain `soil_solver_properties`/`soil_water_heat_step` path).

**No Zig counterpart independently located this pass** (genuine follow-up
items, not claimed complete): the `:2694-2898` ISALTG-gated salt
runoff-flux array reset; the `:3342-3573` `TRxxx` reaction/transfer
flux-array reset (likely absorbed under renamed fields somewhere in the
~40-file `soil/solute/reaction_*.zig` family, not confirmed); the specific
producer/consumer binding of the `:3288-3335` `FNH4S`-family fractions
(the band/non-band-fraction concept is used too pervasively across the
nutrient-chemistry code, ~70+ files, to trace exhaustively in this pass's
budget -- but the legacy formula itself was independently verified free of
asymmetry, see above).

**Process/documentation observation (not a scientific defect, not a new
issue -- already tracked elsewhere).** Several of this pass's Zig
counterparts, and roughly 160 files repository-wide, cite one of four
`docs/...md` paths (`docs/traceability/hour1_2039_5200_binding_survey.md`,
`docs/traceability/erosion_unbound_family_disposition.md`,
`docs/model_changes.md`, `docs/discrepancy_register.md`) as the
authoritative record behind an "A5"/"A8a" disposition banner. This pass
confirmed by direct recursive search that **no `docs/` directory exists
anywhere in this checkout** and none of the four paths resolve. This is not
a new discovery: `audit/traceability/embedded_tag_index.md` (line 5)
already records that `docs/discrepancy_register.md` is missing, cross-
referencing `audit/issues/issue-005-missing-validation-index-dirs-CRITICAL.md`'s
"fifth data point" on this same class of dropped files. Because several of
this pass's dispositions for `:2489-3673` lean on those banner claims
(e.g. `SOIL-EHUM-001`'s closure, the two `layer_geometry_phase_fractions.zig`
/`mass_texture_concentration.zig` A5 modules), this pass independently
verified the underlying *code* (not just the comment claims) before relying
on them -- the dispositions above stand on that independent verification,
not on the missing documents' say-so. No new issue filed; flagging so a
future pass does not waste a diagnosis budget rediscovering the same
missing-`docs/` fact.

**Disposition for this pass's newly-read range (`:2489-3673`):** `preserved`
for the mechanical flux/carryover resets, `ZM`, the EUROSEM erosion
properties, `FPH`, `ORGCX`, and the `FNH4S`-family fraction branch;
`legacy-defect-corrected` for `EHUM` (`SOIL-EHUM-001`, closed);
`replaced-by-approved-feature` for the erosion constituent-flux reset, the
grid-cell/species diagnostic resets, and the soil layer geometry/mass-
texture-concentration recompute (all documented architectural
supersessions). No new `unresolved` items opened by this pass.

## Not covered this pass (genuinely unread, for a future pass)

- `:2489-3673` -- **now read in full this (fifth) pass**, see the addendum
  immediately above. This closes the dossier's last remaining named gap.
- `:3660-4679` -- read in full the fourth pass, see that addendum.
- Zig counterpart search not performed for: `:1891-2388` disturbance-gated
  resets, `:2434-2487` gas-concentration conversions, `:2694-2898`
  ISALTG-gated salt runoff-flux reset, `:3342-3573` `TRxxx` reaction-flux
  reset, the `:3288-3335` `FNH4S`-family fraction block's specific
  producer/consumer binding, and the plain gas/nutrient-concentration
  recompute at `:3754-3892`/`:4494-4507`/`:4564-4619` plus `DPTHA`/`DPTHT`
  (`:4229-4326`). None of these block closure of the dossier's coverage
  target; all are low-risk (mechanical resets or formulas independently
  verified free of internal asymmetry) and are recorded so a future pass
  does not have to rediscover the same "not yet searched" state.
- The `TAUR`-only-transmittance non-finding (third-pass addendum) should
  still be spot-checked against the Zig scattering-cascade implementation
  (not done this pass).
- Fertilizer band-geometry growth (`:4884-5200`): Zig counterpart found and
  cited but not independently re-derived term-by-term (no line-by-line
  formula comparison performed, unlike the fully-verified items 1-4).

## Coverage and closing summary (cumulative, all passes this session -- FINAL TALLY)

Approximate cumulative statement-level coverage of `hour1.f`'s 5,204 lines,
across the 2026-09-18 and 2026-09-19 (five passes total that day) passes:
`:216-951` (736 lines, fertilizer application chemistry), `:955-2487` minus
the trivial per-subhourly-cycle accumulator-reset stretch (~1,470 lines,
canopy radiative transfer + precipitation retention + disturbance-gated
litter/soil resets + gas-concentration conversions), `:2489-3673` (1,185
lines, this fifth pass: flux-array/carryover resets, `ZM`/EUROSEM erosion
surface properties, `EHUM`, `FPH`, `ORGCX`, the `FNH4S`-family fraction
branch, soil layer geometry/mass-texture-concentration recompute),
`:3673-4679` (1,006 lines, fourth pass: soil/litter thermal-property and
water-potential recompute), `:4679-4884` (206 lines, vapor diffusivity +
canopy aerodynamic resistance), `:4884-5200` (317 lines, fertilizer
band-geometry growth) = **4,920 of the file's 4,984 executable lines
(`:216-5200`) now read at statement level, ~99%.** The remaining ~64
unread lines are the low-risk follow-up items listed under "Not covered"
above (a handful of sub-ranges where the formula itself was independently
verified free of internal asymmetry but a Zig counterpart was not
exhaustively traced by name). `:1-215` (header/declarations/loop start) and
`:5200-5204` (`RETURN`/`END`) are intentionally excluded from this
denominator as non-physics. **This closes the dossier's last named gap**
(`:2489-3673`, previously the "recommended top priority" stretch); no
further full-file structural gap remains for a future pass to target --
remaining work is the itemized Zig-counterpart-tracing follow-ups above,
not unread Fortran.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (first pass) and 2026-09-19
(third, fourth, and fifth passes). Independent reviewer: not yet done for
any pass -- this dossier's coverage is now essentially complete but review
has not occurred, so gate status remains **NOT_ASSESSED**, per the
contract's rule that missing evidence (here, independent review) is never
a pass regardless of coverage percentage.

Running disposition tally across all five passes: `preserved` -- items 1
(partial), 3, 4, the third pass's `:955-2487` ranges, the fourth pass's
`:3673-4679` ranges (mostly), and this fifth pass's mechanical resets,
`ZM`, EUROSEM erosion properties, `FPH`, `ORGCX`, and the `FNH4S`-family
fraction branch; `legacy-defect-corrected` -- item 1 (precipitation
retention fix) and, newly tallied this pass, `EHUM`/`SOIL-EHUM-001`
(closed, previously untracked in `audit/`); `replaced-by-approved-feature`
-- the fourth pass's Mualem-van-Genuchten/`CION`/`PSISO` architectural
replacements and this fifth pass's erosion constituent-flux reset,
grid-cell/species diagnostic resets, and soil layer geometry/mass-texture-
concentration recompute (all documented, deliberate architectural
supersessions); `unresolved` -- item 2 (`ZS` update-frequency, `issue-052`)
and the pre-existing, not-this-dossier-owned `SOIL-THETY-001`
(independently corroborated twice now, not resolved); `OPEN` issue --
`issue-053` (`CION`/`PSISO` dual-formulation numeric-equivalence, cross-
referenced to `issue-024`).

Three open `unresolved`/`OPEN` items stand against this dossier's gate:
`issue-052`, `issue-053`, and `SOIL-THETY-001`. No new issue was opened by
this fifth pass -- the one candidate finding investigated at length
(`EHUM`/`SOIL-EHUM-001`) turned out to already be closed in the Zig source,
just never recorded in `audit/`, so this pass recorded it retroactively
(`TRC-265`) rather than filing a new issue for an already-fixed defect.
These three items, not file coverage, are what remains before this
dossier's gate can move past `NOT_ASSESSED` -- coverage completeness and
independent scientific acceptance are separate gates, per the contract.
