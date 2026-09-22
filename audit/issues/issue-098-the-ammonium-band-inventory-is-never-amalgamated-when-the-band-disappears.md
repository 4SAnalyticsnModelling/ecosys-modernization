# Issue 098 -- the AMMONIUM band inventory is never amalgamated when the band disappears, stranding nitrogen in a zero-volume domain: this is the hour-3,275 frontier blocker

Status: **OPEN, ROOT CAUSE OF THE FRONTIER FAILURE, CONFIRMED BY INSTRUMENTED REPRODUCTION AND SOURCE ON BOTH SIDES. ESCALATED SAME DAY -- ALL THREE legacy amalgamation blocks are ineffective, not just ammonium (filed 2026-09-22, adversarial Claude/Pi session).** Fix specified below and deliberately not applied in the same step as the diagnosis.

> ## ESCALATION: the nitrate and phosphate amalgamations are ALSO dead -- they write to discarded scratch
>
> While locating the right place to add the ammonium amalgamation, the existing nitrate and
> phosphate ones turned out to be **ineffective in production**, by a different mechanism.
>
> In `stages/soil_chemistry_convergence.zig`, the pool arrays handed to
> `fertilizer_band_nitrate_phosphate.updateLayer` are **scratch**:
>
> ```zig
> const nitrate_nonband_pools = try scratch_allocations.alloc(f64, active_layer_count);   // :764
> ...
> nitrate_nonband_pools[local_layer] = nitrate_nonband_g_n;                               // :899  filled FROM state
> ...
> try ecosys.fertilizer_band_nitrate_phosphate.updateLayer(.{...},
>     &nitrate_geometry_for_update, &nitrate_pools,
>     &phosphate_geometry_for_update, &phosphate_pools);                                  // :1016-1039  amalgamates them
> ```
>
> and **no `_pools[` reference exists anywhere after `:1016`** -- the enclosing loops close at
> `:1040-1042` and the function ends. The merged values are never written back to state.
>
> **The asymmetry is the damning part, and it is inside a single call.** The *geometry*
> arguments are **live**: `nitrate_geometry = try context.fertilizer_band.geometry(...)`
> (`:717`) is an accessor into the persistent band state, so
> `nitrate_geometry.band_depth_m[0..active_layer_count]` (`:950`) is a live slice and
> `updateGeometry`'s `geometry.band_volume_fraction[index] = 0.0`
> (`fertilizer_band_nitrate_phosphate.zig:156`) **persists**. So within the same
> `updateLayer` call:
>
> | half | argument | effect |
> |---|---|---|
> | geometry -- zeroes the band volume fraction | live state slice | **persists** |
> | inventory -- merges band pools into non-band | scratch buffer | **discarded** |
>
> That is precisely the ammonium defect reproduced for nitrate and phosphate: the fraction
> goes to zero and the inventory stays where it was.
>
> **So all three legacy amalgamation blocks are ineffective**: NH4 (`hour1.f:4962`) has no
> implementation at all; NO3 (`:5057`) and PO4 (`:5148`) have one whose writes are thrown away.
>
> ### Blast radius, counted
>
> Every pool array reaching `updateLayer` is scratch. Enumerating
> `const <name>_pools = try scratch_allocations.alloc(...)` in
> `stages/soil_chemistry_convergence.zig`:
>
> | | count |
> |---|---|
> | pool arrays allocated from scratch | **46** |
> | -- nitrogen family (nitrate, nitrite, fertilizer-nitrate x non-band/band) | 6 |
> | -- phosphorus family (20 species x non-band/band) | 40 |
> | reads of any `*_pools[` after the `updateLayer` call at `:1016` | **0** |
>
> So the discarded merge covers **23 band/non-band species pairs** -- 3 nitrogen and 20
> phosphorus. Adding the 6 ammonium-family pairs that have no implementation at all, **29
> band/non-band pool pairs have an ineffective amalgamation on band disappearance.**
>
> A sweep of the whole tree finds `scratch_allocations.alloc`/`scratch.alloc` at 76 sites in
> only 4 files, 56 of them in this one file, so the exposure is concentrated rather than
> systemic. The other three files (`constant_forcing_steady_state.zig` 16,
> `hourly_heat_water_solute.zig` 3, `heat_step.zig` 1) were **not** audited for the same
> pattern and should be.
>
> ### Why the tests did not catch it
>
> `fertilizer_band_nitrate_phosphate.zig:362` is a test named *"amalgamation transfers nitrate
> and salinity phosphate pools"*, and it passes. It exercises `updateLayer` as a pure function
> against caller-supplied arrays and correctly asserts the transfer. **The function is right;
> the wiring is wrong.** A unit test of a pure mutator cannot see that production hands it
> scratch memory. This is the same "unit-testable but production-dead" shape as `issue-096`'s
> identically-false comparison, and it is worth generalising: **for any kernel that mutates
> caller-supplied buffers, the audit needs a check that the production call site passes live
> state.** Neither a unit test nor a conservation ledger will report it -- the ledger sees
> nothing created or destroyed because the merge simply never happened.
>
> ### Consequence for the fix
>
> The fix is now larger than "add the ammonium mirror". It is:
>
> 1. Write the amalgamated nitrate/phosphate pools **back to state** after `updateLayer`, or
>    pass live slices instead of scratch.
> 2. Add the ammonium amalgamation (six pool pairs, `hour1.f:4970-4981`) with live wiring.
> 3. A **production-path** test for each, asserting the merge is visible in state after the
>    hourly stage -- not only inside the pure function.
>
> ## STEP ZERO RESOLVED: the staging omits the zone fraction, and fixing the write-back alone would inject a large mass error
>
> The convention question is settled by the legacy, which states it six independent times
> (`hour1.f:3826-3858`):
>
> ```fortran
> IF(VLNHB(L,NY,NX).GT.ZERO)THEN
>   CNH4B(L,NY,NX)=AMAX1(0.0,ZNH4B(L,NY,NX)/(VOLW(L,NY,NX)*VLNHB(L,NY,NX)))   ! :3846-3847
>   CNH3B(L,NY,NX)=AMAX1(0.0,ZNH3B(L,NY,NX)/(VOLW(L,NY,NX)*VLNHB(L,NY,NX)))   ! :3848-3849
> ELSE
>   CNH4B(L,NY,NX)=0.0                                                         ! :3851
>   CNH3B(L,NY,NX)=0.0
> ENDIF
> ```
>
> plus `CNO3B`/`CNO2B` over `VOLW*VLNOB` (`:3855-3858`) and `CH2P4`/`CPO4S` over `VOLW*VLPO4`
> (`:3826-3831`). **The convention is unambiguous:**
>
> ```
> concentration = amount / (TOTAL layer water x ZONE volume fraction)
> amount        = concentration x TOTAL layer water x ZONE volume fraction
> ```
>
> **So `mineral_nitrogen_transport.concentration()` is CORRECT** -- it divides by
> `water_m3 * fraction`, exactly matching `:3846-3847`.
>
> **And the staging in `soil_chemistry_convergence.zig` is WRONG.** `:843-844` and `:853-896`
> compute `amount = conc * effective_water_volume_m3`, and
> `fertilizerBandGeometryCarrierM3` (`:111-113`) returns
>
> ```zig
> return if (water_volume_m3 > floor_m3) water_volume_m3 else dry_reference_water_m3;
> ```
>
> -- the **total** layer water (or a dry-reference substitute), with **no zone fraction
> applied anywhere**. Every one of the 46 staged pool amounts is therefore short by a factor
> of its zone fraction, i.e. too large by `1/fraction` relative to the true amount. At the
> band fraction `issue-090` pinned for this deck (0.01644736842105263) a staged **band**
> amount is about **61x** too large; a non-band amount at 0.98355 is about 1.7% too large.
>
> ### Why this is currently latent and why that makes it dangerous
>
> These amounts are computed into scratch and discarded, so today they harm nothing -- wrong
> numbers, thrown away. **But they become active the instant the write-back is added**, which
> is the obvious fix for the escalation above. Adding the write-back alone would take a 61x-too-large
> band amount and merge it into the non-band pool, injecting a very large nitrogen and
> phosphorus mass error across 23 species pairs. **The two defects must be fixed together, and
> the fraction factor must be fixed first.**
>
> ### One more thing the legacy settles
>
> `:3845`/`:3850-3852` show the legacy's behaviour when the zone fraction is zero: **report a
> zero concentration, raise nothing.** ecosys-ng's `MineralNitrogenInZeroWaterDomain` is
> therefore **stricter than the source**. That strictness is what exposed this whole chain and
> should be kept -- with the amalgamation working, the case should not arise at all, so a
> guard that fires is genuine information. But it should be recorded as a deliberate
> divergence from `hour1.f:3850`, not assumed faithful.

Genuinely new: `MineralNitrogenInZeroWaterDomain` returns **zero hits** across the 615-file reference documentation tree (`issue-097`), including the 49,801-line `discrepancy_register.md`.

> ## CORRECTION, same day: the amalgamation gap is REAL but it is NOT the cause of the hour-3,275 crash
>
> I framed this issue as "the frontier blocker is the missing ammonium amalgamation". **That
> causal claim is wrong.** The source findings below all stand; the attribution does not.
>
> **The evidence that refutes it.** The instrumented run's own census reports:
>
> ```
> info:     fertilizer_application entries=2 first_hour=2508 last_hour=3252
> ```
>
> Only two fertilizer applications fired before the failure. The deck's `f25fr98` has three
> events, and the **banded** one is `17051998 ... 0.05 0.76 1` -- application depth 0.05 m and
> row spacing **0.76 m**, exactly the pair `issue-090`'s test pins as
> `(0.025/0.76)*(0.025/0.05)`. That is **17 May = day 137 = hours 3,265-3,288**, and the
> census's last application is hour **3,252**, so the banded event **had not fired yet** when
> the run died at hour 3,275. The two that did fire are `15041998` (hour ~2,508) and
> `16051998` (hour ~3,252), and the latter carries `0.0` depth and `0.00` row spacing -- i.e.
> **broadcast**, no band.
>
> Independently: `runottawa:70` is `plant_nutrients,0,0,0,1,1,1,1`, so all three initial band
> volume fractions are **zero** for this deck (`fertilizer_band_state.zig:145-148`), and
> `DRY_CARRIER_TRACE` at hour 2,896 shows `ammonium_non_band_fraction=1e0`.
>
> **So no ammonium band ever existed in this run, and no amalgamation was ever due.**
> `fraction = 0` at hour 3,275 is *correct*. The defect is that `ammonium_band` holds
> 1.154e-7 mol **at all**.
>
> ### The corrected diagnosis: a transformation product arriving in a band that does not exist
>
> This is the **mirror of an already-recorded failure**, documented in this repository at
> `management/fertilizer_management_dispatch.zig:460-464` (my own `issue-090` note):
>
> > *"The NO3 band activates on ANY banded nitrogen, including banded ammonium alone, because
> > banded ammonium nitrifies into the nitrate band zone. A first attempt here gated NO3 on
> > banded nitrate only, and hour 3,276 then failed `MineralNitrogenInZeroWaterDomain` --
> > **nitrification products arriving in a nitrate band whose volume fraction was still
> > zero**."*
>
> Same shape, different family: something deposits ammonium into the **ammonium** band while
> its volume fraction is zero. The magnitude (1.154e-7 mol, about 1.6e-6 g N) is a trace,
> which points at a proportional zone split that adds to the band without checking that the
> band exists, rather than at a bulk mis-routing.
>
> **Open and unidentified: which process makes the deposit.** It is not a banded fertilizer
> application -- none has occurred. Candidates are mineralisation or urea hydrolysis routed by
> zone, or any per-zone split that writes the band term unconditionally. Identifying it needs
> the band amount tracked across the hour, which is the next instrumentation step, not a
> source-reading question.
>
> ### What survives from this issue
>
> Everything except the attribution, and it is worth keeping on its own merits:
>
> | finding | status |
> |---|---|
> | `hour1.f:4962-4982`'s NH4 amalgamation has no ecosys-ng counterpart | **stands** -- source-verified both sides |
> | NO3/PO4 amalgamation writes to scratch and is never read back | **stands** -- 46 arrays, 0 reads after `:1016` |
> | the staging omits the zone fraction (`1/fraction` too large) | **stands** -- settled against `hour1.f:3826-3858` |
> | the closed-form blend fix design | **stands**, and is still the right design |
> | ecosys-ng's guard is stricter than `hour1.f:3850` | **stands** |
> | **this is the hour-3,275 blocker** | **WITHDRAWN** |
>
> These remain a genuine latent science gap: the first time a band *does* collapse -- day 137
> onward in this deck, once the run gets that far -- the inventory will be stranded exactly as
> described. They are simply not what stops the run today.

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

## Revised fix design: a closed-form concentration blend, which avoids the mass-error trap entirely

Resolving step zero yields a simpler and safer fix than the one specified further below, and it supersedes it.

Because amalgamation sets the non-band fraction to exactly **1.0** and the band fraction to **0**, and because the convention is `amount = conc x VOLW x fraction` with `VOLW` common to both zones, the total water volume **cancels**:

```
amount_total      = conc_nb x VOLW x f_nb  +  conc_b x VOLW x f_b
conc_nb_new       = amount_total / (VOLW x 1.0)
                  = conc_nb x f_nb + conc_b x f_b        <-- VOLW cancels exactly
conc_b_new        = 0
```

So for every **concentration-valued** band pool the entire amalgamation is a fraction-weighted blend of the two concentrations, using the fractions **as they stand before being zeroed**:

```zig
non_band = non_band * non_band_fraction + band * band_fraction;
band     = 0;
```

This is the concentration-space equivalent of `hour1.f:4970`, it is exactly mass-conserving by construction, and **it needs no amount staging, no `effective_water_volume_m3`, and no write-back of scratch buffers.** It therefore sidesteps the 1/fraction staging defect completely rather than requiring it to be fixed first.

For **amount-valued** pools (exchangeable ammonium, the three fertilizer reserves) it stays the legacy's plain add:

```zig
non_band += band;
band = 0;
```

**Ordering requirement, now sharper:** the blend must read the fractions *before* `hourly_fertilizer_band_geometry.zig:278-284` zeroes them. That module already retains `old_non_band` for its `relative_non_band_change` computation (`:277`), so the pre-zeroing values are available at exactly the right point.

**What this means for the scratch-buffer defect.** With the blend design, the 46 scratch pool arrays and their missing zone-fraction factor are **not on the fix path at all** -- the nitrate/phosphate amalgamation should be re-expressed as the same blend rather than repaired. The scratch arrays and the `1/fraction` staging error then become dead code to remove, not machinery to correct. That is a materially smaller and lower-risk change than fixing the write-back.

## Original fix specification, SUPERSEDED by the blend design above

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
