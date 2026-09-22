# Run 021 -- first `ReleaseSafe` production run: criterion 3 measured in the qualification mode, and `issue-090`'s fix production-INVALIDATED, 2026-09-22

**Status: TWO RESULTS, ONE GOOD AND ONE BAD.** `issue-091` is resolved (`ReleaseSafe` is not detected by Defender), so this is the first production run of the session and the first-ever measurement in the build mode the performance qualification actually requires. It also shows `issue-090`'s fix **does not clear hour 3,275**.

## Configuration

| | |
|---|---|
| binary | `zig build -Doptimize=ReleaseSafe`, SHA-256 `4A08E227D8B524A271A4FC4BD4916D68066971724E7A4C2CC978AAD0D646F5B6`, 11,139 KB |
| deck | Ottawa, fresh copy (`runottawa` + `runottawa_input_files` only -- **no checkpoint `.bin` files**, so no resume) |
| tolerances | `runtime,4,1,1e-8,1e-11,200,0.5` -- `relative=1e-8`, `absolute=1e-11`, 200 max iterations. **Strict**, not the loose `1e3` the reference performance doc measured |
| threads | `--threads 1` (matching `run-003`/`run-004` methodology) |
| launched | detached via `Start-Process`, stderr/stdout redirected, start time recorded to disk |

## Result 1 (BAD): `issue-090`'s fix does NOT clear hour 3,275

```
info:     census_positive_control entries=3275 first_hour=1 last_hour=3275
error: MineralNitrogenInZeroWaterDomain
```

**Same error, same hour as `run019`** -- which predates the fix (`issue-091` records `run019` as "the previous binary, before the NO3 gate correction"). `issue-090` corrected the fertilizer-band NO3 activation gate to `Z4B+Z3B+ZUB+ZOB` per `hour1.f:356`, was unit-validated with a test pinned to hand arithmetic, and passed the full suite with zero regressions. **It does not fix the frontier.**

This is exactly the validation that `issue-091` blocked, and the honest outcome is that the fix is now **production-invalidated as a frontier fix**. It may still be correct as a faithfulness correction -- the gate asymmetry it fixes is real and source-verified -- but it is not the cause of `MineralNitrogenInZeroWaterDomain`. `issue-090` must be re-dispositioned: correct-but-not-causal.

**Frontier unchanged at 3,275.** No regression either -- the run reached the same hour, so the trace removals and the session's other landed changes cost nothing.

## Result 2 (GOOD): criterion 3 measured in `ReleaseSafe` for the first time

Wall clock, measured externally (start timestamp written to disk before launch, end from process exit):

| checkpoint | elapsed | rate | vs Fortran (51.21 ms/h) |
|---|---|---|---|
| hour 2,208 | 194 s | **87.9 ms/h** | **1.72x slower** |
| hour 3,240 | 393 s | **121.3 ms/h** | **2.37x slower** |
| hour 3,275 (exit, incl. failure handling) | **556 s** | 169.8 ms/h | 3.32x slower |

The model's own per-day sample (`final_hour_elapsed_ms`, the final hour of each of 136 days) gives mean **144 ms/hour**, sum 19,631 ms -- consistent with the external wall clock and an independent confirmation of the same order.

The Fortran denominator is `run-003`'s gfortran oracle figure, **51.21 ms/hour**, which that run cross-checked two ways: full-year 446.50 s / 8,760 h = 50.97 ms/h against day-108 131.46 s / 2,568 h = 51.21 ms/h, agreeing to 0.5%.

### The important structural finding: the gap WIDENS within the year

The 3,240-to-3,275 segment cost 163 s for 35 hours (4.66 s/hour), which is failure handling, not stepping -- discount it. But the genuine stepping segments show a clear trend:

- hours 1-2,208: **87.9 ms/h**
- hours 2,208-3,240: (393-194) s / 1,032 h = **192.8 ms/h**

**Per-hour cost more than doubles** from winter into spring as vegetation and active biogeochemistry come online. **The Fortran shows no comparable growth** -- its full-year and day-108 rates agree to 0.5%, i.e. it is essentially flat across the whole year.

So "ecosys-ng is ~2x slower" **understates the problem at the production horizon**. The ratio is ~1.7x over the winter months where most of the measured span sits, ~2.4x by spring, and extrapolating a widening gap across 262,920 hours gives no reason to expect it stays near 2x. **A full-horizon ratio cannot be stated until a run completes the horizon**, and that is now the binding constraint on criterion 3 -- not tooling, not Defender, and not the absence of a baseline.

### Comparison with the earlier `ReleaseFast` measurements

| run | build | span | rate |
|---|---|---|---|
| `run-003` | ReleaseFast | 1-2,578 | 327.8 ms/h |
| `run-004` (logging gated) | ReleaseFast | 1-2,578 | 103.2 ms/h |
| **`run-021`** | **ReleaseSafe** | 1-2,208 | **87.9 ms/h** |

`ReleaseSafe` at 87.9 ms/h over a comparable span is **faster than `run-004`'s `ReleaseFast` 103.2 ms/h**, despite `ReleaseSafe` retaining runtime safety checks that `ReleaseFast` omits. That is not a `ReleaseSafe`-versus-`ReleaseFast` result -- it is four days of intervening tree improvements swamping the build-mode difference. **The clean build-mode comparison has not been made** and would need both modes rebuilt from the same commit.

## What this does and does not qualify

`tools/production_performance_reference.json` requires "a frozen threshold derived from a **passing** strict-production ReleaseSafe run". This run is strict-production and `ReleaseSafe` but **does not pass** -- it fails at hour 3,275 of 262,920 (1.25%). **So this is not a qualifying measurement and the reference stays `unqualified`.** Nothing here converts a `BLOCKED` gate to `PASS`; `check_gate.py` owns gate status and this run changes none of it.

What it does deliver: the first real number for a criterion that had none in this build mode, and a clear statement that ecosys-ng is currently **slower** than the legacy Fortran by a factor that grows through the simulated year -- against a goal of "significantly more performant". Reaching parity needs better than a 2x speedup; the goal needs more than that again.

## Limitations

- **Single repeat.** `run-003` used three repeats and found ~6% spread; this is one run, so the rates carry at least that uncertainty and the checkpoint rates are from two mid-run samples taken 194 s and 393 s after launch, not instrumented counters.
- **Initialization is included** in every ecosys-ng figure and in the Fortran figure, and the Fortran's initialization is known to be disproportionately slow (`starte.f`'s two ~1000-iteration Newton loops, `run-002`), which if anything **flatters** ecosys-ng here.
- The two models were run on the same machine but not pinned to the same core, and nothing else CPU-heavy was run during the measurement window (deliberately -- no compiles, no test suites).
- `-Doptimize=ReleaseSmall` remains untried; not needed.
- The `implausible surface conductive flux` errors logged during the run (temperature differences of 23-27 K across a 0.01 m surface layer) are **not** fatal and did not stop the run, but they are logged at `error` level and are not investigated here.
