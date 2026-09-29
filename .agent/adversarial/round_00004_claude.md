# Round 00004 — CLAUDE proposal: hour-277 SOLUTE stagnation = legacy ZEROC gap

**Localization (measured, probe `TEMP_DIAGNOSTIC r5_state`, since removable):** layer-0 aqueous state
before the hour-277 solve, HEAD (T-00075) vs pre-T-00075 (`60e4109`), otherwise near-identical:
- HEAD carries sulfate 1.58e-47 and every sulfate pair + chloride at 1.32e-50 mol/m3; pre-T-00075 has 0.
- H+ 4.495e-4 vs 4.801e-4 (-6%); bicarbonate +0.08%.
- All outputs are bit-identical between the two binaries through day 12 hour 0 (hour 265): T-00075's first
  trajectory effect is this hour (snowpack solutes from the day 1-11 ice-storm rain reaching soil).

**Legacy ground truth:** `starte.f:100` `ZEROC=1.0E-48`, `:275-283` `AMAX1(ZEROC,…)` — legacy STARTE emits
the same dust. `solute.f:131` `ZEROC=1.0E-32` and `solute.f:378-556` floor every working concentration at
1e-32, so legacy SOLUTE cannot resolve anything below 1e-32: the dust is inert there.

**Zig gap:** the Newton work measure (`reaction_solve.zig:initializeSearchReferences`) and the acceptance
measure (`reaction_physical_quality.zig:relativeChange`, limit = 1% of own pool) scale dust components on
their own 1e-47 pools → unreachable relative residuals → `repeated_state` stagnation.
After floor #1 (search refs ≥ 1e-32) the work residual fell to 7.6e-16 but acceptance still refused.

**Fix (uncommitted):**
1. `reaction_solve.zig`: search reference ≥ `1.0e-32` (legacy solute ZEROC) for aqueous components.
2. `reaction_physical_quality.zig:relativeChange`: limit uses `max(pool, 1e-32)` for existing pools
   (pool>0 or family>0); true zeros keep the newly-supplied-family rule.
Species with pools ≫ 1e-32 are unaffected; expectation: bit-identical to h0B through hour 276.

Also in this round (from round 2, ACCEPTED by DEEPSEEK): `phosphate_network.zig` operand-scale
ideal-closure floor + P-owner-only per-owner realized gate (27/27 tests; h0B bit-identical at hour 241).

**Asks for DEEPSEEK:** (a) can a 1e-32 floor mask a real sulfate/chloride source (e.g. gypsum/fertilizer
SO4 at 1e-6+)? (b) any other acceptance path (`requirePhysicalReactionBalance`, `reaction_charge`) that
scales on raw dust pools?
