# Feature ID: FEAT-015-WTHR-WEATHER-FORCING

Status: PARTIALLY_ASSESSED (source-audit; `wthr.f` is 625 lines and was FULLY read this pass -- full coverage)

## Scope and provenance

Legacy source: `f77src/wthr.f` (sha256 `6BF5262A7A84172DE5146593C7D500BABD1D587C5CFE545F1C87E99A166CD658`), **100% read**. Confirmed scope: assembles hourly meteorological drivers (temperature, radiation, vapor pressure, wind, rain/snow, irrigation) by disaggregating daily arrays (ITYPE=1) or passing through hourly arrays (ITYPE=2), derives solar geometry/sky radiative properties, applies optional climate-change perturbations, accumulates daily totals, sets a fire flag, sets sub-hourly cycle counts. A driver/preprocessor, not a physical process solver.

### 1. Daily-to-hourly diurnal temperature/vapor-pressure curve -- `preserved`

`wthr.f:110-138`, three-segment sinusoidal interpolation. Zig: `ecosys-ng/src/io/input/daily_weather_disaggregation.zig` (sha256 `2719EE3320C2903D669B41E272AB44DF3FC03416E8B49F731A201251EF96F01B`), `curveParameters`/`curveValue` (`:84-104`), exact segment conditions and phase constants (3.1416/1.5708/9.0/3.0). Two regression tests independently restate the Fortran arithmetic (not calling the candidate) to avoid a tautological pass.

### 2. Saturated vapor pressure -- `preserved`, with an adjacent already-corrected defect

`wthr.f:136-137,197-198,449-450`: `VPS=0.61*exp(5360*(3.661e-3-1/TKA))*exp(-ALTI/7272)`. Reproduced verbatim in three sites. **Standing-lesson finding**: `hourly_weather_observation.zig` (header: "A8a DISPOSITION: superseded, but it earned its keep first") is NOT the reachable production owner for the ITYPE=2 branch -- that's `ecosys-ng/src/io/input/hourly_weather_stream.zig` (sha256 `7D0DF9947DC3392CDF66CC74DD81EEEFFD039FFAB6AE3CBFC182D3AFF623E7BB`). The superseded module's existence exposed a real production gap: `wthr.f:199`'s cap `VPK=min(DWPTH,VPS)` was missing from the bound reader; fixed at `hourly_weather_stream.zig:174` (`capVapor`, citing `wthr.f:197-199`), live and tested (`:183-189`). Tag `WTHR-VPS-001`. **Disposition: `legacy-defect-corrected`.**

### 3. Solar geometry, cloudiness, sky emissivity, longwave radiation -- `preserved`

`wthr.f:228-280`: `RADZ=4.896*max(0,SSIN)`, `CLD=min(1,max(0.2,2.33-3.33*RADN/RADZ))`, `EMM=0.625*max(1,(1000*VPK/TKA)^0.131)*(1+0.242*CLD^0.583)`. Zig: `ecosys-ng/src/atmosphere/atmospheric_radiation.zig` (sha256 `84B4B21D2A5A739299BAEEB3DF37B68BE84E32A5DA627D9374F75E1967A1A390`, `prepare:17-73`) delegating to `sky_radiative_properties.zig` (sha256 `4BB3DB57D83B832131964F604D11C68D19D00681B0EDA3CA5A8E7F124FB707AA`, `derive:33-88`), exact constants including the phytotron branch (`CLD=0,EMM=0.97`, `wthr.f:261-262`). **Standing-lesson finding**: the file's own header documents `atmospheric_radiation.zig` once carried this arithmetic inline as an unbound duplicate of `sky_radiative_properties.zig`; a duplicate-owner screen flagged the pair and the inline copy was deleted in favor of the named module (not marked as a defect in either). Falsifiability-companion test confirms all branches are actually reached.

### 4. Rain/snow precipitation partition -- `preserved`

`wthr.f:147-159,201-208`, threshold `TSNOW=-0.25`, floor `0.1e-3`. Zig: `daily_weather_disaggregation.zig:61-67` (daily) and `hourly_weather_stream.zig:151-152` (hourly, live path -- `hourly_weather_observation.zig` restates the same logic but is the superseded module per finding #2).

### 5. Climate-change perturbation block -- `preserved`

`wthr.f:327-487`: seasonal index, `DTA`/`AMP`/diurnal `DHR=sin(0.2618*(J-(ZNOON+3))+1.5708)`, humidity rescale-then-clamp. Zig: `ecosys-ng/src/io/input/climate_change.zig` (sha256 `D1FBFC7B50ACFDA09E6EC34C8EE62EA066DE219A95EC5E079CDEDC3C91C5B80A`), `seasonIndex`/`apply` (`:50-79,162-164`), exact constants and order. Biological re-acclimation sub-block (`wthr.f:412-431`) exposed via `averageAirTemperatureChangeC` (`:81-94`, cites `wthr.f:392,412-431`), consumed at the composition root under tags `PLANT-ACCLIM-MODE2-001`/`SOIL-MOFFSET-001`, resolving to real populated modules (`plant/response/biological_climate_acclimation.zig:25`), not stubs.

### 6. Fire flag and sub-hourly cycle-count setup -- `preserved`

`wthr.f:548-561,589-622`. Zig: `management/disturbance_management_dispatch.zig:27-100` (constants `wthr_surface_fire_temperature_k=373.15`, `wthr_subsurface_fire_temperature_k=348.15` cited directly from `wthr.f:50`) and `core/iteration_control.zig`, which documents an adjacent already-corrected mistranslation (an `NPH*MXN` product conflating the legacy sub-hourly cycle count with an unrelated Newton-iteration ceiling).

### 7. Dormant subsurface-irrigation branch -- `preserved` (dormant, correctly)

`wthr.f:300-315`: depth-based irrigation split is commented-out in the Fortran itself; only the surface path executes. Zig: `ecosys-ng/src/management/irrigation_layer_routing.zig` (sha256 `BC7747F43AD68D1BE4FB718F5065788CAFBE536ECFF7777BF0C75EA7442775FC`, `:6-14`), tag `IRRIGATION-SUBSURFACE-DEAD-CODE-001`, dead branch correctly kept dead with a named regression test (`:248`).

## Acceptance and review

Author: this session's audit fork, 2026-09-18 (full-file coverage). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Six items `preserved`, one `legacy-defect-corrected` (closed). **No open gaps found in this file.** Every apparent "gap" (superseded module, inline-duplicate radiation copy, `NPH*MXN` mistranslation) traced to the actual bound call site and confirmed already fixed with a named tag/doc/regression test -- consistent with this session's standing methodology.
