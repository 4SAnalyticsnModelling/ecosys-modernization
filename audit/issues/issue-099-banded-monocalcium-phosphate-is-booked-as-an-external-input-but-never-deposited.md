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

> ## THE ROOT CAUSE BELOW IS WRONG -- WITHDRAWN. The reserve IS counted by the census.
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
> Distinguishing them is cheap: log the reserve value per layer immediately before and after
> the application hour. **That is the next step, and no conclusion should be drawn until it is
> done** -- this issue has now had one wrong root cause from me and it should not get a second.
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
