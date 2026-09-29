# Architecture Design: Round 00025 — Pre-Solve Water Pair Projection (Legacy RHHX Entry Reset)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Objective**: Port legacy SOLUTE iteration-start $H^+ / OH^-$ equilibration (`f77src/solute.f:824-853`) to `ecosys-ng`'s SOLUTE entry (`soil/solute/reaction_solve.zig:955-965`), placing post-tillage states directly on the water manifold.  

---

### 1. Element, Charge, and Solvent Accounting Across SOLUTE

- **Element Inventories (`AcceptedStateInventory`)**:  
  `AcceptedStateInventory` (`reaction_solve.zig:414-430`) tracks 15 physical elemental and site pools: C, N, P, Al, Fe, Ca, Mg, Na, K, S, Cl, Si, CEC charge, and non-band/band P sites. **Free $H^+$ and $OH^-$ are not independent elemental inventory coordinates** in this census.
- **Charge Conservation (`reaction_charge.zig:40-79`)**:  
  Net charge is $\sum q_i c_i = \dots + [H^+] - [OH^-] + \dots$  
  Water projection enforces $\Delta [H^+] = \Delta [OH^-] = -RHHX/\gamma_1$.  
  Therefore, $\Delta \text{Charge} = \Delta [H^+] - \Delta [OH^-] = 0$. Net charge is **identically conserved**.
- **Solvent Water Balance (`chemistry_state.zig:271-287`)**:  
  `accepted_water_equilibrium_extent_mol_per_m3` is passed to `chemistry_state.publishAcceptedWaterEquilibriumBalance` at `stages/soil_chemistry_convergence.zig:611-615` to update `state.water_equilibrium_balance_mol[layer] += \Delta W \cdot V_{water}`.  
  The pre-solve projection extent $RHHX$ must be **added to `result.accepted_water_equilibrium_extent_mol_per_m3`**, exactly as legacy does with `TBH2O(L) += RHHX`.
- **Accepted-State Conservation Gate (`reaction_solve.zig:735-775, 958-961`)**:  
  `original_state` is packed at line 958. To avoid treating $RHHX$ as an unclosed drift between entry and exit, either:
  1. Project $H^+ / OH^-$ **before** `state.packCell(cell_index, workspace.rollback_state)` (at line 957), updating `original_state`, OR
  2. Include entry extent in `original_state`'s water extent. Updating `state.aqueous` at line 957 before `rollback_state` is packed makes `original_state` start directly on the manifold.

---

### 2. Helper & Extent Publication

`water_equilibrium.projectProvisional` (`soil/solute/water_equilibrium.zig:252-295`) implements the exact legacy $RHHX$ formula.

#### Pseudo-diff in `soil/solute/reaction_solve.zig`:
```zig
// In solveCellWithWorkspaceAndTrace (lines 957-965)
try validateAqueousMolarity(state, cell_index);

// --- DEV-014: Legacy solute.f:824-853 RHHX entry water projection ---
const entry_coeffs = try state.activityCoefficients(cell_index, parameters.fractions);
const entry_water = try water_equilibrium.projectProvisional(
    state.aqueous[cell_index].hydrogen,
    state.aqueous[cell_index].hydroxide,
    entry_coeffs.monovalent_activity_coefficient,
    parameters.water_activity_product_mol2_per_m6,
);
state.aqueous[cell_index].hydrogen = entry_water.hydrogen_concentration_mol_per_m3;
state.aqueous[cell_index].hydroxide = entry_water.hydroxide_concentration_mol_per_m3;
const entry_water_extent = entry_water.equal_reaction_extent_mol_per_m3;

try state.packCell(cell_index, workspace.rollback_state);
const original_state = workspace.rollback_state;
...
try rebaseEntryCarboxylCapacity(state, cell_index, parameters);
...
// Add entry_water_extent to final result:
var final_result = if (!hasKineticGeochemistry(parameters)) first else combineResults(first, second);
final_result.accepted_water_equilibrium_extent_mol_per_m3 += entry_water_extent;
return final_result;
```

---

### 3. Activity Coefficient

- Legacy uses `A1(L,NY,NX)` computed in `hour1.f:4045`.
- In `ecosys-ng`, this is `(try state.activityCoefficients(cell_index, parameters.fractions)).monovalent_activity_coefficient` (`activity_coefficients.zig:58`).

---

### 4. Risk & Invariance Analysis

- **On-Manifold Hours**: When entry is already in water equilibrium ($[H^+][OH^-]\gamma_1^2 = K_w$), `activity_difference = discriminant`, yielding `entry_water.equal_reaction_extent_mol_per_m3 == 0.0`.
- $[H^+]$ and $[OH^-]$ are unchanged (within float roundoff $\le 1\text{ ulp}$), preserving bit-for-bit behavior across clean hours while eliminating the $45.5\text{ mol/m}^3$ non-equilibrium shock after tillage.
