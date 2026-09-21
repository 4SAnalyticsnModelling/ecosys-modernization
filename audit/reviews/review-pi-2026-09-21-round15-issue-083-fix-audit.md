# Adversarial Review Round 15: Issue-083 Mechanical Excess-Relief Fix Audit

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial verification of the fix for Issue-083 in `ecosys-ng/src/soil/water/solver_residual.zig`:
1. Removal of `limitFluxForAssembledTarget` from `applyMechanicalFreezingDisplacement` (donor-only bound).
2. Moving `applyMechanicalFreezingDisplacement` before the per-cell `acceptedEntryLiquidCeilingM3` loop.
3. Deriving the trial ceiling from `@max(base[cell], target[cell])`.

---

### Verdict: SOUND

The fix is rigorously sound and mathematically consistent with the legacy oracle:
1. **Conservation is strictly guaranteed**: `applyConservativeFlux` executes exact peer debits and credits on `target`, with no mass creation or destruction regardless of face ordering or column height.
2. **Non-negativity is preserved**: In `ecosys-ng`'s grid topology, vertical faces run strictly top-to-bottom ($L \to L+1$). Each layer acts as `destination` (donor) across at most one vertical face. Because `mechanicalFreezingDisplacementM3` bounds the upward flux by $-\text{target}[\text{destination}] \times \text{time\_fraction}$ with $\text{time\_fraction} \le 1.0$, `target[destination]` cannot be drawn negative.
3. **Ceiling remains optimizer-independent and tight**: `@max(base[cell], target[cell])` represents the union of the accepted entry state and the deterministic, physics-mandated prepass relocation. It admits neither optimizer-manufactured overfill nor false-positive rejections of prepass credits.

---

### Audit of Specific Questions

#### (1) Conservation: Can the relief term create or destroy water anywhere?
- **Finding: NO.**
- In `ecosys-ng/src/soil/water/solver_flux.zig:42-47`:
  ```zig
  pub fn applyConservativeFlux(
      target: []f64,
      source: usize,
      destination: usize,
      flux_m3: f64,
  ) void {
      target[source] -= flux_m3;
      target[destination] += flux_m3;
  }
  ```
- In `applyMechanicalFreezingDisplacement` (`solver_residual.zig:86, 142`), for upward flux $flux\_m3 \le 0$:
  - `target[source] -= flux_m3` (source/shallower recipient is credited: $-(-) = +$).
  - `target[destination] += flux_m3` (destination/deeper donor is debited: $+(-) = -$).
  - Net change across the pair $= (-flux\_m3) + (+flux\_m3) = 0.0$.
- Because `micro_fluxes[face_index] += matrix_flux` records the exact same quantity that modifies `target`, and the downstream residual computation evaluates `residual[cell] = trial[cell] - target[cell] + ...`, internal transfers conserve water to machine precision ($0.0$ drift).

#### (2) Non-negativity: Can `target[destination]` go negative under repeated faces?
- **Finding: NO.**
- **Topology Check**: In `ecosys-ng/src/transport/hydrology.zig:484`:
  ```zig
  if (layer + 1 < grid.active_soil_layer_count[horizontal])
      appendFace(..., first, try hydrology.soilIndex(column, row, layer + 1), 2, ...);
  ```
  Vertical faces are strictly constructed with `first = layer` (shallower, `source_cell`) and `second = layer + 1` (deeper, `destination_cell`). In a 1D column (or individual vertical column in a 3D grid), for any given layer $L$:
  - Layer $L$ serves as `source_cell` for the face connecting $L \to L+1$.
  - Layer $L$ serves as `destination_cell` for the face connecting $L-1 \to L$.
- Therefore, layer $L$ is evaluated as `destination_cell` (donor of upward displacement) **at most once per prepass execution**.
- **Donor Bounding**:
  `flux.zig:93-106` (`mechanicalFreezingDisplacementM3`) computes:
  $$\text{requested} = \min(0, \max(-\text{target}[\text{destination}] \times \text{time\_fraction}, \text{excess}))$$
  Since $\text{time\_fraction} \in (0, 1]$, $|flux| \le \text{target}[\text{destination}] \times \text{time\_fraction} \le \text{target}[\text{destination}]$.
- When `target[destination] += flux` is applied, the updated value satisfies:
  $$\text{target}[\text{destination}]_{\text{new}} \ge \text{target}[\text{destination}] \times (1.0 - \text{time\_fraction}) \ge 0.0$$
- Even if a layer was previously credited as `source` by a deeper layer $L+1 \to L$, that credit is strictly non-negative, which only *increases* available liquid before layer $L$ acts as donor (if faces were evaluated bottom-to-top; with top-to-bottom ordering, layer $L$ donates from its entry/source state, then receives credit from $L+1$). Neither ordering can produce a negative state.

#### (3) Ceiling: Is `@max(base[cell], target[cell])` ever looser than the oracle?
- **Finding: NO.**
- In the legacy oracle (`watsub.f:4898-4932`), after the mechanical freezing displacement is added, `VOLW2` is updated before the iterative solution or subsequent flux computations.
- In `ecosys-ng`, `base[cell]` is the accepted entry water, and `target[cell]` immediately after `applyMechanicalFreezingDisplacement` is:
  $$\text{target}[\text{cell}] = \text{base}[\text{cell}] + \text{external\_source}[\text{cell}] + \sum \text{relief\_credits} - \sum \text{relief\_debits}$$
  - For a **donor** layer: $\text{target}[\text{cell}] < \text{base}[\text{cell}]$. The term `@max(base[cell], target[cell]) = base[cell]`. The donor's trial ceiling remains capped at its accepted entry overfill. The optimizer cannot propose liquid higher than what the layer entered the hour with.
  - For a **recipient** layer: $\text{target}[\text{cell}] > \text{base}[\text{cell}]$ because it absorbed liquid mandated by the oracle's physics. The term `@max(base[cell], target[cell]) = target[cell]`. This permits the optimizer's candidate `trial[cell]` to reach the newly credited level without triggering a spurious `SoilWaterCandidateExceedsPoreCapacity`.
- Neither `base` nor `target` contains optimizer iterate values (`trial` or Newton step $\Delta x$). The ceiling is fixed at the start of residual assembly. It is strictly optimizer-independent.

---

### Conclusion

The fix directly restores the oracle's asymmetric handling of Darcy versus mechanical relief fluxes. It preserves conservation, maintains non-negativity across all vertical columns, and correctly accommodates the deterministic upward displacement of pore excess into shallower layers without loosening the solver's resistance to unphysical optimizer excursions.
