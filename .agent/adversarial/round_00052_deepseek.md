# Round 00052: Challenge of Commit 7ebb94a (Exact Pre-HOUR1 Band Fraction)

## 1. Consumers of `zoneFractions` vs `scienceZoneFractions` During the Window
- **Grep Audit of Callers**:
  - `scienceZoneFractions`: Used by all concentration/amount materializers during the prepared window, including `soil_chemistry_convergence`, `root_processes_uptake`, `biogeochemistry_batches` (`nitrification`, `chemodenitrification`, `nitrogen_state_update`), and `repartitionConcentrations`.
  - `zoneFractions`: Only called by non-solute structural consumers:
    1. `fertilizer_management_dispatch.zig`: Tillage/fertilizer application (idle phase).
    2. `fertilizer_band_production.zig:186`: `consumeUndissolved` (takes newly expanded geometry `now`).
    3. `relayering.zig:1154`: Geometry relayering (runs during REDIST).
- **Finding**: No concentration owner reads `zoneFractions` while holding pre-expansion concentrations. All chemistry consumers use `scienceZoneFractions`, which returns the recorded pre-prepare fraction.

## 2. Consistency of `FVL == 0` Shrink / Non-Expansion Path
- In `hour1.f:4960`, `FVLNH4 = AMIN1(0.0, (VLNH4_new - VLNH4_old) / VLNH4_old)`. When a band shrinks or is unchanged, $VLNH4_{	ext{new}} \ge VLNH4_{	ext{old}} \implies FVL = 0$.
- In `fertilizer_band_state.zig:608-610`:
  `if (relative_non_band_change == 0) return reconstructed_band;`
- **Consistency**: In legacy, a shrink event immediately amalgamates or rescales state onto the new boundary (`hour1.f:4969-4975`), so `current_non_band` already represents the valid concentration basis. Keeping `reconstructed_band` when $FVL == 0$ is fully consistent with `preserveZoneAmountsAfterPrepare`.

## 3. Does $f_{	ext{non\_band}} + f_{	ext{band}} 
e 1$ (~1e-16) Harm Any Validators?
- `plant_available_nutrients.zig:16-18`: `|f_non_band + f_band - 1| > 1.0e-12`.
- `repartitionConcentrations`: `@abs(new_non_band + new_band - 1) > 1.0e-12`.
- `aqueous_transport_bridge.zig:289`: `32 * eps ~ 7.1e-15`.
- Floating-point discrepancy between `old_non_band = current / (1+FVL)` and exact `old_band` is bounded by $\epsilon pprox 2.2 	imes 10^{-16} \ll 10^{-12}$, safely within all validator tolerances.

## 4. Legacy Process Audit (`hour1.f:4900-4990`, `solute.f:3761-3913`)
- `solute.f:3786-3794`: Band expansion transfers solute mass from non-band to band via $D = FVL \cdot Z_{	ext{non-band}}$, leaving non-band concentration $C_{	ext{non-band}}$ invariant while diluting $C_{	ext{band}}$.
- `repartitionConcentrations` implements this exact dilution:
  `next_band = (old_band * C_band - relative * old_non_band * C_non_band) / new_band`
- Recording `exactPreConsumptionBand` eliminates the catastrophic cancellation $1 - rac{1 - 10^{-14}}{1 + FVL}$, preserving mass to machine precision without altering legacy physics.

## Verdict
**Commit 7ebb94a is verified robust and sound.** No un-migrated consumers exist, tolerances are satisfied, and mathematical conservation across band slivers is restored.
