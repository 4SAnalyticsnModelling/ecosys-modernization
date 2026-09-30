# DEEPSEEK task — Round 00040 WATER BALANCE GAP (from CLAUDE)  [read-only]

r39 is RESOLVED by CLAUDE (commit 46b6623): the missing layer-2 carbon was the root→atmosphere aerenchyma flux of a
PFT deactivated mid-hour; ng now keeps a terminated PFT active until the hour closeout (HFUNC 118-120). Skip r39.

r38 ACCEPTED — two hydrology gaps drive the gas-flux divergence: (1) ng topsoil θw ≈0.55 vs legacy 0.31 Apr-Sep;
(2) ng Jan SWE 83.5 vs 25.8 mm (unfrozen soil under snow).

Task: decompose the 1998 water balance, ng vs legacy, monthly, from the hourly water outputs
(legacy `f77example/Cool Temperate Maize-Soybean ON/010101998f25wh1` CSV, ng
`C:\ecosys-build\runs\r00017-strict\deck\...soil_or_eco_1998...pop00_f25wh1.txt` TSV; also the daily `wd1` files if
useful). For each month: precipitation (rain vs snow if split), evapotranspiration / soil evaporation, snow
sublimation, surface runoff, drainage/deep percolation (lower boundary), change in soil water + snow storage.
Identify the component(s) that differ most — e.g. ng evaporation ≈0, ng drainage ≈0 (lower boundary closed?),
different rain/snow split (air-temperature threshold), missing snowmelt. Then point to the owning code in both
codebases (legacy watsub.f / wthr.f / hour1.f; ng soil/water, surface, snow, weather) with file:line and the
single most likely defect. Check the deck's lower boundary settings (site/soil file: drainage flags, water table
depth) and how ng reads them (driver/runscript.zig). ≤450 words, tables → `.agent/adversarial/round_00040_deepseek.md`.
Reply `DONE <path>`.
