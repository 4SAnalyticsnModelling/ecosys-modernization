# run-037 -- issue-108: the hour-3,289 carbon residual is root CO2/CH4 venting (1.0758e-6 g C) booked inconsistently (2026-09-24)

Task `20260924-122218-1d2477d6`.

## Existing-log decomposition (run-036 log, no new run)

From the post-NITRO carbon trace (`audit/runs/issue-105-fix-run/stderr.log`, exact `Fraction` arithmetic; five-pool sum minus `after` = 4.4e-12):

| Interval | dStorage (g C) | Pools |
|---|---|---|
| `after_post_watsub -> after_uptake` | -1.075808288e-6 | inorganic/gas -1.07581e-6; residue -1.7289e-7 and plant +1.75529e-7 (a conserving residue->plant transfer, net +2.6e-9 vs organic -2.64e-9) |
| `after_chemistry -> after_transport` | -1.228925738e-1 | inorganic/gas |
| `after_interface_heat -> after_surface_gas` | -5.311990503e-5 | inorganic/gas |

Total storage change -0.12294676878. Booked outputs are 0.12294461808. The residual -2.1516e-6 therefore splits into two equal halves: an unbooked -1.0758e-6 in the uptake interval, and a soil-surface storage loss (0.12294569) that exceeds the booked output by 1.0756e-6.

## Probe (run-037)

- New TEMP_DIAGNOSTIC `diagnostics.traceIssue108Carbon` prints the census C pools, root gas C (CO2+CH4, gaseous and aqueous), the signed `atmosphere_to_root` and `soil_to_root` C exchange ledgers (CO2 and CH4 slots), and cell 0's running ledger C in/out. It is called around `plant_root_gas_transport.advanceOxygen` and `advance` in `hourly_vegetation.zig`, and at every post-NITRO trace point. Target hour re-gated to 3,289. Logging only.
- Build `audit/runs/issue-108-probe-build/receipt.json` (exit 0, 1,004.6 s; exe prefix `5A5488A167DE9406`). Run on a fresh prod-deck copy: `audit/runs/issue-108-probe-run/receipt.json` (exit 1, 2,135.2 s; stderr SHA256 `53080731017CED32EA082FDC269C906A3260572BD30CD190C33C4C46FCA2A2F1`). The failure row is identical to run-036, so the probes did not perturb the run.

## Result: prediction (registered before the run) CONFIRMED for the first step

- `before_root_gas_advance -> after_root_gas_advance`: `inorganic_gas_c` -1.07581e-6 (which includes root gas), `root_gas_c` +3.14872e-5, `soil_to_root_c` +3.25630e-5, **`atmosphere_to_root_c` = -1.07581e-6**. The oxygen pass (`before_root_oxygen -> before_root_gas_advance`) moves nothing.
- So the unbooked uptake-interval loss is **exactly the C that `plant_root_gas_transport.advance` vents from roots to the atmosphere** (atmosphere->root exchange is negative = outward). Soil->root transfer is internal and conserved (soil -3.2563e-5, root +3.1487e-5, vented 1.0758e-6).
- The cell ledger stays 0 until end-of-hour booking, so the second half (booked outputs short of the surface-gas storage loss by 1.0756e-6) cannot be attributed from this probe. It is consistent with the vent entering the booked outputs with the opposite sign, and equally with the vent being unbooked while the surface-gas booking is short by the same amount. **Not established which.**

## Next

Log per-booking carbon at the target hour (extend the ledger mutation trace to carbon, with a producer label) to find which booking carries -1.0758e-6, or where the vent should be booked and is not. Then compare with legacy root-to-atmosphere gas accounting (`extract.f:715-726` `RCODFA`, and the `uptake.f` root gas exchange around `:2040-2140`). The Ca/Na/K layer-2 excess is not addressed here.
