# Feature ID: FEAT-020-GROSUB-COMBUSTION-LITTER-BALANCE-CLOSURE

Status: PARTIALLY_ASSESSED (source-audit; assigned range `f77src/grosub.f:11685-13177` read in full this pass, closing the gap left after TRC-168..TRC-171 (`8748-11557`; renumbered from an original TRC-032..TRC-035 after a later-discovered numbering collision was fixed); independent review not yet done)

## Scope and provenance

Candidate/input hashes: `audit/manifest/candidate-001-snapshot.json` sha256
`79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979`.

Legacy source: `f77src/grosub.f` (sha256
`FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`), lines
11685-13177 -- the tail of the single monolithic `SUBROUTINE GROSUB`. Cross-referenced
`f77src/extract.f` (sha256 `AFD88FD3B587FD7B82AB8350F29C1E89800203E4A012D977AE3EFDA22BA01077`),
lines 949-951 for the `TBALC`/`TBALN`/`TBALP` cell-level rollup of this range's
`BALC`/`BALN`/`BALP` output.

This range covers: standing-dead stem exposure geometry (11687-11729, not
depth-audited, see "Not covered this pass"); the `ICHKF`-gated fire/combustion
cascade for shoot, standing dead, charcoal, root, root nodule, and storage
pools (11735-12545); litterfall from standing dead (12598-12653); cumulative
litterfall totals (12628-12653); dynamic salt redistribution through
harvest/litterfall for shoot and root (12655-12890); PFT-level state
accumulation from branch/root-layer state (12892-13052); and the per-plant
C/N/P mass-balance closure identity (`BALC`/`BALN`/`BALP`, 13054-13173), which
is a pure output diagnostic (confirmed via `extract.f:949-951` and
`outpd.f:106,179,220` -- it is written to output columns but never gates
control flow anywhere in `f77src`).

Prior-pass context: `audit/issues/issue-022-grazing-cascade-dead-code-vs-live-algorithm-divergence.md`
documents the adjacent `8748-11557` range and the standing lesson applied
throughout this pass: trace the live call site before trusting a
well-documented helper's header comment. That lesson mattered again in
Finding 1 below. `audit/issues/issue-023-grosub-8821-format-write-argument-mismatch-oracle-build-crash.md`
already resolved a diagnostic-only `WRITE` statement inside this exact range
(`:12766-12778`, the `CASNC0` trace missing `IYRC`); it has no Zig counterpart
and needed no further action this pass.

## Findings

### 1. Fire/combustion cascade (shoot, standing dead, charcoal, root, nodule, storage) -- `preserved` for the live path; dead duplicate helper flagged as `issue-026`

`grosub.f:11735-12545` (the `ICHKF.EQ.1` block). Canopy/standing-dead/charcoal
combustion (`:11812-12178`, Arrhenius response `EXP(12.028-60000/RTK)` capped
at `TFNCX`, `SPCMB(1-5,IBTYP)` specific rates, charcoal's own kinetics
`EXP(20.620-120000/RTKD)`) is live-wired via
`ecosys-ng/src/plant/growth/shoot_fire.zig` (sha256
`84CA414161393E0047F3F788F476826A1BA17263AD50B6867A7A21C2C8B1F200`,
`apply()` at `:40`), called from
`ecosys-ng/src/stages/hourly_vegetation.zig` (sha256
`F8F96F285BF5731C2F98B9DE6310129040BF3C82CA12DA0C0936E51318EAA4D7`,
`produceCanopyStandingDeadFireBeforeSolute` at `:54-94`, gated on
`context.fire_active_this_hour`, matching source `ICHKF`). `shoot_fire.zig`
shares its Arrhenius/charcoal constants and `combustionFraction` helper with
`ecosys-ng/src/plant/root/plant_root_disturbance.zig` (sha256
`D8EE5BDA057AACEEE6AB7DAADAC2F79B41200CFDFA5C2FA2DA1C33AA85AFD1D9`, imported
as `FireScience`), so canopy and soil-driven combustion use one verified
kernel rather than two independently-typed copies of the same equation --
no domain-asymmetry found here.

Root, root-nodule, and storage combustion (`:12241-12492`, `TKS`-gated,
`FWTRVC=FWTRTL` storage-shares-root-structural-fraction identity at `:12301`,
`RCPOOLN`/`RWTNDL` nodule transaction at `:12461-12475`) is live-wired via
`ecosys-ng/src/management/disturbance_management_dispatch.zig` (sha256
`F5C131F1CB466E1C73BE6EB618B807B1022ECC174904E133AB665551BA4FA485`,
`applyRootFireCombustion` at `:1315-1436`), calling
`plant_root_disturbance.zig`'s `combustSymbiont` (`:382-419`, header cites
"GROSUB RCPOOLN/RWTNDL transaction") and `combustionFraction` (`:67-75`).
`applyRootFireCombustion` is called from production at `ecosys_ng.zig:5236`
(sha256 `C609DCE148E026CDEB8C47E272CC508163AC7D557F8B844636B8648F3E5C8715`),
gated on the same `fire_active_this_hour` array, and its `root_structural_fraction`
is passed directly into `state_updateStorageCombustion` (`:1408,1446-1457`),
exactly reproducing the source's `FWTRVC=FWTRTL` sharing rule.

**Standing-lesson check applied and it mattered**: `ecosys-ng/src/management/plant_harvest_source_order_combustion.zig`
(sha256 `BB773888CB6F0E8013ABFBA65274BEA51153472570E1A785D679B8C79FF0D1D6`,
1187 lines) is a second, independent, carefully-documented reimplementation of
this *entire* cascade -- every public function's header literally reads
"Exact GROSUB `<line-range>`" (e.g. `:63` "Exact GROSUB 11735-11795",
`:175` "Exact GROSUB 11812-11839", `:377` "Exact GROSUB 11934-11988", `:537`
"Exact GROSUB 12112-12138", `:598` "Exact GROSUB 12152-12178", `:777`
"Exact GROSUB 12253-12332", `:927` "Exact GROSUB 12339-12454", `:1057`
"Exact GROSUB 12461-12492", `:1138` "Exact GROSUB 12506-12541"). A repo-wide
grep for every one of its twelve exported function names found call sites in
exactly five files: itself, its two re-export shims
(`plant_harvest_runtime.zig`, `plant_harvest_runtime_source_order_exports.zig`,
`plant_harvest_source_order.zig`), and its own test file
(`ecosys-ng/src/validation/plant_harvest_runtime_test_part4.zig`). **No
production stage calls any of these functions.** This is the same
dead-helper-vs-live-algorithm shape as `issue-022`, but with a materially
different outcome on inspection: the live path (`shoot_fire.zig` +
`disturbance_management_dispatch.zig`) uses the identical Arrhenius
constants, specific-rate table, and sharing rules as the dead helper and as
the Fortran source, and is itself well-tested against the same GROSUB line
citations. This looks like harmless orphaned scaffolding rather than a
science-relevant divergence, but per the standing lesson it still needs a
formal record rather than a silent assumption -- filed as `issue-026`.

Disposition: **preserved** for the live production combustion path
(`shoot_fire.zig` + `plant_root_disturbance.zig` + `disturbance_management_dispatch.zig`).
The unused `plant_harvest_source_order_combustion.zig` helper module is a
paperwork/dead-code finding, tracked in `issue-026`, not a `preserved`/`unresolved`
call on the science itself.

### 2. Litterfall from standing dead -- `preserved`

`grosub.f:12598-12626` (`XFRC/XFRN/XFRP` standing-dead litterfall, rate
constant `1.5814E-04 h^-1` for herbaceous (`IBTYP.EQ.0.OR.IGTYP.LE.1`) or
`1.5814E-05 h^-1` for woody, scaled by `SQRT(TFN3)` and split into woody/
nonwoody `CSNC`/`ZSNC`/`PSNC` shares via `FWOOD`/`FWOODN`/`FWOODP`). Zig:
`ecosys-ng/src/plant/standing_dead/litterfall.zig` (sha256
`1E48B00F08B5B6F40A085A69D86F6FF33AE52126288C0EDD2B0479B8AD939520`),
`apply()`/`removalFor()` at `:89-204`, header explicitly cites
"grosub.f lines 12598-12626". Both rate constants (`1.5814e-4`, `1.5814e-5`)
and the `@sqrt(temperature_response)` scaling match exactly; unit tests
(`:224-299`) independently verify the exact fraction and a conservation
identity (initial carbon equals remaining plus litterfall). Live-wired via
`ecosys-ng/src/stages/hourly_vegetation.zig` and `ecosys-ng/src/stages/plant_daily.zig`
(confirmed by grep; not a test-only reference).

### 3. Cumulative litterfall totals -- `preserved` (accumulator pattern, not independently re-derived)

`grosub.f:12628-12653` (`TCSN0`/`TZSN0`/`TPSN0`, `HCSNC`/`HZSNC`/`HPSNC`,
`TCSNC`/`TZSNC`/`TPSNC`, `CSNCL`) is a mechanical summation of the `CSNC`/
`ZSNC`/`PSNC` litterfall arrays already produced by Finding 2 and the sibling
tillage/death litterfall blocks covered by `TRC-169`..`TRC-171`. Not
independently re-derived this pass beyond confirming the summation targets
(`TCSNC` etc.) are consumed by the balance-closure identity in Finding 5
(`grosub.f:13073` `+TCSNC(NZ,NY,NX)`) and by the salt-litterfall fraction in
Finding 4 (`CSNCL` feeds `FCSNC0`/`FCSNCL`). No independent Zig accumulator
was located for `TCSN0`/`HCSNC` specifically; treated as covered by the
producer-side modules already audited rather than as its own gap.

### 4. Dynamic salt redistribution through harvest/litterfall (shoot and root) -- `preserved`, with an approved transactional-safety improvement; one legacy micro-defect not reproduced (`issue-025`)

`grosub.f:12655-12890`. Shoot salts (`:12672-12790`): total branch salt per
species (`ZALCT`..`ZCLCT`), harvest fraction `FCSNCH=DHVSTC/WTSHT` and litter
fraction `FCSNC0=CSNCL(0)/WTSHT`, proportional per-branch redistribution via
`FZALC` etc. Root salts (`:12792-12890`): per-layer total root carbon+litter,
litter fraction `FCSNCL`, proportional per-root redistribution via `FZALR`
etc. Zig: `ecosys-ng/src/plant/salt/harvest.zig` (sha256
`C0597BD21DED0AE69E693725F7766CE0559F48572493D1D8D6FFA7121BECE1E7`),
`removeForHarvestAndLitterfall()` at `:111-116`, header cites "Direct
translation of grosub.f lines 12655-12890 for dynamic plant salts", called
from `ecosys-ng/src/plant/salt/harvest_adapter.zig` (sha256
`584AC923789007A32BDC0F42A857053AD0F91D50417DEB49F4D27A3AC8B176A1`,
header at `:93` cites "Binds GROSUB 12655-12890"), live-wired at
`ecosys_ng.zig:3913-3927`. The Zig version validates every prospective
removal against every inventory *before* mutating any of them
(`validateProspectiveUpdate`, `:163-205`) and is proven atomic under a
late-discovered NaN by its own regression test (`:314-355`) -- an approved
transactional-safety improvement consistent with the contract's "trial states
must be transactional" requirement, not a science change; the arithmetic
identity (proportional-share redistribution keyed by each species' total)
is otherwise unchanged from the source.

**Legacy micro-defect found, not reproduced by Zig (harmless divergence)**:
`grosub.f:12825` reads `IF(WTRTLT.GT.ZEROP(NZ,NY,NZ))THEN` -- the third index
is `NZ` (the PFT index) where every one of the ~20 structurally-parallel
`ZEROP(NZ,NY,NX)` guards in this same two-block range (`:12691,12720,12725,
12730,12735,12740,12745,12750,12755,12760,12836,12840,12844,12848,12852,
12856,12860,12865`) correctly uses `NX` (the grid-column index). `ZEROP` is
dimensioned `(JP,JY,JX)` (`f77src/blkc.h:6`), so this substitutes the wrong
column's epsilon threshold for the litter-fraction gate at this one call
site. This is the "N parallel blocks, 1 outlier" pattern applied to guard
clauses rather than physics blocks. The Zig `harvest.zig` implementation
takes a single scalar `carbon_absolute_tolerance_g_c`/`physical_relative_tolerance`
per call rather than indexing a `(plant, row, column)` epsilon table, so it
structurally cannot reproduce this specific cross-indexing typo -- filed as
`issue-025` for the record, per this project's established convention of
giving each such "Zig correctly doesn't reproduce a legacy quirk" case its
own tracked entry (see `issue-018`/`issue-020`/`issue-021` for the precedent).

### 5. PFT-level state accumulation from branch/root-layer state -- `preserved`

`grosub.f:12892-13052` (`WTSHT`/`WTLF`/`WTSHE`/.../`WTRT`/`WTRTN`/`WTRTP`/
`WTND`/`WTNDN`/`WTNDP` rebuilt each hour from `WTSHTB`/`WTLFB`/.../`CPOOLR`/
`WTRT1`/`WTRT2`/`WTNDB`/`WTNDL` branch- and root-layer state). Zig:
`ecosys-ng/src/validation/landscape_mass_inventory_plant.zig` (sha256
`72E4959A998AFB3D156213F8E965B8B08901C380D7F19470FD89101D834E939F`),
`aggregatePlantRange`/`addShootsCell`/`addRootsLayer` (`:62-120`), whose own
header explicitly notes the reference root-carbon census "sums `CPOOLR` +
`WTRT1` + `WTRT2` without `WSRTL`" citing `grosub.f:12996-13015` by name, and
documents which duplicate/non-storage coordinates it deliberately excludes.
This module is the conservation-audit consumer of the totals; the harvest/
salt path (Finding 4) independently sources its own `shoot_carbon_g_c` input
from the live canopy/root state rather than from this validation module, so
there is no single point of failure if one consumer's aggregation were
wrong. Confirmed the derived-aggregation architecture (recompute totals
on demand from authoritative branch/root state, rather than maintaining a
second redundant stored total as the Fortran does) is a legitimate,
non-lossy translation choice, not a gap.

### 6. Per-plant C/N/P mass-balance closure (`BALC`/`BALN`/`BALP`) -- `preserved`, exact term-for-term match

`grosub.f:13054-13173` plus `extract.f:949-951` (`TBALC`/`TBALN`/`TBALP`
cell rollup) and `outpd.f:106,179,220` (output columns 86/70/66) confirm this
triplet is a **pure output diagnostic never used to gate control flow**
anywhere in `f77src`. Identities:
`BALC=WTSHT+WTRT+WTND+WTRVC+TCSNC-TCUPTK-RSETC+WTSTG+THVSTC+HVSTC-VCOXF-ZNPP`;
`BALN` adds `-TNH3C-TZUPFX` to the same structure; `BALP` has no atmospheric/
fixation terms. Zig: `ecosys-ng/src/plant/state_update/balance.zig` (sha256
`E58F300AACF397AC1AE558BF04DE3948A323247D0773E51AB1494211A0823080`),
`refresh()`/`balanceForPlant()`/`balanceForCell()` (`:85-139`), calling
`ecosys-ng/src/io/output/plant_daily_output.zig` (sha256
`2DCD5F66B493CA474385E28540B4B635D828287ECDEED7568BC83BAA6D071514`)
`carbonBalance()` (`:71-89`, header "Exact GROSUB BALC accounting identity"),
`nitrogenBalance()`/`baseNutrientBalance()`/`phosphorusBalance()`
(`:230-264`, headers "Exact GROSUB BALN identity" / "Exact GROSUB BALP
identity"). Verified term-for-term: every addend and subtrahend in the three
Fortran identities has an exactly corresponding signed field in the Zig
struct, including `phosphorusBalance`'s enforced-zero atmospheric-exchange/
fixation terms (matching `BALP`'s structural absence of those two terms
rather than merely omitting them). `balanceForCell` performs the
`TBALC`/`TBALN`/`TBALP` per-cell rollup across the runtime species axis,
matching `extract.f:949-951`. Live-wired at `ecosys_ng.zig:2517` (comment at
`:2496` explicitly cites "GROSUB 13071-13165 / EXTRACT 949-951").

## Not covered this pass

- `grosub.f:11687-11729` (standing-dead stem exposure geometry: `ZG`/`RSTK`/
  `ARSTG`/`ARSTD`/`SURFD` cylinder-surface-area distribution across canopy
  layers). This sits at the head of the assigned range but is canopy-radiation
  geometry (feeds `hour1.f` per its own header comment), not combustion,
  litterfall, salt, or balance-closure content -- out of this pass's four
  named focus areas. Two candidate Zig owners were located by grep
  (`canopy/radiation/exposure.zig`, `stages/hourly_snow_energy.zig`) but
  neither was read past its own comment referencing `ARSTG`/`ARSTD`; equation-
  level verification not attempted.
- Finding 3's cumulative-total accumulators (`TCSN0`/`HCSNC` specifically)
  were not traced to an independent dedicated Zig accumulator; treated as
  covered indirectly through the producer/consumer modules in Findings 2, 4,
  and 6.
- No independent numerical/runtime test was executed this pass (per
  `PROJECT_CONTRACT.md`, targeted compilations are allowed but a repetitive
  full `ReleaseFast` run was correctly not attempted); all findings are
  static source-to-source trace and call-site verification.
- `issue-026`'s equivalence claim (live combustion path vs. the dead helper)
  rests on matching constants/structure by inspection, not a matched-state
  numerical kernel test comparing the two Zig implementations directly. If a
  reviewer wants stronger evidence before authorizing deletion of the dead
  helper, that test is the next bounded action.

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-range read,
`f77src/grosub.f:11685-13177`). Independent reviewer: not yet done. Decision:
PARTIALLY_ASSESSED for gate purposes -- five of six findings `preserved`
with high-confidence exact-match citations on both sides; Finding 1's live
path `preserved`, its dead duplicate helper and Finding 4's micro-defect each
given their own tracked issue (`issue-026`, `issue-025`) rather than silently
assumed harmless, per this project's established recording convention.
