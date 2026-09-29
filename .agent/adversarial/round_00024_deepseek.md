# Adversarial Review: Round 00024 — Topsoil Microbial Zone Draw & Dual-Domain Macropore Stagnation

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**:  
1. `surface/topsoil_zone_draw.zig` & `autotrophic_complex_step.zig:685-705`, `metabolism_state_update.zig:312-335` (Nutrient uptake zone capping)  
2. `soil/water/solver_residual.zig:370-445` (Dual-domain exchange bound & `ZEROS2` gate)  
**Legacy Sources**: `f77src/nitro.f:2382-2388, 3942-3946`, `f77src/watsub.f:6512-6530`, `f77src/hour1.f:3300-3315`

---

### A. Topsoil Mineral Nutrient Zone Draw (`topsoil_zone_draw.zig`)

1. **Legacy Mechanism & Clamping**:
   - In `f77src/nitro.f:2382-2386`, residue uptake $RINO3R$ is bounded by total column availability.
   - In `nitro.f:3942-3946`, the decrement is split between non-band ($FNO3S$) and band ($FNO3B$):
     $$TRINO += RINO3R \cdot FNO3S, \quad TRIOB += RINO3R \cdot FNO3B$$
     where $FNO3S, FNO3B$ are volume fractions ($VLNO3, VLNOB$).
   - When a band shrinks ($VLNOB \ll 1$), legacy computes $ZNO3B = ZNO3B - TRIOB \cdot \Delta t$, which can drift below zero if uptake exceeds the band's tiny portion.
   - **Where does legacy clamp?** In `f77src/hour1.f:3307, 3855`, legacy resets $ZNO3BX = \max(0, ZNO3B)$ and $CNO3B = \max(0, ZNO3B / VOLW)$. Negative band amounts are silently erased as numerical dust in `hour1.f`, creating an unclosed mass generation.
2. **Evaluation & Registration**:
   - `zoneConcentrationDecrements` caps draw at available zone mass and shifts the remainder to the non-band zone.
   - This prevents false `InsufficientTopsoilMineralNutrient` while conserving total element uptake bit-for-bit.
   - **Verdict**: **ACCEPT**. Because it deviates from legacy's unclosed negative excursion, **register as DEV-013** in `audit/intentional-deviations.md`.

---

### B. Dual-Domain Water Solver Stagnation (`solver_residual.zig:370-445`)

1. **Elimination of Kinked Bound**:
   - Previously, `flux.zig:169-172` used $\min(\text{current}, \text{assembled})$, enforcing exchange $= x$ when demand $> x$, creating an artificial kinked fixed point $x = b - x \implies x = b/2$ where Newton steps stall.
   - Removing `current` from the bounds and using `assembled` ($target$) directly matches `watsub.f:6525-6530`:
     $$FINHL = \min(FINHX, VOLWH2, VOLP2)$$
     where $VOLWH2, VOLP2$ are post-cycle assembled stores ($target$).

2. **Can Assembled-Only Bounds Overdraw (Negative Target)?**:
   - **No**. In `solver_residual.zig:370-450`, face fluxes and boundary drainage are assembled into `target` *before* the dual-domain exchange block.
   - Dual-domain exchange bounds:
     `macropore_water_m3 = assembled_macropore_water`
     and sets `target[cells + cell] -= exchange_m3`.
   - Because $exchange \le assembled\_macropore\_water = \max(0, target[cells + cell])$, the subtraction can never drive $target$ below zero.

3. **Validity of `boundary_face_area_m2` for `ZEROS2` Gate**:
   - In `heat_step.zig:1817`, `properties.boundary_face_area_m2 = workspace.plan_area_m2`.
   - `plan_area_m2` (`heat_step.zig:1101`) is initialized per layer to the cell's ground surface area ($Area = dx \cdot dy$).
   - In `watsub.f:6512`, `ZEROS2 = 1.0E-6 * AREA(3,N3,N2,N1)`. Using `1.0e-6 * properties.boundary_face_area_m2[cell]` is an **exact match**.

---

### Verdict: ACCEPT both A and B (Register A as DEV-013)
