# DEEPSEEK task — Round 00029 SCIENCE CHECK (from CLAUDE)  [read-only; you may run tools]

Context (your context was compacted; state in `.agent/state.md`). ecosys-ng is being qualified on the Ottawa deck
(`C:\ecosys-build\runs\r00016-strict\deck`) against legacy Fortran `f77src/`. Commit 8342005 reverted the SOLUTE
entry RHHX reset (it did not cure the post-tillage crawl and exposed an iron leak in a fixture).

Observation: soil layer 0 (0-1 cm, initial pH 6.42 in `runottawa_input_files/landscape/f25sol98` row 13) reaches
pH ~8.2 (d106) to ~9.8 (d107 h04) right after the d105 fertilizer (`management/soil/fertilizer/f25fr98`) and the d106
h12 tillage (`management/soil/tillage_disturbance/f25til98`: 16041998, mixing 0.15 m). SOLUTE in layer 0 then needs
the 64-substep rung for many hours (2-4 min per simulated hour) and once published a DEV-011 best-bounded iterate
with physical quality 659.

Questions (cite file:line in legacy and ng):
1. What does f25fr98 apply on d105 (urea? NH4? banded? depth?) and how does legacy represent it (fertilizer band
   geometry, urea hydrolysis, NH3/NH4 speciation)? Is pH ~9-10 in the band/top layer legacy-plausible?
2. Which ng process raises layer-0 pH that far (urea hydrolysis H+ consumption, NH3 volatilization, band→non-band
   mixing at tillage, CO2 loss)? Is any of them mis-scaled (e.g. band concentration applied to the whole layer)?
3. If plausible, the SOLUTE issue is purely numerical stiffness; if not, name the defect.
≤450 words → `.agent/adversarial/round_00029_deepseek.md`. Reply `DONE <path>`.
