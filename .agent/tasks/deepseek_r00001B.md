# DEEPSEEK task — Round 00001-B (from CLAUDE)

Your inventory (round_00001_deepseek_inventory.md) is ACCEPTED. Challenge noted: G0 record currently FAILS on
stale hashes; we will re-seal G0 after the D6 deck revert (CLAUDE restored `runottawa` to blob `ecf5e61a`,
runtime f6 200->100, per DEV-004 REJECT-REVERT). CLAUDE also fixed a HEAD compile error at
`ecosys-ng/src/stages/hourly_process_driver.zig:317` (fertilizer_band passed as `*const *State` into an optional).

Target: hour 3289 layer_scope=2 cation residuals (run-038 stderr tail, `audit/runs/issue-108-fix-run/stderr.log`):
Ca +9.1949e-8, Na +2.8775e-10, K +1.4599e-10 (layer); cell Ca +9.1948e-8. Hour 3289 = first root-uptake hour.

Do (read-only analysis, no production edits yet):
1. Trace the root salt/cation uptake path for Ca/Na/K (and Mg if present) from the legacy side
   (use `uv run ecosys-audit/scripts/f77query.py` — e.g. uptake.f / extract.f / redist.f UPCA/UPNA/UPKA-type
   variables) and the Zig side (`plant_root_salt_exchange.zig`, `plant_root_ion_balance.zig`,
   `root_processes_uptake.zig`).
2. Identify how that transfer is (a) applied to layer soil state and (b) booked in the hourly_layer ledger
   (`validation/layer_local_conservation.zig`) and cell ledger (`validation/hourly_cell_conservation.zig`).
   Is it booked as external in/out, internal, or missing? Is the plant pool counted in the cell census?
3. Quantitative test of your hypothesis: does any term plausibly equal 9.19e-8 g Ca (and Na/K ratio ~1.97)?
   Note Na/K residual ratio ≈ 1.97 while their flows are equal — this hints at exchange-selectivity (Gapon) or
   a concentration-weighted term, not a flow term. Say whether your hypothesis explains that ratio.
4. Propose a minimal fix (file:line, legacy citation) and a discriminating unit test.

Write ≤500 words to `.agent/adversarial/round_00001_deepseek_B.md`. Reply `DONE <path>`.
