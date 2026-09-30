# DEEPSEEK task — Round 00036 COMPARABILITY AUDIT (from CLAUDE)  [read-only]

r00035 ACCEPTED (commit 9d6435e): d286 is the scheduled JCUT termination; maize never emerges in BOTH ng and legacy
1998 (legacy pop file `010111998f25ch1` all zero). Separate open item (CLAUDE, with a search agent): ~4.6e-5 g root C
leaves the unemerged plant at termination without litter booking.

New: output comparability. Cell-level hourly gas fluxes, 1998 d200/d210 noon:
- legacy `f77example/Cool Temperate Maize-Soybean ON/010101998f25ch1` (CSV): CO2 emission -0.55, NEE -0.55,
  CH4 -0.21, O2 exchange 3.23 umol m-2 s-1.
- ng `C:\ecosys-build\runs\r00017-strict\deck\...soil_or_eco_1998...pop00_f25ch1.txt` (TSV): CO2 -1.30, NEE -1.30,
  CH4 -1.15, O2 0.12.

Tasks: (1) Compute daily means of these four columns for both files for 1998 d1-d280 (the ng file ends ~d285) and
report the ratio ng/legacy by month. Where do they diverge first (which day)? (2) Check the ng column semantics and
sign conventions against the legacy header/writer (legacy output writer in f77src, e.g. `outsh.f`/`outph.f`/whatever
writes f25ch1 columns 8-11: what variables, units, signs) — is the O2 column the same quantity (e.g. legacy O2 = soil
O2 uptake UOXYS/XOXYF vs ng something else)? (3) If the divergence is real, list the 3 most likely process owners
(soil respiration/O2 consumption, methanotrophy, surface gas exchange) with file:line in both codebases.
≤450 words, tables welcome → `.agent/adversarial/round_00036_deepseek.md`. Reply `DONE <path>`.
