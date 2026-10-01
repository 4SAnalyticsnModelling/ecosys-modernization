# DEEPSEEK task — Round 00053 1998 COMPARABILITY AUDIT (ng r00019 vs legacy)  [read-only]

ng run r00019 (all fixes through 7ebb94a) has hourly outputs for 1998 d1 to ~d353 in
`C:\ecosys-build\runs\r00019-strict\deck\runottawa_output_files\modelled_outputs\` (carbon/heat_energy/nitrogen/
water ... `*_1998_*` files, e.g. f25ch1, f25eh1, f25wh1, f25nh1). Note ng hour index 0 = legacy hour 1.
Legacy reference outputs: `f77example/` (Ottawa 1998 hourly/daily files; same file stems).
For d1-d350 compute, ng vs legacy, and report a compact table:
(1) cumulative ET, drainage, surface runoff (mm); monthly mean topsoil θ and soil T at 2 depths;
(2) cumulative NEE, GPP, Reco (g C m-2) and monthly NEE;
(3) cumulative N2O, NO3 leaching, mineral N at d350 (g N m-2);
(4) SWE/snow days in Jan-Mar and Nov-Dec.
Then rank the 3 largest relative gaps that are NOT explained by DEV-020 (legacy snow ablation artifact) and for
each name the most likely legacy-vs-ng process difference with file:line pointers in `f77src/` and
`ecosys-ng/src/`. ≤500 words → `.agent/adversarial/round_00053_deepseek.md`. Reply `DONE <path>`.
