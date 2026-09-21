# Adversarial Review Round 7: Diff Audit for Design A (Post-Tillage Pore Capacity Relief)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial audit of `pore_capacity_relief.zig`, wiring in `runtime_adapter.zig`, and fixture modification in `tillage_adapter_compile_test.zig`.

---

### E1. Fixture Change in `tillage_adapter_compile_test.zig:86-87`
**VERDICT: DEFENDED AS A GENUINE FIXTURE INCONSISTENCY (NOT A RETROFIT).**
- `tillage_adapter_compile_test.zig:94-98` explicitly sets layer volume `volume = [1.0, 1.0]` and porosity `porosity = [0.5, 0.4]`.
- Physical pore capacity is definitionally `volume * porosity = [0.5, 0.4]`.
- Prior to your change, `Grid.init` left `grid.matrix_pore_capacity_m3` default-initialized to `0.0`.
- The fixture simultaneously set `grid.matrix_liquid_water_m3[0] = 0.1` while claiming pore capacity was `0.0`—a physical impossibility that only passed previously because `apply()` never audited pore capacity.
- **Counter-check**: If a fixture asserts non-zero liquid in a medium with zero pore capacity, rejecting it with `TillagePoreReliefSurfaceOverflow` was correct behavior. Populating the mirror to match the fixture's own declared porosity is physically necessary.

### E2. Safety of Modifying `physical_gas.matrix_water_m3` Pre-Commit
**VERDICT: SAFE AND INTERNALLY CONSISTENT.**
- Traced `runtime_adapter.zig:1034-1044`:
  1. `context.grid.matrix_liquid_water_m3` and `matrix_ice_water_m3` are updated directly via `@memcpy` from `physical_gas.matrix_water_m3` and `matrix_ice_m3`.
  2. `context.grid.liquid_water_m3` is immediately derived as `physical_gas.matrix_water_m3 + macropore_liquid_water_m3`.
  3. `scatterTransportOwnersAssumeValid` takes `physical_gas`, keeping gas/transport mirrors consistent.
  4. Organic matter balances (`organic_after_soil`) and gas closures are evaluated *before* line 1014; since pore relief only moves liquid water between layers, organic mass closures remain untouched.
- No downstream consumer re-reads water from an un-relieved pre-tillage buffer.

### E3. Loop Traversal and Cascade Ordering (`pore_capacity_relief.zig:114-131`)
**VERDICT: SOUND BUT CONSERVATIVELY ONE-WAY (DEEPEST TO SHALLOWEST).**
- Loop executes `while (layer > 1) { layer -= 1; ... }`, scanning from `layers - 1` down to `1`.
- Any excess in layer `i` is pushed to `i - 1`. When the loop reaches `i - 1` on the next iteration, `occupied` evaluates against the *newly increased* water in `i - 1`.
- It cannot skip an excess: any displaced excess cascades monotonically upward until it reaches layer 0 or is fully absorbed by available air space.
- Limitation: It does not downward-drain (which legacy vertical displacement also does not do for freezing/overfill relief; `FLQL` moves upward).

### E4. Silent Handling of Ice-Dominated Overfill (`unrelievable_m3`)
**VERDICT: ACCEPTABLE, PRESERVES DOWNSTREAM DIAGNOSTIC INTEGRITY.**
- If ice causes the overfill, liquid cannot relieve it without melting ice (which tillage does not do).
- Bailing out immediately would mask whether subsequent liquid layers could be relieved.
- Allowing `unrelievable_m3` to fall through to `runtime_material_refresh.zig:245` correctly attributes the eventual failure to the physical entry invariant rather than a tillage dispatch crash.
