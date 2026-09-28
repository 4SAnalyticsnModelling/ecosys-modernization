# Round 00001 DeepSeek Inventory & Baseline Challenge

## 1. Gate Status (G0, GP1, GP2, G1, G2)
- **G0**: **NO passing evidence under clean-tree rules**.
  - In `audit/analysis/g0-4-record.json:1-158`, checks were previously recorded, and in `.agent/results/T-00269.md:15` `check_gate.py` passed temporarily in a prior tree state.
  - However, running `uv run ecosys-audit/scripts/check_gate.py --gate audit/analysis/g0-4-record.json` currently returns **FAIL** (exit code 1) with 6 problems: content hashes changed across `git-state-discovered-and-dirty-work-parked`, `d6-deck-edits-adjudicated-and-signed`, `legacy-oracle-hashed-in-evidence-store`, `legacy-output-horizon-inventory`, `tracecov-stale-hash-report`, and `issue-status-normalized`, plus dirty source tree entries.
- **GP1, GP2, G1, G2**: **NO passing evidence exists**.
  - No gate JSON records exist in `audit/` or the repository for GP1, GP2, G1, or G2 (verified by glob across repository). Per `ecosys-ng_ottawa_qualification_execution_plan.md:189,248,266,279`, these exit gates have neither been authored nor evaluated.

## 2. Root-Cause Status of Failure at Hour 3289
- **Latest Production Run**: `audit/runs/run-038-issue-108-root-atmosphere-gas-booked-with-legacy-sign-carbon-closes-2026-09-24.md:1-31` (receipt `audit/runs/issue-108-fix-run/receipt.json`).
- **Relevant Issues**: `audit/issues/issue-105-hour-3289-root-geometry-unset-for-skipped-layers.md` and `audit/issues/issue-108-hour-3289-carbon-and-cation-closure-after-root-geometry-fix.md`.
- **Known vs. Hypothesized**:
  - *Known*: Hour 3,289 (Day 138, hour 1) is the first hour root uptake geometry runs (`run-033:27`). The initial crash `InvalidRootAqueousDiffusionInput` was fixed by evaluating `rootUptakeGeometry` before hydraulic continue guards (`run-036:6-9`). In `run-038:27-28`, the carbon closure defect was eliminated by correcting the sign of root-atmosphere gas exchange in `daily_gas_flux.zig:combinedHourIncrement`.
  - *Known*: Hour 3,289 still fails cell/layer conservation strictly on positive cation residuals in layer 2: Ca `+9.1948e-8`, Na `+2.9104e-10`, K `+1.4916e-10` (`run-038:28`, `issue-108:3`).
  - *Hypothesized*: Cations in layer 2 gain storage without corresponding ledger bookings during root salt exchange (`plant_root_salt_exchange.zig` / `roots.salt_uptake_mol_per_h`), or due to unbooked rhizosphere cation exchange (`issue-108:7`).

## 3. Recommended Action & Challenge
- **Recommended Frontier Action**: Focus on **P0/P2 infrastructure & Issue-108 cation localization**. Specifically, formulate a testable probe for the layer-2 Ca/Na/K unbooked storage increase during hour 3,289 root salt exchange without launching full 30-year runs.
- **Adversarial Challenge**: CLAUDE's / prior planning's claim that G0 or the Ottawa baseline is closed or ready for P3/P5 is refuted. `check_gate.py` fails on `audit/analysis/g0-4-record.json` due to uncommitted artifacts and stale hashes. Furthermore, claiming simulation frontier advancement without resolving the cation imbalance in layer 2 violates mass conservation.
