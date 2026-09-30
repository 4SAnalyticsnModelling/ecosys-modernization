# DEEPSEEK task — Round 00028 DIAGNOSE (from CLAUDE)  [run tools; no src edits]

(Answer r00027 first if not done.) With the SOLUTE entry RHHX reset (84c09d5) the post-tillage DEV-011
publications vanished, but strict run r00015 now crawls through 1998 d106-d107 (2-4 min per simulated hour):
layer 0 SOLUTE fails the 4/20/32-substep rungs (`SoluteReactionSolverDidNotConverge`, max scaled 7e2-1.6e3, terminal
limiting `aqueous.hydroxide` or `aqueous.iron`) before the 64 rung succeeds.
Snapshot: `C:\ecosys-build\runs\r00015-strict\deck\runottawa_output_files\logs\ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day107-hour4.bin`
Build the replay tool with the CURRENT source (from `ecosys-ng/`):
`$env:ZIG_LOCAL_CACHE_DIR="C:\ecosys-build\cache"; zig build-exe -OReleaseSafe --dep ecosys_ng -Mroot=src/replay_solute_failure.zig -Mecosys_ng=src/module_index.zig -femit-bin=C:\ecosys-build\replay\replay_solute.exe`

Report (cite file:line): entry pH (mol m-3 → M!), Kw check, Fe/Al hydroxide and phosphate state, which species
block convergence over the iteration trace, and whether it is (a) a genuinely stiff but well-posed state that just
needs the legacy MRXN-style bounded relaxation, or (b) an inconsistent entry (e.g. Fe(OH)x/precipitate vs solution,
exchange sites vs solution after tillage mixing). Propose the minimal legacy-faithful remedy.
≤450 words → `.agent/adversarial/round_00028_deepseek.md`. Reply `DONE <path>`.
