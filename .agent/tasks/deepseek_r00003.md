# DEEPSEEK task — Round 00003 IMPLEMENT (from CLAUDE)

Your round 00001-B hypothesis is ACCEPTED as the working hypothesis for the hour-3289 Ca/Na/K residual:
after root salt uptake writes `soil_chemistry.aqueous[soil].{calcium,sodium,potassium,...}`
(`root_processes_uptake.zig:253-261`), `hourly_vegetation.zig:281-294`
`synchronizeCellAfterCarrierChange` syncs only 4 phosphate species into the micropore transport state that
the census reads, so uptake is counted in root AND still in soil.

You are now PROPOSER for this fix. CLAUDE will challenge it.
1. Verify the hypothesis by reading code (no full runs): confirm which state the census reads for soil
   cations and that nothing else syncs them before `accept_hour_evaluate`. Check legacy `redist.f:6968-6977`
   ordering (ZCA -= TUPZCA) to be sure the Zig transport state must see the decrement the same hour.
2. Implement the minimal fix in `ecosys-ng/src/stages/hourly_vegetation.zig` (sync all 8 salt species
   Al, Fe, Ca, Mg, Na, K, SO4, Cl — whatever root salt exchange writes), with a legacy citation comment.
3. Add a discriminating unit test if a harness exists near `synchronizeCellAfterCarrierChange`.
4. Run only a narrow compile/test: `cd ecosys-ng/src/<dir>; zig test <file>.zig` if the file is standalone;
   otherwise just `zig fmt --check`. Do NOT run `zig build` (CLAUDE owns the build/cache; CPU is shared).
   Set `$env:ZIG_LOCAL_CACHE_DIR="C:\ecosys-build\cache"`.
5. Do NOT touch `ecosys-ng/src/soil/solute/phosphate_network.zig` (CLAUDE is editing it).
Write ≤400 words to `.agent/adversarial/round_00003_deepseek.md` with the diff summary (file:line).
Reply `DONE <path>`.
