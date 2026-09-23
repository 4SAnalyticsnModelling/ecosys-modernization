# Issue 101 -- layer-scope conservation failures are printed as grid-cell failures, and the printed index is meaningless without the domain

Status: **RESOLVED and CONFIRMED IN PRODUCTION (2026-09-23, `run-026`).** The relabelled row was observed at hour 3,275:

```
error: hourly_layer layer_scope conservation failure: layer_scope=2 quantity=nitrogen ...
```

where before the fix it read `hourly cell conservation failure: cell=2`. The sibling row is a genuine grid-cell row and is still correctly labelled `hourly cell ... cell=0`, so the two index spaces are now distinguishable in the log. Fix written, `BUILD_EXIT=0`, all four new strings verified present in the binary, relabelled row observed. **Outstanding: the test suite has not been re-run since the `D:` fault**, so this is production-confirmed but not regression-tested.

Earlier status line, retained: **FIX COMPILES (2026-09-23 06:28, `ReleaseSafe`, exit 0).** A diagnostics-only defect with no effect on computed science, but it directly caused three wrong committed conclusions on `issue-100` and cost two `ReleaseSafe` build-and-run cycles (roughly two hours) chasing the wrong ledger.

**Update 2026-09-23: the `D:` fault cleared on its own and the build then succeeded, which confirms the diagnosis below and clears this change of suspicion.** The same tree that would not build for hours compiled in one go once `D:` read latency returned to normal: the timed read went from **5,875 ms to 427 ms** for the same 214 KB file, and `build-exe` then ran the healthy profile -- **714 CPU-seconds and a 2.29 GB working set**, against the 0.3 CPU-seconds and 17 MB it showed while `D:` was faulted. `BUILD_EXIT=0`, binary written 06:28:34, and all four new strings (`layer_scope`, `hourly_layer`, plus the probes) verified present in it. **So the change was never the cause, and the "never been through a compiler" caveat recorded in commit `8df913d` is now discharged.** The test suite has not yet been re-run, and the relabelled row has not yet appeared in a production log -- that run is in flight.

**The history below is retained because the failure mode is worth keeping: a faulted disk presents as a compiler hang, not as slowness.**

**Verification was blocked by a host-environment fault, not by the change.** Neither `zig test src/module_index.zig` nor `zig build -Doptimize=ReleaseSafe` will make progress on this host as of 2026-09-22 22:00 onward: both sit with live processes at **exactly zero CPU-seconds delta over 60 s**, write nothing to the global zig cache, and never ramp a `build-exe` child past ~0.5 CPU-seconds, where a healthy build of this project reaches **745 CPU-seconds and a 2.3 GB working set**. The same toolchain compiled and ran a trivial one-test file in **25.5 s** during the stall, so zig is not broken. Memory and disk are not the constraint (36 GB of 64 GB free, 395 GB free on C:). ### The cause, now measured: `D:` read latency has collapsed

Timed single-file reads via `System.IO.File.ReadAllBytes`, same moment, same process:

| file | size | elapsed | per KB |
|---|---|---|---|
| `D:\ecosys-modernization\ecosys-ng\src\validation\hourly_cell_conservation.zig` | 214 KB | **5,875 ms** | ~27 ms |
| `C:\...\OneDrive\...\docs\v1_release_checklist.md` | 46 KB | **26 ms** | ~0.57 ms |

**`D:` is roughly 50x slower per byte than `C:`, and 5.9 seconds to read one 214 KB local file is pathological.** That single measurement explains every symptom:

- `zig build-exe` must open several hundred source files on `D:`, so it sits **I/O-blocked at process startup** -- which is exactly why it shows near-zero CPU and a 17 MB working set while never ramping. It is not hung on a computation; it is waiting on the disk.
- `git` operations on `D:` took over five minutes.
- The **trivial test that compiled in 25.5 s was in the scratchpad on `C:`**, not on `D:`. That is the whole difference.
- Reading the 3.28 MB reference register on `C:` worked normally throughout.

**Hypotheses now refuted, each by measurement:**

- *A wedged zig cache from my five force-kills.* Retried with `--global-cache-dir` pointed at a brand-new directory: `build-exe` still sat at 0.3 CPU with **zero delta over 30 s** and wrote **zero** files into the fresh cache.
- *The `issue-091` Defender class.* `MsMpEng` was resident at 1.2 GB, but `Get-MpComputerStatus` shows no scan running -- last quick scan ended 2026-09-22 02:15:09, last full scan 2026-09-16. Withdrawn.
- *Memory or disk exhaustion.* 36 GB of 64 GB free; 395 GB free on `C:`, 449 GB on `D:`.
- *A compiler bug from this issue's own edit.* The stall reproduces identically for `zig test`, and the successful 18:35 build of this same project shows the toolchain handles this code path; the change was additionally simplified (hoisting `scope.domain()` out of the `inline for`) and the stall was unaffected.

**This is a host storage fault on `D:`, not an audit problem and not something this session caused.** No workaround was applied: a Defender exclusion is a privileged environment change the contract forbids as an audit side effect, and is unjustified anyway now that the scan hypothesis is refuted; relocating the repository off `D:` would be a far larger environment change than an audit should make unilaterally. **The fix therefore stands as written and unverified until `D:` is healthy.** The first thing a resuming session should do is re-run the timed read above -- if `D:` still reads at ~27 ms/KB, no build will complete and nothing else should be attempted.

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

## Independent corroboration from the reference docs, and a check that this is not a duplicate

Per standing practice, the OneDrive reference docs (read-only) were searched before treating this as a new finding. The 3.28 MB, ~49,800-line `docs/discrepancy_register.md` **does not document the cell/layer message mislabeling**, so this entry is not a duplicate. But it contains two things that bear on it directly.

**1. The same ambiguity already cost an earlier pass time.** The register's 2026-09-04 amendment records that the owner of `HourlyLayerConservationFailure` was, in the preceding entry, "**not yet identified by file**" and had to be hunted down:

> "Found the owner of `HourlyLayerConservationFailure`: `src/validation/layer_local_conservation.zig:4172`, called from `ecosys_ng.zig:5621` ... passed to this one `evaluate()` call"

A whole amendment was needed to establish which module owned a layer conservation failure. That is the same difficulty this issue describes, hit independently by a different pass roughly three weeks earlier. **The defect is recurrent, not a one-off confusion of mine** -- which is the argument for fixing the label rather than just noting it.

**2. It confirms `run-025`'s deduction from an independent source.** `run-025` identified `layer_local_conservation.evaluate` as the emitter of both hour-3,275 rows by deduction -- the call-site probe firing once with length-1 arrays, plus the delegation at `:4325` -- and listed as a limitation that no probe had confirmed it from inside the layer call. The register independently records that `layer_local_conservation`'s `evaluate()` is a **distinct call site** owning the layer conservation check, invoked from `ecosys_ng.zig` with its own tolerance copy. The line numbers differ (`:4172` / `:5621` then, `:4325` / `:6055` now) because the files have grown, but the structure is the same. The deduction stands on two independent legs now.

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
