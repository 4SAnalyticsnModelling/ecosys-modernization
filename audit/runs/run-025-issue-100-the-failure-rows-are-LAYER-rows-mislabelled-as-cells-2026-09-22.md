# Run 025 -- `issue-100` RESOLVED as a diagnostic-labelling defect: the hour-3,275 failure rows are LAYER-scope rows printed as "cell", 2026-09-22

**Status: the index-space question `run-024` posed is ANSWERED, and the answer is that I had been instrumenting the wrong ledger for two full build-and-run cycles.** The nitrogen residual itself is still open, but it is now correctly aimed. A separate, genuine reporting defect is filed as `issue-101`.

## The measurement that settled it

Same deck, fresh directory (`n100d`), `ReleaseSafe`, probe strings verified present in the binary before running. Three instruments: the all-method nitrogen ledger trace, nitrogen added to the seven-point post-NITRO stage trace, and a new probe at the `evaluate` call site itself.

The call-site probe fired **exactly once** for the whole hour:

```
TEMP_DIAGNOSTIC n_ledger[at_evaluate]: storage_before.len=1 storage_after.len=1
    cells.len=1 area.len=1 cells_ptr=0x19973f40c00
    cell0_in=0e0 cell0_out=1.4674866533175493e-2
```

Two things follow immediately:

1. **`cell0_in`/`cell0_out` at the call site exactly equal the totals I traced through the ledger's three mutation methods** (`0` and `1.4674866533175493e-2`). So nothing rewrites the ledger between booking and evaluation, and the `run-024` hypothesis of a direct write through the public `cells` field is **excluded**.
2. **Every array is length 1, and the probe fired once, yet two failure rows appear.** A one-iteration loop cannot emit two rows, and neither row's terms match this call's inputs. **So neither failure row comes from `ecosys_ng.zig`'s `hourly_cell_conservation.evaluate` call at all** -- that call did not fail.

## The cause: a second caller reusing the cell evaluator with the `.hourly` tag

`layer_local_conservation.zig:4325-4342`:

```zig
pub fn evaluate(
    allocator, storage_before, storage_after,
    activity: []const hourly.BoundaryActivity,
    scope_area_m2, tolerances,
) !hourly.Report {
    return hourly.evaluateForScope(..., .hourly);
}
```

The **layer** conservation module delegates to the cell module's evaluator and passes the **same `.hourly` scope tag**. The emitter prints `@tagName(scope)` followed by the literal word `cell`:

```
"{s} cell conservation failure: cell={d} quantity={s} ..."
```

So a layer-scope failure renders as `hourly cell conservation failure: cell=2`, where **`2` is a layer/scope index, not a grid cell**. It is called from `ecosys_ng.zig:6055` with `hourly_layer_storage_before/after`, `hourly_layer_boundary_ledger.*.activity` and `layer_scope_area_m2` -- an entirely different ledger from the one I instrumented.

**Both hour-3,275 nitrogen rows are layer-scope rows.** `cells.len=1` never contradicted anything; the rows were never cell rows. My whole-tree search for the message string found the single emitter correctly, but I enumerated its callers by searching only for `hourly_cell_conservation.evaluate` and one sibling file, and never searched the tree for `evaluateForScope` -- which is where the second caller lives. **That is the same narrow-search error that cost me a wrong conclusion earlier on this issue, made a third time.**

## Corroboration from the new nitrogen stage trace

Nitrogen was added to the post-NITRO trace, which previously carried only carbon and heat. Summing its six storage pools at the last checkpoint:

```
sum at after_surface_gas = 643.394687189585
row "after"              = 643.3946871895852     <- match to 15 digits
```

So the trace measures exactly the quantity the row reports, which validates the instrument. It also shows **index 0 is a whole-domain scope**, since its `after` equals the landscape six-pool total. Index 2 is a sub-scope within it. That makes the eleven-figure-identical residual at indices 0 and 2 **one physical loss seen at two aggregation levels** -- the reading `run-024` flagged as better-supported, now corroborated -- and it localises the loss to **sub-scope 2**.

### And a clean negative result: this trace starts too late

| | value |
|---|---|
| six-pool sum at `after_nitro` (first point) | `643.378721260869` |
| six-pool sum at `after_surface_gas` (last point) | `643.394687189585` |
| **storage change inside the trace window** | **`+0.0159659287160139`** |
| storage change reported by the row | `+1.58897081620341` |
| **change occurring BEFORE the first checkpoint** | **`+1.5730048874874`** |

**99% of the hour's nitrogen movement happens upstream of `after_nitro`.** The seven-point trace covers the last 1% of it, so as positioned it cannot localise this loss either. A checkpoint before NITRO is required. Within the window the real movements are ammonium `+0.01027` at `after_uptake` and dinitrogen `+0.006637` at `after_transport`, with nitrate falling `-0.000941`; none of these is the missing `0.0676655386`.

## What this corrects in the committed record

- **`issue-100`'s entire cell-based framing is void**, including the two-cell table, the "fixed mass per affected cell" characterisation, and the `run-024` conclusion that "`evaluate` is not reading the ledger state I instrumented." The truth is narrower and more mundane: **I was reading a different ledger's rows than the one I instrumented, because they are printed with the same words.**
- **The `run-024` withdrawal of the halo hypothesis stands** and `cells.len=1` stands. Those were correct.
- The identical-residual *data* stands, and now has a natural explanation.

## Next bounded action

1. **Fix the labelling (`issue-101`).** This is a real defect that will mislead every future reader exactly as it misled me, and it cost this session two build-and-run cycles (~2 hours). Give the layer callers their own scope identity so the row names its own index space.
2. **Re-aim the nitrogen diagnosis at `hourly_layer_boundary_ledger.activity`**, sub-scope 2, which is where the terms actually come from.
3. **Add a pre-NITRO checkpoint** to the stage trace, since 99% of the movement is upstream of its current first point.

## Limitations

Single run; the two failure rows are byte-identical to `run-023` and `run-024`, so those specific numbers have now reproduced three times across three binaries. The identification of `layer_local_conservation.evaluate` as the emitter of both rows is a **source-level deduction from the call-site probe firing once with length-1 arrays plus the delegation at `:4333`** -- it has **not** been confirmed by a probe inside the layer call itself, which is the obvious next control and is not yet run. The claim that index 0 is a whole-domain scope rests on its `after` matching the landscape total to 15 digits; the scope layout was not read. The stage-trace arithmetic is my own summation of six logged arrays, not a figure the program printed. `check_gate.py` owns gate status; the frontier is unchanged at hour 3,275 of 262,920 (1.25%).
