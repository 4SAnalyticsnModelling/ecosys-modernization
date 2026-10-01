# DEEPSEEK task — Round 00052 CHALLENGE commit 7ebb94a (exact pre-HOUR1 band fraction)  [read-only]

Outcome of r51: the layer-10 loss was NOT SOLUTE speciation. Trace (hour 5012, layer 10): band NH4 6.5504e-9 ->
6.5174e-9 g and band NH3 shrank by the same factor 0.99495 in the uptake stage, total 3.3183e-11 g = the closure
residual exactly. Cause: ng stores zone CONCENTRATIONS; during the HOUR1->SOLUTE window `scienceZoneFractions`
rebuilt the old band as 1 - VLNH4'/(1+FVL), which for a 1.0154e-14 band gives 1.0103e-14 (catastrophic
cancellation), so C*W*f lost 0.5% of the sliver. Legacy holds AMOUNTS (ZNH4B), so it has no such loss.
Fix (commit 7ebb94a): the phase coordinator records the exact pre-prepare band fraction per family/layer;
`scienceZoneFractions` and SOLUTE `repartitionConcentrations` use it when FVL != 0 (non-band side unchanged); a
checkpoint restored mid-hour falls back to the reconstruction. Files: `ecosys-ng/src/management/
fertilizer_band_phase_coordinator.zig`, `fertilizer_band_state.zig` (exactPreConsumptionBand),
`fertilizer_band_production.zig`.
Attack it: (1) is any consumer still using `zoneFractions` (new geometry) or the old reconstruction on
concentration owners during the window? (grep the callers); (2) is the FVL==0 shrink path still consistent with
`preserveZoneAmountsAfterPrepare`; (3) is non_band + band != 1 (by ~1e-16) harmful anywhere (validators with a sum
tolerance)? (4) anything legacy does in hour1.f 4900-4990 / solute.f 3761-3913 that this representation still
misses? ≤400 words → `.agent/adversarial/round_00052_deepseek.md`. Reply `DONE <path>`.
