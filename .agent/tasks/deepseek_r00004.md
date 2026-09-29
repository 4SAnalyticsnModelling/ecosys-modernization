# DEEPSEEK task — Round 00004 DIAGNOSE (from CLAUDE)

Status: phosphate-gate false positives at hour 277 are fixed (uncommitted, `phosphate_network.zig`:
operand-scale ideal-closure floor + P-owner-only per-owner realized gate; 27/27 unit tests). Your cation
sync (round 3) is stashed as `git stash list` "deepseek-cation-sync" while we attribute a 1e-13 hour-241
output change (replay refused: `OutputReplayRecordMismatch` field 7 carbon file f25ch1 day 11).

NEW frontier: fresh hour-0 run (`C:\ecosys-build\runs\h0A.err`, binary with both fixes) fails
hour 277 (1998 d12 h13, cell 0 layer 0) with `SoluteReactionSolverStagnated`:
`SOLUTE inventory-balance progress stopped: iteration=3 maximum=0.3656 rms=0.0352 repeated_state=true`,
then fixed-hour recovery with 32 and 64 exact substeps also stagnates (max 0.0172). Pre-T-00075 binary
(`60e4109`) passes this hour. Failure packet (binary ECOSSOL) is written under
`C:\ecosys-build\runs\h0A\runottawa_output_files\logs\ecosys-ng-solute-failure-*.bin`; replay tool source
`ecosys-ng/src/replay_solute_failure.zig` (not wired into build.zig).

Do (read + targeted tools; no `zig build` — tell CLAUDE if you need a build):
1. Which inventory component dominates the 0.3656 max residual? Find where "inventory-balance progress
   stopped" is computed and what "maximum" measures (file:line).
2. What does T-00075 inject into layer 0 at a wet hour that pre-T-00075 did not (species, magnitude,
   pH / H+ / OH- / carbonate)? Compare `starteDynamicInput` output vs the old mixed-droplet path.
   Is the injected H+/OH-/ion-pair charge balance consistent with legacy STARTE (`starte.f:127-151,
   1234-1310`) — especially units (mol vs g, per m3 rain vs per layer)?
3. Hypothesis ranking with a discriminating test for each. If you find a units/mapping defect in
   T-00075's consumer (`hourly_process_driver.zig:672-751`), propose the exact fix with a legacy cite.
≤500 words → `.agent/adversarial/round_00004_deepseek.md`. Reply `DONE <path>`.
