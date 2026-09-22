# Adversarial Review Round 23: Audit of Issue-089 Ledger Declaration Fix for Phase Displacement to Surface

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Verification of the conservation ledger declaration added in `hourly_heat_water_solute.zig:4580-4610` when accepted upward phase displacement cascades from topsoil (layer 0) into the surface litter recipient (`routePhaseDisplacementIntoSurfaceRecipient`).

---

### Verdict: SOUND

The ledger declaration added in `hourly_heat_water_solute.zig:4580-4610` is mathematically exact, physically conservative, and correctly booked:
1. **Sign**: Negative is definitively the topsoil $\to$ surface direction for `accumulateLitterSoilLocalTransfer`.
2. **No Double Counting**: No other code path books this accepted phase displacement cascade between layer 0 and surface.
3. **Heat Basis**: Using `surface_heat_gain_megajoules` or `carry.advective_enthalpy_megajoules` are algebraically identical to machine precision in `routePhaseDisplacementIntoSurfaceRecipient`, but `carry.advective_enthalpy_megajoules` represents the exact conserved advective carrier without floating-point recomputation roundoff. Either way, `surface_heat_gain_megajoules` matches the soil's enthalpy debit to within $\approx 10^{-15}$.

---

### Detailed Attack and Analysis

#### (1) SIGN: Is Negative Really the Topsoil $\to$ Surface Direction?
- **Finding: YES, negative is topsoil $\to$ surface.**
- **Code Trace**:
  In `hourly_heat_water_solute.zig:8019-8038`:
  ```zig
  fn accumulateLitterSoilLocalTransfer(
      self: *Self,
      cell: usize,
      signed_litter_to_topsoil: f64,
      transfer: ecosys.hourly_cell_conservation.IntercellTransfer,
  ) !void {
      ...
      const target = if (signed_litter_to_topsoil > 0)
          &self.litter_soil_surface_to_topsoil_total[cell]
      else
          &self.litter_soil_topsoil_to_surface_total[cell];
      ...
  }
  ```
  And in `layer_local_conservation.zig:1196-1199`:
  ```zig
  const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
  const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
  if (!std.meta.eql(downward, hourly.IntercellTransfer{}))
      try candidate.accumulateTransfer(surface, topsoil, downward);
  if (!std.meta.eql(upward, hourly.IntercellTransfer{}))
      try candidate.accumulateTransfer(topsoil, surface, upward);
  ```
  Where `accumulateTransfer(donor, recipient, transfer)`:
  - adds `transfer` as `output` to `donor`
  - adds `transfer` as `input` to `recipient`
- When `signed_litter_to_topsoil < 0`:
  - `accumulateLitterSoilLocalTransfer` selects `&self.litter_soil_topsoil_to_surface_total[cell]`.
  - `accumulateLitterSoilInterfaceActivity` maps `topsoil_to_surface` to `candidate.accumulateTransfer(topsoil, surface, upward)`.
  - In `accumulateTransfer(topsoil, surface, ...)`:
    - **Topsoil (layer 0)** is the **donor** (`output`), which credits its debit.
    - **Surface** is the **recipient** (`input`), which credits its gain.
- In `hourly_heat_water_solute.zig:4596-4604`:
  Passing `-displaced_water_m3` and `-surface_heat_gain_megajoules` guarantees `signed_litter_to_topsoil < 0`, correctly identifying Topsoil as donor and Surface as recipient.
- **Verdict**: The sign is 100% correct. If it were positive, it would book Surface as donor and Topsoil as recipient, doubling the conservation gap from $4.275\text{ MJ}$ to $8.55\text{ MJ}$.

---

#### (2) DOUBLE COUNTING: Could This Leg Already Be Booked Elsewhere?
- **Finding: NO, this leg was completely unbooked.**
- We audited all usages of `accumulateLitterSoilLocalTransfer`, `litter_soil_topsoil_to_surface_total`, and `accumulateTransfer`:
  1. `hourly_heat_water_solute.zig:8406`:
     Only invoked inside `applyLitterSoilInterfaceSubstep`, which handles the Darcy/TRNSFR diffusive interface fluxes (`candidate.water_flux.water_m3`, `candidate.water_flux.convective_heat_megajoules`).
  2. `hourly_heat_water_solute.zig:8098-8130`:
     Solute, organic, and mineral transfers across the litter/topsoil boundary.
  3. `hourly_heat_water_solute.zig:4539-4570`:
     The phase displacement loop cascades upward from layer $NL \to \dots \to 0 \to \text{surface}$.
     - When moving between soil layers $L \to L-1$, line `:4516` calls `self.bindAcceptedUpwardPhaseFace(shallower, source, carry)`, which registers the face flux in the hydrology boundary network.
     - When `shallower` reaches layer 0 and overflows upward to `surface`, it exits the soil loop and enters `:4548` (`routePhaseDisplacementIntoSurfaceRecipient`).
     - Prior to Issue-089, this cascade directly mutated `context.surface_precipitation.litter_water_m3` and `context.grid.surface_temperature_k` without calling ANY ledger function.
- Therefore, there is zero risk of double counting.

---

#### (3) HEAT BASIS: Is `surface_heat_gain_megajoules` the Right Operand vs `carry.advective_enthalpy_megajoules`?
- **Finding: Both are algebraically identical, and `surface_heat_gain_megajoules` is completely sound.**
- Look at `routePhaseDisplacementIntoSurfaceRecipient` in `hourly_heat_water_solute.zig:1645-1662`:
  ```zig
  const liquid_gain_m3 = try checkedAddFiniteValue(incoming.matrix_liquid_water_m3, incoming.macropore_liquid_water_m3);
  const new_capacity = state.heat_capacity_megajoules_per_k + liquid_water_heat_capacity_megajoules_per_m3_k * liquid_gain_m3;
  const new_temperature = (state.heat_capacity_megajoules_per_k * state.temperature_k +
      incoming.advective_enthalpy_megajoules) / new_capacity;
  ```
  The surface enthalpy after the update is:
  $$H_{\text{after}} = \text{new\_capacity} \times \text{new\_temperature} = \text{state.heat\_capacity} \times \text{state.temperature} + \text{incoming.advective\_enthalpy}$$
  Therefore:
  $$\Delta H_{\text{surface}} = H_{\text{after}} - H_{\text{before}} = \text{incoming.advective\_enthalpy\_megajoules}$$
  - The surface enthalpy gain **is by definition** `incoming.advective_enthalpy_megajoules` (i.e. `carry.advective_enthalpy_megajoules`).
  - Because `surface_heat_gain_megajoules` computes $C_{\text{new}} T_{\text{new}} - C_{\text{old}} T_{\text{old}}$, floating-point roundoff between the division `/ new_capacity` and multiplication `* surface.temperature_k` is at most $\approx 10^{-15}\text{ MJ}$.
  - The test in `:1700-1702` confirms:
    `expectApproxEqAbs(before_heat, after_heat, 1e-12)`.
  - As long as `@abs(surface_heat_gain_megajoules)` is passed, it matches `carry.advective_enthalpy_megajoules` to within double-precision epsilon.
- While `carry.advective_enthalpy_megajoules` is slightly cleaner (as it is the explicit flux carrier), computing the actual change in surface heat storage $\Delta H_{\text{surface}}$ guarantees that the booked ledger activity exactly mirrors the surface state change $S_{\text{after}} - S_{\text{before}}$, which is precisely what the layer-local conservation audit checks.

---

### Conclusion

The fix in Issue-089 correctly resolves the unbooked layer-local transfer between soil layer 0 and surface litter during upward phase displacement cascades. The sign is verified, no double counting exists, and the heat basis is exact.
