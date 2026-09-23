# Run 024 -- `issue-100`: the reported conservation terms do NOT come from the boundary ledger, and there is only ONE grid cell, 2026-09-22

**Status: the measurement succeeded and refuted my own framing of this issue for the second time. No fix. No frontier change (still hour 3,275).** What it produced is a much better-posed question than the one it was built to answer.

## The experiment

`ReleaseSafe`, fresh deck copy (`n100c`, staged from `n100b`'s inputs with no checkpoints so it ran from hour 1), instrumented three ways:

1. A nitrogen trace in **all three** `BoundaryLedger` mutation methods -- `accumulate` (`:845`), `accumulateCells` (`:898`) and `accumulateIntercell` (`:917`) -- via one shared `traceNitrogen` helper, so the measurement could not be incomplete by construction the way the previous one was.
2. An **unconditional presence marker** in `BoundaryLedger.init` reporting `cells.len`, so "fired zero times" and "was not compiled in" are distinguishable.
3. An **hour gate** (`diagnostic_nitrogen_trace_hour == 3275`, published from the driver beside the per-hour `reset()`), because twelve booking sites firing every hour for 3,275 hours through a per-line-flushing logger previously cost ~140x throughput.

Pre-run control: the built binary was checked for the probe strings before being run -- `n_ledger[init]` present once, `n_ledger` twice -- and its mtime was 53 seconds old. The probe was in the binary, established **before** the experiment rather than inferred after it.

## Result 1: the frontier row is bit-reproducible

Both failure rows came back **byte-identical** to `run-023`, from a different binary:

```
cell=0 quantity=nitrogen before=6.418057163733818e2 after=6.433946871895852e2
       external_inputs=1.6566363548027827e0 external_outputs=4.033074007076744e-16
cell=2 quantity=nitrogen before=5.04112824263519e1 after=5.1993688088010714e1
       external_inputs=1.7186002174175976e0 external_outputs=6.85290171591924e-2
```

Determinism across binaries is worth having: it means every number in `issue-100` is a stable target, not run-to-run noise.

## Result 2: there is exactly ONE cell

**403 `BoundaryLedger.init` calls, every single one `cells.len=1`.**

```
TEMP_DIAGNOSTIC n_ledger[init]: cells.len=1     (x403, no other value)
```

This agrees with the deck derivation and settles the question `issue-100` left open: `runottawa:4`'s `geospatial_grid,45.25,45.35,-75.75,-75.65,0.10,0.10` is a 0.10-degree span at 0.10-degree resolution, `spatial_grid.RegularGrid` treats its bounds as **cell edges** (`:40-41`), so `intervalCount` gives 1 row by 1 column. The `tile_layout` halo hypothesis is **not** needed and is withdrawn.

**So `cell=2` cannot be a grid cell index.** `evaluate` takes `cell` as a loop index over `0..storage_before.len` and requires `boundary.len` to equal it (`:2356-2358`), and a whole-tree search finds **exactly one** emitter of that message (`hourly_cell_conservation.zig:2412`). A `cell=2` row is not constructible from a one-element ledger. That row is real, reproducible, and its index space is unidentified.

## Result 3: the ledger books ZERO nitrogen input at the failing hour

The probe fired **four** times, all `cell=0`, at log lines 11999-12003 -- immediately before the failure rows at 12012 and 12021, which confirms the hour gate selected the right hour:

| site | `in` | `out` |
|---|---|---|
| `accumulateCells` | `0` | `3.836286914478998e-18` |
| `accumulateCells` | `0` | `3.474144335157334e-16` |
| `accumulateCells` | `0` | `2.687005216048415e-16` |
| `accumulate` | `0` | `1.4674866533174874e-2` |
| **ledger total** | **`0`** | **`1.4674866533175493e-2`** |

Against what the row for that same cell reports:

| | probe (ledger total) | row (`cell=0`) |
|---|---|---|
| nitrogen input | **`0`** | **`1.6566363548027827`** |
| nitrogen output | **`1.4674866533175493e-2`** | **`4.033074007076744e-16`** |

**Neither term matches, and the output disagreement runs the wrong way** -- the traced output is fourteen orders of magnitude *larger* than the reported one, so this is not a case of the probe missing some additional contribution. The array `evaluate` reads is not the ledger state the probe watched.

## What this refutes -- including two things I had already committed

1. **"Cells 0 and 2 lose the same absolute mass."** The two rows and their eleven-figure-identical residual `-0.0676655386` are **reproduced and real**. The *interpretation* is dead: there is one grid cell, so these are not two cells. The identical residual is now far more likely to be **one physical loss reported at two aggregation levels or two scopes** than two independent losses of a coincidentally equal fixed mass -- which also disposes of the "fixed absolute quantity dropped once per affected cell" characterisation I put in the issue's status line. **Not yet established either way**; stated as the better-supported reading, not a finding.
2. **"Cell 2's nitrogen is booked via `accumulateCells` or `accumulateIntercell`."** Refuted. The probe covers all three methods and the only cell that exists books **no nitrogen input at all**.

That makes this the **tenth and eleventh** mechanism-from-reading refuted across `issue-099` and `issue-100`. The difference is that these two were refuted by the measurement that was designed to test them, which is the intended way for it to go, and the cost was one build and one run rather than eight.

## The better-posed question this leaves

Not "where does the missing nitrogen go" but: **what array does the hourly cell conservation report actually read, and in what index space?** Everything follows from that, and until it is answered, the `before`/`after`/`external_inputs` figures in `issue-100` cannot be attributed to any particular producer.

The next build (in progress at the time of writing) adds two instruments aimed exactly at it:

- A probe at the `evaluate` call site itself (`ecosys_ng.zig:5872`) printing `storage_before.len`, `storage_after.len`, `cells.len`, `area.len`, the slice **address**, and cell 0's actual nitrogen terms at the instant of the call. Combined with the addresses now printed at the three trace sites, this separates "a different array" from "the same array, rewritten in between".
- **Nitrogen added to the existing post-NITRO failure trace.** That trace already checkpoints carbon and heat at all seven points of the hour (`after_nitro, after_post_watsub, after_uptake, after_chemistry, after_transport, after_interface_heat, after_surface_gas`) but carried **no nitrogen**, which is why it could not localise this loss. All six storage-side nitrogen pools that `mass_balance_audit.zig:262` sums for the closure are now traced per point, so a step in any one of them between adjacent points localises the loss to a stage *and* a pool in a single run.

## Limitations

Single run, no repeat -- though the two failure rows are byte-identical to `run-023`'s, which is a repeat of those specific numbers across two different binaries. The ledger totals in the comparison table are **my sums of the four traced lines**, not a figure the program printed. The probe covers the three `BoundaryLedger` methods; it does **not** cover direct writes through the public `cells` field, which any holder of the ledger can perform and which remains a live possibility that the address probe is designed to detect. The claim that exactly one source site emits the failure message is a whole-tree text search, not a call-graph proof. `check_gate.py` owns gate status; the frontier is unchanged at 3,275 of 262,920 hours (1.25%), so criteria 1 and 2 remain unverifiable and criterion 3 is untouched.
