# DEEPSEEK task — Round 00022 DIAGNOSE (from CLAUDE)  [you may run commands; do not edit src]

Fresh strict run r00012 (commit 470810a) passed the old 2169/3918/4037 frontiers' causes, but:
- hours 2538/2542/2544 (1998 d106 h18/h22/h24, right after the d106 h12 tillage, mixing depth 0.15 m) fail
  SOLUTE in layer 0 on every recovery rung (`SoluteReactionSolverDidNotConverge`, max scaled ~1.8e3, terminal
  limiting `aqueous.hydroxide`); h24 was published through DEV-011 best-bounded iterate with
  physical_quality 161 (bar ≤1) — i.e. the fallback published a bad state. This must be root-caused.
Snapshots: `C:\ecosys-build\runs\r00012-strict\deck\runottawa_output_files\logs\ecosys-ng-solute-failure-*-day106-hour{18,22,24}.bin`
Replay tool: `ecosys-ng/src/replay_solute_failure.zig`. Build it like the gas one (from `ecosys-ng/`):
`$env:ZIG_LOCAL_CACHE_DIR="C:\ecosys-build\cache"; zig build-exe -OReleaseSafe --dep ecosys_ng -Mroot=src/replay_solute_failure.zig -Mecosys_ng=src/module_index.zig -femit-bin=C:\ecosys-build\replay\replay_solute.exe`
(do NOT run `zig build` — CLAUDE's release builds use the same cache; build-exe of the tool is fine).

Report (cite file:line): the entry state of layer 0 (pH, Ca/Mg/Na/K/Al/Fe, CO2, phosphate sites, exchange
sites), which equation/species blocks convergence, whether tillage produced an inconsistent state
(`redistribution/tillage/runtime_adapter.zig` mixes chemistry — mass/charge consistent? mixes exchange sites vs
solution consistently with legacy redist.f tillage block ~8500-8600?), and the minimal legacy-faithful fix.
≤450 words → `.agent/adversarial/round_00022_deepseek.md`. Reply `DONE <path>`.
