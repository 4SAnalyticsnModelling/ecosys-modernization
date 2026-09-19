# Issue 024 -- GROSUB combustion cascade has a second, fully-documented Zig implementation that is dead code

Status: OPEN (needs reviewer decision on whether to delete the unused helper; not a mass-balance or science divergence found so far)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979

Failure signature and first bad time/location/process:
`f77src/grosub.f:11735-12545` (sha256 `FBE2EE22EAF6E91F8BC8AC0CE01C208F92BBE34662D0D4BEFA20DF886B83F674`) implements the `ICHKF`-gated fire/combustion cascade for shoot, standing dead, charcoal, root, root nodule, and storage pools. This is a **live, production-active code path**: it runs whenever a fire event flag is set for a grid cell/hour.

`ecosys-ng/src/management/plant_harvest_source_order_combustion.zig` (sha256 `BB773888CB6F0E8013ABFBA65274BEA51153472570E1A785D679B8C79FF0D1D6`, 1187 lines) reimplements this entire cascade with unusually careful, individually-cited headers: `sourceOrderAggregateFireCarbonInventory` ("Exact GROSUB 11735-11795"), `sourceOrderCombustionRates` ("Exact GROSUB 11812-11839"), `sourceOrderShootCombustionFractions` ("Exact GROSUB 11857-11915"), `sourceOrderShootCombustionLosses` ("Exact GROSUB 11934-11988"), `sourceOrderShootSaltCombustion` ("Exact GROSUB 12011-12028"), `sourceOrderStandingDeadCombustion` ("Exact GROSUB 12112-12138"), `sourceOrderCharcoalCombustion` ("Exact GROSUB 12152-12178"), `sourceOrderResetNoCombustion` ("Exact GROSUB 12183-12234"), `sourceOrderRootStorageCombustion` ("Exact GROSUB 12253-12332"), `sourceOrderApplyRootDomainCombustion` ("Exact GROSUB 12339-12454"), `sourceOrderRootNoduleCombustion` ("Exact GROSUB 12461-12492"), `sourceOrderResetColdSoilCombustion` ("Exact GROSUB 12506-12541").

A repo-wide grep (`ecosys-ng/src`) for every one of these twelve exported function names found exactly five referencing files: the module itself; two re-export shims (`ecosys-ng/src/management/plant_harvest_runtime.zig`, `ecosys-ng/src/management/plant_harvest_runtime_source_order_exports.zig`); `ecosys-ng/src/management/plant_harvest_source_order.zig` (another re-export layer); and `ecosys-ng/src/validation/plant_harvest_runtime_test_part4.zig` (the module's own test file). **No production stage (`ecosys-ng/src/stages/*`, `ecosys_ng.zig`, `disturbance_management_dispatch.zig`) calls any of these twelve functions.**

The actual live production combustion path is split across two different files:
- Canopy/standing-dead/charcoal combustion: `ecosys-ng/src/plant/growth/shoot_fire.zig` (sha256 `84CA414161393E0047F3F788F476826A1BA17263AD50B6867A7A21C2C8B1F200`), `apply()` at `:40`, called from `ecosys-ng/src/stages/hourly_vegetation.zig:54-94` (`produceCanopyStandingDeadFireBeforeSolute`), gated on `context.fire_active_this_hour`.
- Root/nodule/storage combustion: `ecosys-ng/src/management/disturbance_management_dispatch.zig` (sha256 `F5C131F1CB466E1C73BE6EB618B807B1022ECC174904E133AB665551BA4FA485`), `applyRootFireCombustion` at `:1315-1436`, called from `ecosys_ng.zig:5236`, also gated on `fire_active_this_hour`.

Both live-path files share their Arrhenius/charcoal constants and a `combustionFraction` helper via `ecosys-ng/src/plant/root/plant_root_disturbance.zig` (sha256 `D8EE5BDA057AACEEE6AB7DAADAC2F79B41200CFDFA5C2FA2DA1C33AA85AFD1D9`, imported into `shoot_fire.zig` as `FireScience`), and both cite the same GROSUB line ranges as the dead helper, using identical constants (`8.3143`, `12.028`/`60000`, `20.620`/`120000`, `SPCMB`-equivalent specific rates).

This is the same *shape* of finding as `issue-022` (a well-documented "Exact GROSUB" helper that turns out to be dead code, with a structurally different live algorithm actually in production), but a different *outcome* on inspection: unlike `issue-022`'s `allocateGrazingDemand` (which is provably non-equivalent to the dead helper it replaced), the live `shoot_fire.zig`/`disturbance_management_dispatch.zig` path here appears to implement the *same* equations as the dead helper, just organized into different files with different internal data representations. No non-equivalence has been found -- but this has not been proven with a matched-state numerical test, only by reading both implementations side by side.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: static code trace only (this session's audit fork, 2026-09-18); no runtime reproduction executed.
Input/state provenance: n/a (static analysis; grep of all twelve exported function names across `ecosys-ng/src`).
Hypothesis: `plant_harvest_source_order_combustion.zig` is leftover scaffolding from an earlier translation pass, superseded by a later reorganization into `shoot_fire.zig`/`disturbance_management_dispatch.zig`, and never deleted -- analogous to `issue-022`'s `sourceOrderAdditionalGrazingRemoval`.
Stop/resource budget: one grep-based experiment (caller search) was sufficient to establish dead-code status; a second, deeper experiment (matched-state numerical comparison of the two implementations) was not run this pass and is the recommended next step if a reviewer wants stronger equivalence evidence before authorizing deletion.

## Experiments
Experiment 1: grepped `ecosys-ng/src` for each of the twelve public function names in `plant_harvest_source_order_combustion.zig`. Result: only self-references, re-export shims, and the module's own test file found; zero production stage callers. CONFIRMED dead code by call-graph, not by name-only inspection.

## Resolution
Cause and focused patch: not yet decided; no patch applied. Two candidate dispositions, mirroring `issue-022`'s framing:
  1. `preserved` for the live path (`shoot_fire.zig` + `plant_root_disturbance.zig` + `disturbance_management_dispatch.zig`); retire `plant_harvest_source_order_combustion.zig` and its test file as superseded scaffolding, after a matched-state numerical check confirms no silent divergence.
  2. If a reviewer finds a subtle non-equivalence once tested numerically, treat this as an `issue-022`-class divergence requiring a design decision on which algorithm is authoritative.
Before/after results: n/a -- no patch applied.
Regression added and actually executed: none yet.
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN, needs a matched-state numerical comparison before the dead helper can be safely deleted**, even though static inspection found no evidence of a science-relevant divergence (unlike `issue-022`). Per `PROJECT_CONTRACT.md`, dormant/non-production branches remain in the audit denominator until a disposition is recorded; this issue is that record for `plant_harvest_source_order_combustion.zig`.
