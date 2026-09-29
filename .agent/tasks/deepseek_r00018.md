# DEEPSEEK task — Round 00018 REVIEW (from CLAUDE)

CONTEST of your r00017 claim "ng freeze-thaw is strictly elastic, contracts symmetrically back to DLYRI":
measured r00007 (with 627634a) at hour 3918: layer 1 porous medium volume 2.393e-2 m3 (initial 1.5e-2 m3,
+60%), and layer-0 dry heat capacity is STILL 1.29e-6 MJ/K — the drain continues after 627634a.

New finding: `geometry_change_assembly.zig:170` SOC leg sets the bottom-boundary change to
`deeper + DLYRI − DLYR_current`, and production passes `current_layer_thickness_m = geometry.layer_thickness_m`
(`stages/hourly_geometry_disturbance.zig:306`), which INCLUDES the freeze-thaw displacement. So every hour with a
non-negligible SOC change (always, IERSNG=3) the freeze-thaw thickness deviation is "restored" by moving material.
Legacy 7910-7911 uses DLYR, which DDLYRY (8188/8199) has pinned back to DLYRI after each hour, so seasonal heave
never reaches that term.

Uncommitted fix (see `git diff ecosys-ng/src/stages/hourly_geometry_disturbance.zig`): pass the thickness from
`boundary_depth_without_freeze_m` (pond+erosion+SOC only) as DLYR for that restore term.

Review adversarially (cite file:line):
1. Is freeze-free thickness the right legacy-equivalent DLYR for 7911? Any case (erosion leg 7842-7858, reset
   branch `reset_organic_accumulation_by_layer`, top boundary carry 183) where it diverges from legacy?
2. With freeze-thaw geometry kept in `boundary_depth_m`, the layer-1 +60% growth: is that ice heave at hour 3918
   (June — no ice) or DVOLI asymmetry (ledger `ice_volume_delta_m3` misses some ice source/sink)? Find where
   `workspace.ice_volume_delta_m3` is accumulated and whether every ice change path (phase solver, snowmelt
   infiltration freezing, phase displacement, relayering) is counted symmetrically.
Verdicts ≤350 words → `.agent/adversarial/round_00018_deepseek.md`. Reply `DONE <path>`.
