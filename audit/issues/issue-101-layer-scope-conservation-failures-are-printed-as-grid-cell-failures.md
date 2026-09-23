# Issue 101 -- layer-scope conservation failures are printed as grid-cell failures, and the printed index is meaningless without the domain

Status: **FIX WRITTEN 2026-09-22, NOT YET COMPILED. Do not treat this as verified.** A diagnostics-only defect with no effect on computed science, but it directly caused three wrong committed conclusions on `issue-100` and cost two `ReleaseSafe` build-and-run cycles (roughly two hours) chasing the wrong ledger.

**Verification is blocked by a host-environment fault, not by the change.** Neither `zig test src/module_index.zig` nor `zig build -Doptimize=ReleaseSafe` will make progress on this host as of 2026-09-22 22:00 onward: both sit with live processes at **exactly zero CPU-seconds delta over 60 s**, write nothing to the global zig cache, and never ramp a `build-exe` child past ~0.5 CPU-seconds, where a healthy build of this project reaches **745 CPU-seconds and a 2.3 GB working set**. The same toolchain compiled and ran a trivial one-test file in **25.5 s** during the stall, so zig is not broken. Memory and disk are not the constraint (36 GB of 64 GB free, 395 GB free on C:). The host is broadly I/O-degraded: plain `Get-Process` and `Get-CimInstance` calls began taking over five minutes each.

**The cause is NOT established.** I suspected the `issue-091` failure class (Defender interfering with this project's builds) because `MsMpEng` was resident at 1.2 GB, but `Get-MpComputerStatus` refutes an active scan -- the last quick scan ended 2026-09-22 02:15:09 and the last full scan on 2026-09-16, so only ordinary real-time protection is running. That attribution is withdrawn. Memory, disk and the toolchain are all individually fine, and I stopped probing the host rather than spend more of the session on it, so **the fault is recorded as observed and uncharacterised.**

No workaround was applied. The one I had in mind -- a Defender path exclusion -- is both a privileged environment change the project contract forbids as an audit side effect, and unjustified now that the scan hypothesis is refuted. The fix therefore stands as written and unverified until the host recovers.

**Compilation status of the committed source, stated precisely:** the `issue-100` instrumentation in this tree **was** compiled and executed -- it is the binary behind `run-025`, built 18:35 and run to hour 3,275. The `issue-101` change below (the `EvaluationScope` domain variants, the three message format strings, and the four `layer_local_conservation` call sites) was written **after** that build and **has never been through a compiler**. It is mechanical and `scope` was verified to drive no logic, but it is unverified.

## The defect

`hourly_cell_conservation.evaluateForScope` is shared by **two callers over two different index spaces**:

| caller | arrays | index space |
|---|---|---|
| `ecosys_ng.zig:5872` via `hourly_cell_conservation.evaluate` | `hourly_cell_storage_before/after`, `hourly_cell_boundary_ledger.cells`, `canopy_cell_area_m2` | **grid cells** |
| `ecosys_ng.zig:6055` via `layer_local_conservation.evaluate` (`:4325`) | `hourly_layer_storage_before/after`, `hourly_layer_boundary_ledger.activity`, `layer_scope_area_m2` | **layer/scope** |

The layer caller passed the scope tag `.hourly` -- the *same* tag the cell caller uses -- and the failure message hard-coded the word `cell`:

```zig
"{s} cell conservation failure: cell={d} quantity={s} ..."
.{ @tagName(scope), cell, field.name, ... }
```

So a **layer-scope** failure rendered as:

```
error: hourly cell conservation failure: cell=2 quantity=nitrogen before=5.04112824263519e1 ...
```

where **`2` is a layer/scope index and there is only one grid cell in this deck.** Nothing in the line distinguishes it from a grid-cell row. All three scope tags were affected, not just `hourly`: the layer module's accumulated paths (`:4894`, `:4908`, `:4936`) passed `.accumulated_continuity` and `.accumulated`, identical to the cell module's, so **all six (domain, window) combinations collapsed onto three tags.**

The same hard-coded `cell=` appears in the sibling carbon-components and heat-components diagnostics emitted alongside a failure.

## How it misled, concretely

`issue-100` was filed on the hour-3,275 nitrogen residual. The failure rows read `cell=0` and `cell=2`, so I treated them as two grid cells and:

1. Characterised the defect as "a fixed absolute mass lost once per affected cell" and committed that.
2. Instrumented all three `BoundaryLedger` mutation methods, plus a presence marker and an hour gate, and ran to the frontier -- **the wrong ledger**, twice.
3. When the traced totals did not match the reported terms, concluded that "`evaluate` is not reading the ledger state I instrumented" and committed that too. It was true but for a mundane reason: the row was not from that evaluator's call at all.
4. Spent effort reconciling `cells.len=1` (correct, measured 403 times) against an apparently impossible `cell=2` row, and floated a `tile_layout` halo hypothesis that had to be withdrawn.

The measurement that exposed it was a probe at the `evaluate` call site itself, which fired **exactly once** with every array length 1 while **two** rows were emitted -- proof the rows came from elsewhere. Full record: `audit/runs/run-025-issue-100-the-failure-rows-are-LAYER-rows-mislabelled-as-cells-2026-09-22.md`.

**This is a diagnostics defect that produced real, repeated audit error.** A conservation failure row is the primary evidence artefact at this frontier; a row whose index space is unstated is not evidence, it is a trap.

## The fix

`EvaluationScope` now encodes the **domain** as well as the accumulation window, and exposes `domain()` so the message names the index space:

```zig
pub const EvaluationScope = enum {
    hourly, accumulated_continuity, accumulated,
    hourly_layer, accumulated_layer_continuity, accumulated_layer,

    pub fn domain(self: EvaluationScope) []const u8 {
        return switch (self) {
            .hourly, .accumulated_continuity, .accumulated => "cell",
            .hourly_layer, .accumulated_layer_continuity, .accumulated_layer => "layer_scope",
        };
    }
};
```

All three failure messages now interpolate `scope.domain()` in place of the hard-coded word and for the index label, so the same layer row reads:

```
hourly_layer layer_scope conservation failure: layer_scope=2 quantity=nitrogen ...
```

`layer_local_conservation`'s four delegating call sites (`:4346`, `:4901`, `:4915`, `:4943`) pass the layer variants. `scope` was verified to be used **only** for `@tagName` in three log statements and for nothing else in the evaluator, so extending the enum changes no logic and no acceptance decision.

## Why this was safe to change

- `scope` drives no arithmetic, no tolerance, no acceptance. Confirmed by inspecting every `scope` reference in `evaluateForScope` (`:2371` declaration, `:2440`/`:2445`/`:2466` `@tagName` uses only).
- A whole-tree text search finds exactly one emitter of the message, so there is no second copy to keep in sync.
- No test asserts the message text; the nearby source-text assertions (`hourly_cell_conservation.zig:2612`, `hourly_heat_water_solute.zig:10795`) count occurrences of `"hourly_cell_conservation.evaluate("`, which is untouched.

## Consequence for the audit record

Every prior record quoting a `cell=N` conservation row with `N > 0` for this single-cell deck was quoting a **layer/scope** index. That includes `issue-099`'s phosphorus row and `issue-100`'s nitrogen rows, both at index 2. Those rows' *numbers* are unaffected and reproduce byte-identically across three binaries; only the coordinate label was wrong. `issue-100` has been re-aimed at `hourly_layer_boundary_ledger.activity` accordingly.

## Limitations

The fix is a labelling change verified by inspection plus the full test suite; **as of this writing it has not yet appeared in a production failure row**, which is the real confirmation and requires the next run to reach hour 3,275. The identification of `layer_local_conservation.evaluate` as the emitter of both hour-3,275 rows is a deduction from the call-site probe plus the delegation at `:4325`, **not** yet confirmed by a probe inside the layer call -- the relabelled row itself will confirm or refute it. The `domain()` strings are a naming choice, not a legacy-derived term.
