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

## Where it is not

Checked, to keep the search honest:

- **Not** `soil_chemistry_convergence.zig`'s discarded scratch pools. `issue-098` established that 40 of those 46 arrays are phosphorus-family and are never read back -- but the monocalcium phosphate pair is handled in a **different** module, `management/fertilizer_band_production.zig`, which stages it at `:235-236` and **does** write it back at `:257-258`. Those two findings are adjacent but not the same fault, and conflating them would be wrong.

## Next bounded action

1. Find the code that books the phosphorus/calcium external input for a banded application, and the code that should deposit `PMB` into the layer inventory, and establish which of the two runs without the other. The booking side is the more likely place to look first, since a deposit that silently no-ops would more often show up as a plain mass loss rather than as a booked input.
2. Check whether the **broadcast** counterpart (`PMA`, `FERT(9)`) has the same defect. This deck applies broadcast monocalcium phosphate on other dates, so if both are affected the loss has been accumulating far earlier than day 137 and simply never breached a conservation limit.
3. Search the reference `discrepancy_register.md` for this first -- `issue-097`'s lesson. `MineralNitrogenInZeroWaterDomain` returned zero hits there, but this is a phosphorus/calcium conservation failure and may well be recorded.

## Reproduction

```
zig build -Doptimize=ReleaseSafe          # ReleaseSafe is readable; issue-091
<binary> --threads 1 runottawa            # fresh deck, no checkpoints; ~9.5 min to hour 3,275
uv run ecosys-audit/scripts/f77query.py grep 'FERT\('     # field layout, hour1.f:227-243
```

**Limitations.** Single run, no repeat. The conservation numbers are quoted verbatim from the run's own ledger and were not independently recomputed. The `5.0` identification is a four-significant-figure numeric match plus a corroborating band fraction and species chemistry -- strong, but the fertilizer parse on the ecosys-ng side has **not** been read, so it remains an identification rather than a traced path. Nothing here changes gate status; `check_gate.py` owns that, and the run still stops at 1.25% of the horizon.
