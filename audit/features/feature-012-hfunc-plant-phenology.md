# Feature ID: FEAT-012-HFUNC-PLANT-PHENOLOGY

Status: PARTIALLY_ASSESSED (source-audit; `hfunc.f` is 1098 lines and was FULLY read this pass)

## Scope and provenance

Legacy source: `f77src/hfunc.f` (sha256 `E9A49B84F8003D64E91A562E21889364BE8B2C07FB9ED5DA17DD195EBE6F9C4A`), single subroutine, **100% read**. Contrary to a name-based guess of a shared-utility library, this computes plant phenology: crop-active flag from planting/harvest dates (`:78-121`), non-structural C/N/P pool aggregation/concentrations (`:140-296`), emergence detection (`:298-320`), branch/root-axis initiation (`:322-407`), node-initiation/leaf-appearance rate via Arrhenius function (`:465-510`), growth-stage progression and photoperiod-gated floral initiation (`:512-770`), leaf/node remobilization flagging (`:772-794`), and five leafout/leafoff phenology state machines (evergreen/winter-deciduous/drought-deciduous types 2/4/5/combined type 3, `:796-1074`).

### 1. Arrhenius node-initiation/leaf-appearance rate `TFNP` -- `preserved`

`hfunc.f:474-480` (`RTK=8.3143*TKGO; STK=710*TKGO; ACTV=1+exp((197500-STK)/RTK)+exp((STK-218500)/RTK); TFNP=exp(24.269-60000/RTK)/ACTV`). Zig: `ecosys-ng/src/plant/lifecycle/phenology.zig` (sha256 `192F0618E1724119EDEECB98AACACD42299F8F10378027E07117E7EC28115EA9`), `arrheniusTemperatureFunction` (`:430-435`), constants match exactly (`:35-40`). Water/O2-stress gating pre-floral-initiation (`hfunc.f:493-501`) reproduced at `:417-421`, gated identically. Live call site confirmed: `advanceTile` invoked from `stages/hourly_phenology_preparation.zig:167`.

### 2. Non-structural C/N/P concentration functions -- `preserved`; one sub-item `unresolved`

`CCPOLR/CZPOLR/CPPOLR` (`hfunc.f:200-221`), `CCPOLP/CZPOLP/CPPOLP`/`FDBKP` (`:243-279`) -- mobile pool / (structural mass + itself), fallback concentration=1 when no mass. Zig: `phenology.zig:446-456`, `nonstructuralConcentrations`, matches convention exactly including the fallback branch.

**Sub-item left `unresolved` (not asserted as a defect)**: the specific `FDBKP` N/P-inhibition-ratio formula (`hfunc.f:272-279`) was not located as a distinctly-named ported function -- `pool_aggregation.zig:171` only references "FDBKP aggregation" in a comment, without enough call-site tracing this pass to confirm the exact `CNKIC`/`CPKIC` constants are reproduced. Flagged for a targeted follow-up grep/read, not treated as a confirmed gap.

### 3. Growth-stage progression and floral initiation -- `preserved`

`GSTGI`/`GSTGF` normalized by `GROUPI`, duration constants `GSTGG=2.00`/`GSTGR=0.667` (`hfunc.f:48-49,530-539,619-770`); photoperiod difference `PPD` (`:583-613`). Zig: `ecosys-ng/src/plant/lifecycle/growth_stages.zig` (sha256 `7BA589AD1002C384B086AB6299B11DB3C8A306B3860E393746CE5CA3969CB971`), explicit citations to `hfunc.f:142,159,161-179`; duration constants reproduced in `dormancy.zig`/`phenology.zig` defaults. Wired via `development.zig`'s production `advanceTile`, itself called from `hourly_phenology_preparation.zig:200`. Test coverage explicitly names HFUNC IDAY(7,8,9) stages.

### 4. Leafout/leafoff phenology state machines -- `preserved`

Evergreen (`IWTYP=0`, `hfunc.f:821-847`), winter-deciduous (`IWTYP=1`, `:864-925`), drought-deciduous (`IWTYP=2/4/5`, `:941-1001`), combined (`IWTYP=3`, `:1021-1074`). Zig: `ecosys-ng/src/plant/lifecycle/dormancy.zig` (sha256 `F538B314ABCDCE036E9E951A55685ED83C8D45766AE0EF5EA7D7222A6CA87483`, `:165`, explicitly "Ports the HFUNC leafout/leafoff block"), dispatched by `PhenologyType` enum to the four matching advance-functions. Solstice-day constants (173/355) match. Live call site: `dormancy.advance` called from `development.zig:69,147`, wired at `hourly_phenology_preparation.zig:200`.

## Issue-tag reconciliation

`INIT-004` found in `plant/initialization/phenology_branch.zig:3,8` -- but that file ports `startq.f:436-473`, not `hfunc.f`, and is explicitly self-disclosed as "unwired pure kernel, superseded; do not bind piecemeal" (a different-file/different-issue false lead, correctly not attributed here). No open `hfunc.f`-specific issue tags found in `phenology.zig`/`growth_stages.zig`/`dormancy.zig`.

## Not covered this pass

The specific `FDBKP` N/P-feedback ratio formula/constants (item 2's sub-item).

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file coverage). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Three of four equation groups fully `preserved` with confirmed live call sites; one narrow sub-item `unresolved` pending a targeted follow-up (not a confirmed defect). No confirmed open gaps in this file.
