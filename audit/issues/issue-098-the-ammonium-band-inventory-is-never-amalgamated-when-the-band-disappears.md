# Issue 098 -- the AMMONIUM band inventory is never amalgamated when the band disappears, stranding nitrogen in a zero-volume domain: this is the hour-3,275 frontier blocker

Status: **OPEN, ROOT CAUSE OF THE FRONTIER FAILURE, CONFIRMED BY INSTRUMENTED REPRODUCTION AND SOURCE ON BOTH SIDES (filed 2026-09-22, adversarial Claude/Pi session).** Fix specified below and deliberately not applied in the same step as the diagnosis.

Genuinely new: `MineralNitrogenInZeroWaterDomain` returns **zero hits** across the 615-file reference documentation tree (`issue-097`), including the 49,801-line `discrepancy_register.md`.

## The measurement

`run-021` established that `issue-090`'s fix does not clear hour 3,275 and the run still dies on `MineralNitrogenInZeroWaterDomain`. The error name carries no context -- six call sites, two possible causes, no layer -- so `concentration()` (`soil/biogeochemistry/mineral_nitrogen_transport.zig:671`) was instrumented on its failure path only and the run reproduced in ~9 minutes with `ReleaseSafe`:

```
error: TEMP_DIAGNOSTIC MineralNitrogenInZeroWaterDomain:
  species=ammonium_band  cell=1  amount_mol=1.1539999579320571e-7
  water_m3=7.061016156018221e-3  fraction=0e0  zero_cause=fraction
```

Three things this settles immediately:

1. **It is not a water problem.** `water_m3 = 7.06e-3` is healthy. The error's name is actively misleading -- `concentration()` raises the same error for `fraction == 0` as for `water_m3 == 0`, and the cause here is the **fraction**.
2. **It is the ammonium band specifically**, not nitrate, not phosphate, not the non-band domain.
3. **The stranded amount is a trace**: 1.154e-7 mol, just above the function's own `1e-12` tolerance. This is residue left behind, not a bulk mass error.

## The legacy behaviour, in the source's own words

`hour1.f:4962` names the operation:

```fortran
C     AMALGAMATE NH4 BAND WITH NON-BAND IF BAND NO LONGER EXISTS
      ELSE
      FVLNH4(L,NY,NX)=0.0            ! :4965  geometry
      DPNHB(L,NY,NX)=0.0             ! :4966  geometry
      WDNHB(L,NY,NX)=0.0             ! :4967  geometry
      VLNH4(L,NY,NX)=1.0             ! :4968  geometry
      VLNHB(L,NY,NX)=0.0             ! :4969  geometry
      ZNH4S(L,NY,NX)=ZNH4S(L,NY,NX)+ZNH4B(L,NY,NX)      ! :4970  INVENTORY
      ZNH3S(L,NY,NX)=ZNH3S(L,NY,NX)+ZNH3B(L,NY,NX)      ! :4971  INVENTORY
      ZNH4B(L,NY,NX)=0.0                                 ! :4972  INVENTORY
      ZNH3B(L,NY,NX)=0.0                                 ! :4973  INVENTORY
      XN4(L,NY,NX)=XN4(L,NY,NX)+XNB(L,NY,NX)             ! :4974  INVENTORY
      XNB(L,NY,NX)=0.0                                   ! :4975  INVENTORY
      ZNH4FA(L,NY,NX)=ZNH4FA(L,NY,NX)+ZNH4FB(L,NY,NX)    ! :4976  INVENTORY
      ZNH3FA(L,NY,NX)=ZNH3FA(L,NY,NX)+ZNH3FB(L,NY,NX)    ! :4977  INVENTORY
      ZNHUFA(L,NY,NX)=ZNHUFA(L,NY,NX)+ZNHUFB(L,NY,NX)    ! :4978  INVENTORY
      ZNH4FB(L,NY,NX)=0.0                                ! :4979  INVENTORY
      ZNH3FB(L,NY,NX)=0.0                                ! :4980  INVENTORY
      ZNHUFB(L,NY,NX)=0.0                                ! :4981  INVENTORY
      ENDIF
```

**Five geometry assignments and twelve inventory assignments**, covering six band pools: aqueous ammonium (`ZNH4B`), aqueous ammonia (`ZNH3B`), exchangeable ammonium (`XNB`), and the three fertilizer reserves (`ZNH4FB`, `ZNH3FB`, `ZNHUFB` -- NH4, NH3, urea). Each is added into its non-band counterpart and then zeroed, in the same block that zeroes the volume fraction.

There are exactly three such blocks in the legacy, one per fertilizer family: **NH4 at `:4962`, NO3 at `:5057`, PO4 at `:5148`.**

## What ecosys-ng does: the geometry half only

`management/hourly_fertilizer_band_geometry.zig:278-284` is a faithful, line-for-line port of the **geometry** half:

```zig
} else {
    workspace.band_depth_m[layer] = 0;              // DPNHB  :4966
    workspace.band_width_m[layer] = 0;              // WDNHB  :4967
    workspace.band_volume_fraction[layer] = 0;      // VLNHB  :4969
    workspace.non_band_volume_fraction[layer] = 1;  // VLNH4  :4968
    workspace.band_disappeared[layer] = true;       // <-- the signal is RAISED
}
```

and it publishes that signal deliberately -- `:36` documents `band_disappeared` as *"True where the inactive-band branch requires inventory amalgamation."* The signal is then carried through `management/fertilizer_band_phase_coordinator.zig` and is available per family.

**For nitrate and phosphate the signal is acted on.** `management/fertilizer_band_nitrate_phosphate.zig:123-136`:

```zig
if (nitrate_disposition == .amalgamate)   amalgamateNitrate(inputs.layer_index, nitrate_pools);
if (phosphate_disposition == .amalgamate) amalgamatePhosphate(inputs.layer_index, inputs.salinity_chemistry, phosphate_pools);
```

with `updateGeometry` returning `.amalgamate` at `:157` on exactly the legacy condition. That module's own doc comment states its scope and, crucially, its assumption:

```zig
/// Translates `hour1.f` lines 4992--5200 for one soil layer.
/// Call after the NH4 update for the same layer.
```

`hour1.f:4992-5200` is the **NO3 and PO4** span. The NH4 span ends at `:4983`. **So this module correctly excludes NH4 and explicitly presupposes an NH4 counterpart -- and no such counterpart exists.** Searching the whole tree for `amalgamateAmmonium`, `amalgamate.*ammoni` or `ammoni.*amalgamate` returns **nothing**.

### The defect, stated exactly

> ecosys-ng ports the geometry half of `hour1.f:4964-4982` and raises the `band_disappeared` signal, but **the ammonium family has no consumer for it**. Two of the legacy's three amalgamation blocks were translated; the third -- NH4, which is also the largest at six pools against nitrate's one and phosphate's few -- was not.

So when the ammonium band disappears, the band volume fraction is set to 0 while `ZNH4B`/`ZNH3B`/`XNB`/`ZNH4FB`/`ZNH3FB`/`ZNHUFB` keep whatever they held. `publishMatrix` then divides by that zero fraction and raises.

## Why this is a science gap, not merely a crash

The crash is the *symptom that saved us*. The underlying error is worse:

- **Mass is stranded in a domain that no longer has volume.** The 1.154e-7 mol measured at hour 3,275 is nitrogen the model still believes exists but can never dissolve, take up, nitrify or transport, because every one of those processes scales by the band volume fraction.
- **It affects six pools, not one.** Only aqueous `ammonium_band` trips the guard, because only that pool reaches `concentration()`. Exchangeable ammonium (`XNB`) and the three fertilizer reserves are stranded **silently** -- no guard covers them.
- **It biases nitrogen availability downward** over the whole run: every band closure since simulation start has been quietly discarding its band inventory from the active pools.
- It is invisible to the conservation ledger if that ledger sums band and non-band together, because nothing is created or destroyed -- the nitrogen is merely parked where no process can reach it. That is consistent with the run reaching hour 3,275 with a green conservation record.

## Fix specification, NOT applied

Add the missing NH4 amalgamation as the mirror of `fertilizer_band_nitrate_phosphate.zig`, driven by the same `band_disappeared`/`.amalgamate` signal that already exists:

1. On band disappearance for the ammonium family, for that layer:
   `ammonium_non_band += ammonium_band; ammonium_band = 0` and likewise for ammonia, exchangeable ammonium, and the NH4/NH3/urea fertilizer reserves -- the six pairs at `hour1.f:4970-4981`.
2. Order matters and must match the legacy: the merge happens **in the same step** that zeroes the volume fraction, so no intermediate state has nonzero inventory against a zero fraction.
3. It must run **before** the NO3/PO4 update for the same layer, per `fertilizer_band_nitrate_phosphate.zig:106`'s stated ordering.
4. Regression test: drive a band to disappearance with nonzero inventory in all six pools and assert each non-band pool absorbs exactly its band counterpart, each band pool is exactly zero, and the family total is unchanged to the last bit.
5. Then a production run to confirm hour 3,275 clears, and an output comparison, since this changes nitrogen availability from the first band closure onward and will move results.

**Not applied in this step deliberately.** It is a real science change that alters nitrogen availability across the whole run, and the correct sequence is diagnose, file, then fix under review -- `run-013` in this session cost 280 frontier hours by landing plausible science changes without isolating them first.

## Consequence for `issue-090`

`issue-090` corrected the fertilizer-band NO3 **activation** gate and was unit-validated, source-verified and regression-free. `run-021` showed it does not clear the frontier. This issue explains why: the frontier failure is in ammonium band **deactivation**, a different half of the machinery in a different family. `issue-090` should be re-dispositioned **correct-but-not-causal** rather than reopened.

## Reproduction

```
zig build -Doptimize=ReleaseSafe            # ReleaseSafe is readable; see issue-091
# instrument concentration() at mineral_nitrogen_transport.zig:671 to log species/cell/fraction
<binary> --threads 1 runottawa              # fresh deck, no checkpoints; ~9 min to hour 3,275
uv run ecosys-audit/scripts/f77query.py show f77src/hour1.f --lines 4948-4998   # the NH4 block
uv run ecosys-audit/scripts/f77query.py grep 'AMALGAMATE'                        # all three blocks
```

**Limitations.** The instrumented figure is from a **single** run, and the diagnostic reports only the first failing `(species, cell)` -- other layers or pools may also be stranded at that hour and would not appear. The claim that the five non-aqueous pools are stranded silently is **inferred from the source structure, not measured**: no guard covers them, so nothing would report it. The statement that this has biased nitrogen availability since the first band closure is likewise structural inference -- **the cumulative magnitude has not been quantified**, only the 1.154e-7 mol present in one pool in one layer at one hour. `f77query.py` "does not compile the model, prove equivalence, or decide a gate".
