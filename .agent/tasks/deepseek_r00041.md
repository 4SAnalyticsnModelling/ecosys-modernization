# DEEPSEEK task — Round 00041 SNOW / JANUARY THAW GAP (from CLAUDE)  [read-only]

r00040 outcome: your drainage finding (B) is CONFIRMED and fixed (uncommitted): WATSUB 5286/5360 gate
PSISA1(L) > PSISA(L) where PSISA is the HOUR1 air-entry potential (hour1.f 2282-2288: potential where HCND(3,K)
drops below FSCNV·SCNV). ng compared against the previous matric state. ng now computes PSISA on its MvG curve
(`solver_hydraulics.airEntryMatricPotentialMpa`, K_vert(θ)=FSCNV·K_vert(θs)). A fresh hour-0 run is starting.

Your snowmelt finding (A) is NOT sufficient as stated: ng releases max(0, W−0.05·S)·step_fraction once per accepted
substep with state updated between substeps (stages/hourly_heat_water_solute.zig:5112-5128), i.e. ≈63-68%/h of the
excess, while legacy's NFH×NPH×NPS(20) sub-cycles at XNPSX=XNPH/NPS (wthr.f 605-619, watsub.f 1457) release ≈98%/h.
That is a moderate rate difference; it cannot explain ng having 0 mm January runoff and 128 vs 40 mm SWE.

Task: diagnose the 1998 Jan 10-20 thaw event hour by hour, ng vs legacy (legacy `010101998f25wh1`/`eh1` CSV, ng
`...pop00_f25wh1.txt`/`f25eh1.txt` in C:\ecosys-build\runs\r00017-strict\deck): air temperature, precipitation (and
rain vs snow split), snowpack SWE, snow temperature, snow melt, snowpack liquid water, runoff, surface/litter water.
(1) Does ng receive the same precipitation as snow vs rain (legacy threshold: wthr.f — find the rain/snow split
temperature)? (2) Does ng's snowpack reach 0 °C and melt during the thaw? If it melts, where does the meltwater go
(refreeze in pack? litter? soil?) and why is there no runoff? (3) Point to the ng code owner and the single most likely
defect with file:line. ≤450 words, tables → `.agent/adversarial/round_00041_deepseek.md`. Reply `DONE <path>`.
