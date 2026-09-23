# Run 026 -- `issue-101` CONFIRMED in production, and two distinct boundary-ledger allocations measured, 2026-09-23

**Status: `issue-101` is verified end to end -- written, compiled, and now proven in a production failure row. `issue-100` gains a hard new measurement and a sharper question. Frontier unchanged at hour 3,275.**

## 1. `issue-101` confirmed: the row now names its own index space

The two hour-3,275 nitrogen rows, from the relabelled binary:

```
error: hourly cell conservation failure: cell=0 quantity=nitrogen
       before=6.418057163733818e2 after=6.433946871895852e2
       external_inputs=1.6566363548027827e0 external_outputs=4.033074007076744e-16

error: hourly_layer layer_scope conservation failure: layer_scope=2 quantity=nitrogen
       before=5.04112824263519e1 after=5.1993688088010714e1
       external_inputs=1.7186002174175976e0 external_outputs=6.85290171591924e-2
```

**The second row is a layer-scope row and now says so.** Before the fix both rows read `hourly cell conservation failure: cell=N`, which is what sent `issue-100` chasing the cell ledger for two build-and-run cycles. `run-025` deduced this from a call-site probe; it is now **directly demonstrated in production**, which was the confirmation that run listed as its main limitation.

The first row is a genuine grid-cell row, correctly labelled, and the numbers in both are byte-identical to `run-023`, `run-024` and `run-025` -- these figures have now reproduced across **four** runs and **three** binaries.

`issue-101` is closed by this run: fix written, `BUILD_EXIT=0`, strings verified in the binary, relabelled row observed. The one remaining gap is the test suite, which has not been re-run since the `D:` fault (see below).

## 2. New measurement: there are TWO distinct ledger allocations

The trace sites now print the ledger's slice address, and the addresses do not agree:

| log line | site | `cells_ptr` | `in` | `out` |
|---|---|---|---|---|
| 11999 | `accumulateCells` | **`0x1ef8266a800`** | `0` | `3.836286914478998e-18` |
| 12000 | `accumulateCells` | **`0x1ef8266a800`** | `0` | `3.474144335157334e-16` |
| 12001 | `accumulateCells` | **`0x1ef8266a800`** | `0` | `2.687005216048415e-16` |
| 12003 | `accumulate` | **`0x1ef804f0c00`** | `0` | `1.4674866533174874e-2` |
| 12004 | `at_evaluate` | **`0x1ef804f0c00`** | `0` | `1.4674866533175493e-2` |

**`accumulateCells` books into a different allocation from the one `evaluate` reads.** That is consistent with the 403 `BoundaryLedger.init` calls measured in `run-024` -- transient ledgers are constructed, written, and evaluated separately -- and it means the transport booking helpers' contributions are **not** in the array the hourly cell closure is computed over. Whether that is by design (a scratch candidate committed elsewhere) or a real wiring defect is **not established here**.

## 3. The remaining discrepancy, stated without a mechanism

At the cell `evaluate` call, on the very pointer it reads, the ledger holds `nitrogen_input_g = 0` and `nitrogen_output_g = 1.4674866533175493e-2`. The row emitted for that same cell reports `external_inputs = 1.6566363548027827` and `external_outputs = 4.033074007076744e-16`. **Neither term matches, and `transaction` maps these one-to-one** (`hourly_cell_conservation.zig:2453`: `.external_inputs = activity.nitrogen_input_g`).

**I am deliberately not proposing a mechanism.** The obvious move is to read the ordering of the log lines -- `at_evaluate` at 12004, eight diagnostic lines, then the cell row at 12013 -- and infer that the row must come from a *later* `evaluate` call, since a row emitted inside `evaluateForScope` would print before the `if (!accepted())` diagnostics. That inference may well be right, but **inferring execution order from log-line and source-line position is the single error I have made most often on this issue and on `issue-099` -- wrong at least three times** -- so it is recorded as a hypothesis to be measured, not a finding. The measurement that would settle it is a per-call counter and a call-site identifier on every `evaluateForScope` entry.

## What this changes for `issue-100`

The question is now narrow and well-posed: **the hourly cell closure is computed over an array that does not contain the transport helpers' bookings, and reports terms that match neither the array it reads nor the traces of what was written to it.** Until the number of `evaluateForScope` calls per hour and their identities are measured, no producer can be held responsible for the `0.0676655386` g N.

## Limitations

Single run; the failure-row figures are a fourth reproduction and are solid, but every probe figure here comes from one run. **The test suite has NOT been re-run since the `D:` fault** -- `issue-101`'s change is compiled and production-observed but not regression-tested, which is the one outstanding verification. The two-allocation finding is read off two printed addresses in one hour and has not been traced to the allocations' owners; "by design or defect" is genuinely open. The ordering hypothesis in section 3 is explicitly unmeasured. `check_gate.py` owns gate status; the frontier is unchanged at 3,275 of 262,920 hours (1.25%), so criteria 1 and 2 remain unverifiable for plant processes and criterion 3 is untouched.
