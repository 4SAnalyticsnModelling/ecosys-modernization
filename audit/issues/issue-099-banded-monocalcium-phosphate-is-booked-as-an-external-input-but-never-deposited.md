# Issue 099 -- the day-137 banded monocalcium phosphate application is booked as an external input but never deposited, failing hourly conservation on phosphorus and calcium

Status: **OPEN, CONFIRMED BY PRODUCTION RUN, INPUT POSITIVELY IDENTIFIED (filed 2026-09-22, adversarial Claude/Pi session).** This is the hour-3,275 frontier blocker that `issue-098`'s nitrogen abort was masking -- see `audit/runs/run-022-...md`.

## The measurement

`run-022`, first run with `issue-098`'s fold applied. The nitrogen abort is gone; hour 3,275 now fails here:

```
error: hourly cell conservation failure: cell=2 quantity=phosphorus
  before=4.1385007653583244e1  after=4.138512614717944e1
  external_inputs=5.000454772802566  external_outputs=3.3627920637213936e-4
  internal_production=0  internal_consumption=0
  residual=-4.9999999999999964  normalized_relative=9.998418146247833e-1
  effective_limit=5.000908115323741e-9

error: hourly cell conservation failure: cell=2 quantity=calcium
  before=1.6835573903075448e2  after=1.6835567715446925e2
  external_inputs=8.161072354057172e-2  external_outputs=1.0274385355498689e-3
  residual=-8.064516129025165e-2  normalized_relative=9.758828035885635e-1
  effective_limit=8.312066937640322e-11
```

**The signature is unambiguous: the residual is almost exactly minus the external input**, in both rows.

| quantity | external input | residual | storage change |
|---|---|---|---|
| phosphorus | 5.000454772802566 | **-4.9999999999999964** | +1.185e-4 |
| calcium | 8.161072354057172e-2 | **-8.064516129025165e-2** | -6.188e-5 |

The ledger counts ~5.0 units of P and ~0.0816 of Ca arriving in cell 2, and the cell's storage does not change by anything like that. Both residuals are 8-9 orders of magnitude outside their effective limits, so this is not a tolerance question -- **the input is accounted and not applied.**

## The input is positively identified

`hour1.f:241-242` gives the fertilizer field layout:

```fortran
PMA=FERT( 9,I,NY,NX)     ! broadcast monocalcium phosphate
PMB=FERT(10,I,NY,NX)     ! BANDED  monocalcium phosphate
```

and the deck's day-137 banded line (`f77example/Cool Temperate Maize-Soybean ON/f25fr98`) is

```
17051998  0  0  0  0  1.65  0  0  0  0  5.0  0 ... 0.05  0.76  1  0  0
                                        ^^^ field 10 = PMB = 5.0
```

`5.0` against a booked phosphorus input of `5.000454772802566` -- four significant figures, with the small excess consistent with other P sources in the hour. Monocalcium phosphate is `Ca(H2PO4)2.H2O`, so it carries calcium, which accounts for the second row. The same line's `0.05` and `0.76` are the application depth and row spacing that `issue-090`'s test pins as `(0.025/0.76)*(0.025/0.05) = 0.01644736842105263`, and `run-021` measured exactly that band fraction at **cell 2** -- the cell that fails here.

**So: the day-137 banded monocalcium phosphate application books its phosphorus and calcium as external inputs but does not deposit them into cell 2's inventory.**

> ## ROOT CAUSE, MEASURED: the deposit precedes the hour's conservation baseline, while its input is booked inside the window
>
> The census was instrumented at its own read. It reads the deposit **perfectly** -- 7 passes
> during the failing hour, every one identical:
>
> ```
> census_read: profile_cell=2 cell=0 layer=2 banded_mol=8.064516129032258e-2 pending_phosphate_g=5e0
> ```
>
> > **CAVEAT I have to flag against my own conclusion.** That diagnostic fired only when
> > `banded_monocalcium_phosphate_mol != 0`, so **a census pass that read zero produced no
> > line at all.** "Seven passes, all 5.0" therefore does *not* establish that the *before*
> > pass saw 5.0 -- a zero-reading before-pass would have been silent, and that is precisely
> > the case that would refute the ordering conclusion. The diagnostic has been changed to log
> > unconditionally for `profile_cell == 2`, and **the ordering claim below is not established
> > until that rerun shows no zero-reading pass.** Stated here rather than left implicit
> > because this issue has already had six wrong mechanisms and an under-determined seventh is
> > not an improvement.
>
> So the complete chain is now measured end to end and **every component is correct**:
>
> | step | measured | correct? |
> |---|---|---|
> | booking (preflight) | hour 3,275, cell 0, 5.0 g P | yes |
> | deposit | hour 3,275, `soil_index = 2`, 8.064516129032258e-2 mol | yes |
> | booking (accumulate) | hour 3,275, cell 0, 5.0 g P, not double-counted | yes |
> | census read | `profile_cell = 2`, 8.064516129032258e-2 mol -> **5.0 g P** | yes |
>
> **And yet `before = 4.1385007653583244e1` and `after = 4.138512614717944e1`.** The census
> contributes 5.0 g P on every pass it made during that hour, including the first. Therefore
> the 5.0 is present in **both** the before and the after snapshot -- which is only possible if
> **the deposit executed before the hour's baseline was captured**, while its external-input
> booking is attributed to that same hour. Hence `residual = -external_input` exactly.
>
> ### Why the six readings all failed
>
> Every one of them asked "is this component wrong?" and every component is right. The defect
> is in the **relative order** of two correct operations, which no amount of reading a single
> module can reveal. Note that I twice inferred ordering from **line numbers** in
> `ecosys_ng.zig` (`:6760` baseline before `:7185` fertilizer) and was wrong both times --
> those are calls in different functions, so source order is not execution order. The
> measurement settled in one run what six readings could not.
>
> ### Fix direction
>
> Either capture the hour's conservation baseline **before** the fertilizer stage runs, or
> attribute the external-input booking to the hour whose baseline precedes the deposit. The
> first is almost certainly right, since the ledger `reset()` at `ecosys_ng.zig:6853` already
> carries a comment scoping activity to "exactly one fixed external hour" -- the baseline
> should share that scope.
>
> **Not applied.** It moves a validation baseline that all ten quantities are checked against,
> so it needs its own review pass and a full-suite plus production cycle. **Confirm the call
> order directly first** -- by logging the baseline capture alongside the deposit -- rather
> than relying on the inference above, sound as it is: this issue has already had six wrong
> mechanisms and the last thing it needs is a fix built on a seventh inference.
>
> ## SUPERSEDED: the deposit DOES happen, in the right hour and the right slot -- the defect is in the census READ
>
> Instrumented all three points of the cell-scope booking path and ran `ReleaseSafe` to the
> frontier. Every marker fires in the **same hour**:
>
> ```
> fert_preflight:  hour=3275 cell=0 phosphorus_g_p=5e0 calcium_mol=8.064516129032258e-2
> fert_deposit:    cell=0 layer=2 soil_index=2 phosphorus_g_p=5e0
>                  banded_monocalcium_mol=8.064516129032258e-2
> fert_accumulate: hour=3275 cell=0 phosphorus_g_p=5e0 calcium_mol=8.064516129032258e-2
> ```
>
> **What this establishes:**
>
> 1. **The deposit happens**, at `soil_index = 2` (= `cell 0 * layer_capacity + layer 2`), with
>    the correct magnitude: `8.064516129032258e-2 mol x 62 g/mol = 5.0 g P` exactly. So every
>    hypothesis about a lost, uncommitted or mis-layered deposit is dead -- including my own
>    first one, withdrawn below.
> 2. **The booking happens twice by design** -- `preflight` before the owners mutate and
>    `accumulate` after they accept -- both at `cell=0`, both 5.0 g P. The ledger reports
>    `external_inputs = 5.000454772802566`, i.e. **one** 5.0 plus a small other P source, so
>    the two are not double-counted.
> 3. **The hour is right.** All three at 3,275, the same hour the conservation check fails.
>
> **So the input arrives, the mass is deposited, and the census still reports scope 2's
> phosphorus storage rising by only `+1.185e-4` instead of `+5.0`.** The defect is therefore in
> the **census read path**, not in the application.
>
> ### The specific suspicion: an index mismatch between deposit and census
>
> The deposit writes `state.soil[soil_index]` with `soil_index = cell * layer_capacity + layer
> = 0 * 12 + 2 = 2`. The census reads `pending_fertilizer.soil[profile_cell]`
> (`landscape_mass_inventory_phosphorus_ions.zig:383`). **If `profile_cell` is not the same
> index as `soil_index`** -- for instance if it is a profile-relative index offset by
> `first_profile_layer`, or a scope index rather than a `cell * capacity + layer` flat index --
> the census reads a different slot than the deposit wrote, and the 5.0 g P is invisible while
> sitting in memory.
>
> Note the booking is keyed on **grid cell 0** while the failure is reported at **scope 2**, so
> there is a cell-to-scope mapping in the ledger that is also worth checking.
>
> **That suspicion is also refuted.**
> `landscape_mass_inventory_phosphorus_ions.zig:260` computes
> `const profile_cell = cell * grid.soil_layer_capacity + layer;` -- **identical** to the
> deposit's `soil_index = cell * state.layer_capacity + layer`. Same slot.
>
> ### Six mechanisms checked, all refuted. Every static path is correct.
>
> | # | mechanism | refuted by |
> |---|---|---|
> | 1 | the reserve has no census `StorageOwner` | `layer_mass_inventory.zig:93-107` + `..._phosphorus_ions.zig:385-388` sum it, units reconcile `/62` and `31x2` |
> | 2 | the staged `next_soil` deposit is never committed | `mineral_fertilizer_inventory.zig:109-110` commits after validating |
> | 3 | deposit and booking target different layers | deposit uses `layerAtDepth(0.05)` = layer 2, the failing layer |
> | 4 | the sidecar's event gate has no hour component | `isApplicationHour` at `:161`, identical in all four paths |
> | 5 | the sidecar books before the deposit (ordering) | that ordering is documented as deliberate (`ecosys_ng.zig:7181-7184`), and the sidecar feeds the **layer** ledger, not the cell one |
> | 6 | the cell census omits the reserve, unlike the layer census | `landscape_mass_balance_runtime.zig:178,187,337,347` wire `mineral_fertilizer` in |
>
> And the run itself confirms the application end is sound: preflight, deposit and accumulate
> all fire at hour 3,275, at the right slot, with the right magnitude, without double-counting.
> The baseline is also captured in the right place -- `reconstructLayerMassBalanceScopes` at
> `ecosys_ng.zig:6760`, **before** the fertilizer stage at `:7185-7302` -- so the deposit is not
> pre-baked into `before`.
>
> ### Where that leaves it
>
> Booking, deposit, index, gate, ordering, census wiring and baseline placement are each
> individually correct, and yet `before = 4.1385007653583244e1` rises only to
> `4.138512614717944e1` when 5.0 g P was deposited into the very slot the census reads.
>
> **So the next measurement must be on the census itself, not the application.** Log, at scope
> 2, the census's own `pending.banded_monocalcium_phosphate_mol` reading and its
> `phosphate_phosphorus_g` contribution, in both the before and after passes. That is the one
> place not yet observed, and after six refutations it is the only honest way to proceed --
> every further guess from reading has been wrong.
>
> **Six wrong mechanisms is itself a finding about method**: this defect sits in a path where
> each component is locally correct, which is exactly the shape that static reading cannot
> resolve and instrumentation can. The two instrumented runs in this issue each produced a
> decisive fact; the six readings produced none.
>
> ## SUPERSEDED (but now partly rehabilitated): the reserve IS counted by the census -- the question is at WHICH INDEX
>
> I concluded that the undissolved fertilizer reserve has no census `StorageOwner` and is
> therefore invisible. **That is false**, and I reached it by reading the `StorageOwner` enum
> and stopping there instead of following the census's actual summation.
>
> `validation/layer_mass_inventory.zig:93-107` passes `inputs.mineral_fertilizer` into the
> **soil** per-layer phosphorus aggregation, and
> `validation/landscape_mass_inventory_phosphorus_ions.zig:383-388` sums the reserve
> explicitly:
>
> ```zig
> const pending = pending_fertilizer.soil[profile_cell];
> result.phosphate_phosphorus_g += phosphorus_g_per_mol *
>     (2 * (pending.broadcast_monocalcium_phosphate_mol +
>         pending.banded_monocalcium_phosphate_mol) +
>         3 * pending.hydroxyapatite_mol);
> ```
>
> **And the units reconcile exactly across all three sites**, which is the strongest evidence
> that these are meant to be the same mass and are not mismatched:
>
> | site | expression | unit |
> |---|---|---|
> | booking, `fertilizer_management_dispatch.zig:266` | `p.banded_monocalcium_phosphate * area_m2` | g P |
> | deposit, `mineral_fertilizer_inventory.zig:91` | `... * cell_area_m2 / 62.0` | mol Ca(H2PO4)2 |
> | census, `..._phosphorus_ions.zig:385-388` | `31 * 2 * mol` | g P |
>
> `62.0` in and `31 x 2 = 62` out. Consistent. So `aqueous_and_mineral_species` does cover the
> mineral fertilizer reserve, and my inference from the enum's member names was unfounded.
>
> ### Where the investigation actually stands
>
> Booking, deposit and census all exist and agree on units and magnitude. So the defect is in
> **which** slot is written or read, not whether one exists. The leading candidates, neither
> verified:
>
> 1. **The deposit is staged and not committed.** `mineral_fertilizer_inventory.zig:91` writes
>    `next_soil.banded_monocalcium_phosphate_mol += ...` -- a `next_*` staged structure. If it
>    is not committed to live state, or committed after the census snapshot, the census reads
>    the pre-deposit value. This is the same *class* as `issue-098`'s scratch-buffer finding,
>    and that precedent makes it the first thing to check.
> 2. **The deposit lands in a different layer than the booking.** The booking is per cell; the
>    deposit resolves a layer from `application_depth_m = 0.05` via
>    `fertilizer_nitrogen_inventory.applicationLayer`. A layer mismatch would produce a deficit
>    in one layer and a surplus in another, and the run reports only the first failure, so a
>    compensating surplus elsewhere would not appear in the log.
>
> Both were then checked and **both are refuted**:
>
> 1. **Not a staging failure.** `mineral_fertilizer_inventory.zig:109-110` commits it --
>    `state.soil[soil_index] = next_soil; state.surface[cell] = next_surface;` -- after
>    validating at `:104-105`. The `next_*` names are a validate-then-commit idiom, not a
>    dropped write.
> 2. **Not a layer mismatch.** The deposit resolves its layer as
>    `layerAtDepth(active_layer_thickness_m, event.application_depth_m)` (`:72-73`) with
>    `application_depth_m = 0.05`, which is layer 2 -- the same layer that fails, and the same
>    layer where `run-021` measured the active band.
>
> ### THIRD hypothesis also refuted: the sidecar DOES have an hour gate, and it is the same one
>
> I claimed the sidecar's event loop gates on day/month/year but never the hour. **Wrong
> again** -- I read the inner event loop and missed the enclosing gate.
> `fertilizer_management_dispatch.zig:161-165`:
>
> ```zig
> for (0..self.cell_count) |cell| {
>     if (!try isApplicationHour(source_hour_one_through_twenty_four, solar_noon_hour_by_cell, cell)) continue;
> ```
>
> and **every** path uses the identical gate -- the sidecar at `:161`, `applyNitrogen` at
> `:439`, `applyMinerals` at `:517`, `applyOrganic` at `:546`. The hour selection is
> consistent by construction, and `reconstructAcceptedHour` also `reset()`s first (`:159`), so
> it does not accumulate across hours either.
>
> ### What the evidence now forces: an ORDERING defect within the hour
>
> Three mechanisms are refuted, and the remaining evidence is specific:
>
> - the sidecar books 5.0 g P at hour 3,275;
> - the run's own census reports `fertilizer_application entries=2 ... last_hour=3252`, so the
>   **deposit did not happen** at 3,275;
> - yet both gates are identical, so if the sidecar's gate passed, the deposit's would too.
>
> The only way both hold is that **`applyMinerals` is not reached before the conservation check
> runs** -- the sidecar reconstructs and books, the check evaluates, and the science path
> deposits later in the hour (or the run aborts first). That is an ordering defect between the
> local-conservation sidecar and the mineral application, not a gate or a wiring fault.
>
> It also explains why day 136 passed: that application was **broadcast urea**, a nitrogen
> species on `applyNitrogen`'s path, which may sit at a different point in the hour than
> `applyMinerals`. The failing quantities are phosphorus and calcium -- `applyMinerals`'
> species exclusively.
>
> ### FOURTH refinement: the sidecar's ordering is intentional, and it feeds a DIFFERENT scope
>
> The ordering hypothesis above is also not it, and the search is narrower than I had it.
> `ecosys_ng.zig:7181-7184`, immediately above the sidecar call, states the design:
>
> ```
> // Resolve every accepted event to the actual litter or
> // depth-selected soil owner before any of the three
> // fertilizer mutations. This producer sidecar is only
> // published to the local ledger after all owners accept.
> ```
>
> So reconstructing at `:7185` *before* the three mutations (`:7250` nitrogen, `:7260`
> minerals, organic after) is deliberate, and publication is deferred until the owners accept.
> Reading the line order as the failure was wrong.
>
> **And the scopes differ.** That sidecar publishes to the **layer-local** ledger
> (`layer_local_conservation`). The failing error is **`HourlyCellConservationFailure`** -- the
> **cell** scope, with its own producer. So `reconstructAcceptedHour` is very likely not the
> booking that appears in this failure at all, and the four mechanisms I have chased were all
> in the wrong module.
>
> **Narrowed target for the measurement**: find which producer supplies
> `ExternalProducer.fertilizer` to the *cell*-scope census, and compare its hour and quantity
> against `applyMinerals`' deposit. That is a much smaller search than the whole fertilizer
> dispatch.
>
> ### Stop hypothesising; take the measurement
>
> I have now had three mechanisms refuted in a row by reading one level further each time.
> That is a signal to stop reasoning from static reading. The measurement is one ~10-minute
> `ReleaseSafe` run logging, with the hour, a marker at: (a) the sidecar's booking, (b)
> `applyMinerals`' deposit, (c) the hourly conservation evaluation. The **order** of those
> three lines within hour 3,275 settles it outright.
>
> ### SUPERSEDED second hypothesis: the conservation sidecar has no hour gate
>
> `management/fertilizer_management_dispatch.zig:182-194`, inside
> `LocalActivityState.reconstructAcceptedHour` (`:135`, with a `reset` at `:127`):
>
> ```zig
> for (catalog.entries.items[schedule_index].events) |event| {
>     if (event.date.day != date.day or event.date.month != date.month or
>         (!event.date.isRecurring() and event.date.year != date.year)) continue;
>     const routed = try eventRoutedActivity(event, area_m2, carbon_g_per_mol, cover_fraction, thickness);
>     try self.surface_by_cell[cell].add(routed.surface);
>     try self.soil_by_layer[first + routed.soil_layer].add(routed.soil);
> }
> ```
>
> **The event gate tests day, month and year -- never the hour.** So a function whose own name
> is "reconstruct *accepted hour*" attributes a once-per-day application to **every hour of
> that day**, while `mineral_fertilizer_inventory.applyMineral` deposits it once. The comment
> at `:199` confirms this is "the local-conservation sidecar", i.e. an accounting path, not the
> science path.
>
> ### The tension that stops this being a conclusion
>
> If the sidecar booked 5.0 in *every* hour of day 137, the check should fail on the **first**
> such hour. Day 137 spans hours 3,265-3,288 and the failure is at **3,275**, ten hours in.
> Two readings, and I cannot separate them from the runs I have:
>
> - the application dispatch fires at hour 3,275 specifically, so this is its first hour; or
> - the sidecar books an event the science path has **not yet applied** -- an ordering defect.
>   This would also explain the standing oddity that the run's own census reports
>   `fertilizer_application entries=2 ... last_hour=3252`, i.e. no day-137 application
>   dispatched, while `run-021` measured an **active band** at layer 2 whose fraction
>   (1.6447e-2) can only come from day 137's `0.76` row spacing.
>
> ### The one measurement that settles it
>
> Log, for each hour of day 137: the routed fertilizer activity the sidecar books, the
> `banded_monocalcium_phosphate_mol` reserve value, and whether the application dispatch fired.
> One ~10-minute `ReleaseSafe` run. **No fix should be attempted before that** -- this issue
> has already had one wrong root cause from me, and the hour-3,275-vs-3,265 gap is exactly the
> kind of detail that distinguishes a real mechanism from a plausible one.
>
> The original text is retained below for the reasoning trail. Read it as refuted.
>
> ## WITHDRAWN root cause: the undissolved fertilizer reserve is not a census-visible storage pool
>
> The title's "never deposited" is **wrong** -- it *is* deposited. It is deposited somewhere
> the conservation census cannot see.
>
> **The deposit happens.** `management/mineral_fertilizer_inventory.zig:91`:
>
> ```zig
> next_soil.banded_monocalcium_phosphate_mol += p.banded_monocalcium_phosphate * cell_area_m2 / 62.0;
> ```
>
> **The booking happens.** `management/fertilizer_management_dispatch.zig:266-267`:
>
> ```zig
> result.soil.phosphorus_g_p += p.banded_monocalcium_phosphate * area_m2;
> result.soil.calcium_mol += banded_monocalcium_mol;
> ```
>
> and `ExternalProducer` in the census includes `fertilizer` (`validation/hourly_cell_conservation.zig`), so that input is counted.
>
> **But the pool it lands in has no storage owner.** The census's `StorageOwner` enum has
> exactly ten members -- `water_phases`, `thermal_energy`, `soil_litter_gases`,
> `aqueous_and_mineral_species`, `residue_som_and_microbes`, `surface_litter_organic`,
> `living_plant_carbon`, `living_plant_nitrogen`, `living_plant_phosphorus`,
> `soil_mineral_texture` -- and **none of them is the undissolved fertilizer reserve**.
> Phosphorus storage is `storage_elements | storage_organic | storage_plant_p` (`:201`), where
> `storage_elements = enumMask(.{StorageOwner.aqueous_and_mineral_species})` (`:155`). That
> owner covers the *dissolved and mineral chemistry* state -- `chemistry.phosphate_minerals`
> and `chemistry.band_phosphate` -- which is what the reserve dissolves **into**
> (`mineral_fertilizer_inventory.zig:183-227`), not the reserve itself.
>
> ### The complete mechanism
>
> 1. The application books ~5.0 g P and ~0.0816 mol Ca as external inputs under
>    `ExternalProducer.fertilizer`.
> 2. The mass is deposited into `banded_monocalcium_phosphate_mol`, an **undissolved reserve**.
> 3. That reserve has no `StorageOwner`, so the census's storage total does not include it.
> 4. The mass becomes census-visible only later, as it dissolves into
>    `chemistry.band_phosphate` / `phosphate_minerals`.
> 5. **In the hour of application: input booked, storage unchanged, so
>    `residual = -external_input` exactly.**
>
> That is why the residual matches the input to fifteen digits rather than approximately: the
> entire input went somewhere the census structurally cannot count.
>
> ### Why it surfaces only now
>
> The two earlier applications in this deck both went through **different** paths, which is why
> neither tripped it:
>
> | event | field | species | path |
> |---|---|---|---|
> | `15041998` (hour ~2,508) | `FERT(12) = 360.0` | **CaCO3 lime**, g Ca m-2 (`hour1.f:251`, `CAC`) | books C and Ca via `dispatch:269-272`'s `calcite_mol`, **not** the phosphate reserve |
> | `16051998` (hour ~3,252) | `FERT(3) = 13.8` | **broadcast urea** (`ZUA`, `hour1.f:229`) | a nitrogen reserve, but urea is highly soluble and clears within the application hour |
> | `17051998` (hour ~3,275) | `FERT(10) = 5.0` | **banded monocalcium phosphate** (`PMB`) | the reserve, and it dissolves slowly |
>
> So my earlier guess that broadcast `PMA` had been silently violating conservation since day
> 105 was **wrong** -- day 105 was lime, and this deck applies no broadcast monocalcium
> phosphate at all in 1998.
>
> The refined statement: **the reserve is census-invisible, but the violation only surfaces
> when the reserve persists past the application hour.** A highly soluble species clears
> within the hour and the census never sees a gap; a sparingly soluble one like monocalcium
> phosphate does. That makes this a **latent defect in every deck**, surfacing only on a
> slow-dissolving application -- which is a worse property than a consistently failing one,
> because it passes most decks.
>
> **Still not established**: whether the nitrogen reserves would fail the same way on a
> slow-dissolving N species, and whether any deck in the shipped set applies one. That is the
> generalisation to check.
>
> ### Fix direction
>
> **Add the undissolved fertilizer reserve as a census storage owner.** The mass is genuinely
> in the cell from the moment it is applied, so the census should see it; the booking is
> correct and must not be deferred to dissolution. That means a new `StorageOwner` member, its
> inclusion in the `phosphorus`, `nitrogen` and `calcium` storage masks, and a census
> contribution that sums the `mineral_fertilizer_inventory` and
> `fertilizer_nitrogen_inventory` reserves.
>
> **Not applied.** It changes a validation invariant that every other quantity's mask is
> checked against, so it needs its own review pass rather than being appended to this session.
> The nitrogen reserves are in the same position and would need the same treatment, which is
> exactly the kind of shared-state change the contract says invalidates every dependent check.

## Where it is not

Checked, to keep the search honest:

- **Not** `soil_chemistry_convergence.zig`'s discarded scratch pools. `issue-098` established that 40 of those 46 arrays are phosphorus-family and are never read back -- but the monocalcium phosphate pair is handled in a **different** module, `management/fertilizer_band_production.zig`, which stages it at `:235-236` and **does** write it back at `:257-258`. Those two findings are adjacent but not the same fault, and conflating them would be wrong.

## Next bounded action

1. Find the code that books the phosphorus/calcium external input for a banded application, and the code that should deposit `PMB` into the layer inventory, and establish which of the two runs without the other. The booking side is the more likely place to look first, since a deposit that silently no-ops would more often show up as a plain mass loss rather than as a booked input.
2. Check whether the **broadcast** counterpart (`PMA`, `FERT(9)`) has the same defect. This deck applies broadcast monocalcium phosphate on other dates, so if both are affected the loss has been accumulating far earlier than day 137 and simply never breached a conservation limit.
## Checked against the reference register first (`issue-097`'s lesson)

The **error class has precedent; this instance and mechanism do not.**
`discrepancy_register.md` carries 14 `HourlyCellConservationFailure` hits and 4
`quantity=phosphorus` ones, but the recorded case is a different event:

| | register entry | this issue |
|---|---|---|
| hour | 2,657 accepted / 2,658 attempted | **3,275** |
| cells | 0 and 17 | **2** |
| `external_inputs` | 2.0844784845505646e-9 (and 1.098e-4) | **5.000454772802566** |
| signature | small storage loss against a negligible input | **residual almost exactly minus a large booked input** |

So the register's phosphorus failure is a mass *leak*; this one is an input *never applied*. The 23 `monocalcium` hits are about phosphate chemistry generally, and the single `PMB` hit is `VOLPMB`, a band **air volume** in the ammonia volatilisation discussion -- unrelated to `FERT(10)`.

The precedent is still useful: it shows `HourlyCellConservationFailure` on phosphorus has been reached before from a different cause, so the guard is known to be live and trustworthy rather than newly suspect.

## Reproduction

```
zig build -Doptimize=ReleaseSafe          # ReleaseSafe is readable; issue-091
<binary> --threads 1 runottawa            # fresh deck, no checkpoints; ~9.5 min to hour 3,275
uv run ecosys-audit/scripts/f77query.py grep 'FERT\('     # field layout, hour1.f:227-243
```

**Limitations.** Single run, no repeat. The conservation numbers are quoted verbatim from the run's own ledger and were not independently recomputed. The `5.0` identification is a four-significant-figure numeric match plus a corroborating band fraction and species chemistry -- strong, but the fertilizer parse on the ecosys-ng side has **not** been read, so it remains an identification rather than a traced path. Nothing here changes gate status; `check_gate.py` owns that, and the run still stops at 1.25% of the horizon.
