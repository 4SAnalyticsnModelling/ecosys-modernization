# Adversarial Diagnosis: Round 00023 — Tillage Solution Mixing & Post-Tillage Equilibration

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: SOLUTE failure at hours 2538/2542/2544 (day 106, hours 18/22/24) following day 106 hour 12 tillage.  
**Legacy Reference**: `f77src/redist.f:12078, 12215-12380, 12462, 12725`, `f77src/solute.f:825-860, 2720-2750`  
**Modern Sources**: `ecosys-ng/src/redistribution/tillage/runtime_adapter.zig:2015-2018, 2290-2330, 2485-2515`, `ecosys-ng/src/soil/solute/reaction_solve.zig:955-965`, `ecosys-ng/src/soil/solute/water_equilibrium.zig:250-295`

---

### a. Legacy Tillage Species & Post-Tillage Equilibration

1. **Aqueous Species Mixed in Legacy (`f77src/redist.f:12215-12380`)**:
   - Nitrogen: $ZNH4S, ZNH4B, ZNH3S, ZNH3B, ZNO3S, ZNO3B, ZNO2S, ZNO2B$.
   - Salts & Ion Complexes: $ZHY, ZOH, ZAL, ZFE, ZCA, ZMG, ZNA, ZKA, ZSO4, ZCL, ZCO3, ZHCO3$, all 16 Al/Fe/Ca/Mg/Na/K hydroxide and sulfate pairs, and all aqueous phosphate species ($H0PO4\dots H3PO4$, $ZFE1P\dots ZMG1P$).
   - Aqueous $CO_2$: $CO2S$ is mixed explicitly at line 12462:  
     `CO2S(L) = TI*CO2S(L) + CORP*(FI*TCOZS - TI*CO2S(L)) + TX*CO2S(L) + CORP*CO2SH(L)`.
2. **Post-Tillage Re-equilibration**:  
   - **None in `redist.f` or `hour1.f`**. Neither `CALL STARTE` nor any analytical equilibrium routine is run after tillage.
   - **Legacy Inherent Relaxation**: In `f77src/solute.f:825-860`, legacy SOLUTE executes `RHHX = 0.5*(S0 - SQRT(S1))` at the start of iteration 1, immediately resetting $CHY1$ and $COH1$ to $K_w$ equilibrium, then iterates 60 Picard cycles without a convergence threshold.

---

### b. Linear Mixing of Dependent Water Ions ($H^+$ and $OH^-$)

- **Yes**. In `redistribution/tillage/runtime_adapter.zig:2016`, `salt_fields` includes `"hydrogen"` and `"hydroxide"`.
- `runtime_adapter.zig:2509` performs separate linear mixing of both $H^+$ and $OH^-$:
  $$H^+_{mix} = \sum f_i H^+_i, \quad OH^-_{mix} = \sum f_i OH^-_i$$
- When blending an acidic layer ($H^+ \gg OH^-$) with an alkaline layer ($OH^- \gg H^+$), linear averaging produces a mixture where **both $H^+$ and $OH^-$ are simultaneously large**, violating $K_w = [H^+][OH^-]\gamma_1^2 \sim 10^{-14}\text{ M}^2$ by orders of magnitude (observed $1.4\times 10^{-16}\text{ M}^2$ with both at $\sim 10^{-5}\text{ mol/m}^3$). This is identical to legacy's extensive $ZHY$ and $ZOH$ mixing.

---

### c. Evaluation of Minimal Legacy-Faithful Remedies

| Remedy Option | Mechanism & Conservation Assessment | Legacy Fidelity | Recommendation |
| :--- | :--- | :--- | :--- |
| **Option 1: Project Entry Water Equilibrium** | Call `water_equilibrium.projectProvisional` at SOLUTE entry (`reaction_solve.zig:962`) or post-tillage (`runtime_adapter.zig:2515`). Preserves net charge and activity difference $\Delta = a_{H} - a_{OH}$; extent $\Delta W$ added to solvent. | **High** (replicates `solute.f:845` $RHHX$ pre-solve reset). | **RECOMMENDED** |
| **Option 2: Temporary STARTE Budget** | Raise `max_iterations = 200` or invoke Anderson fallback for the post-tillage hour. | Low (does not fix non-convex initial point; high CPU). | Reject |

**Specific Implementation**:  
In `soil/solute/reaction_solve.zig:962`, beside `rebaseEntryCarboxylCapacity`:
```zig
const water_proj = try water_equilibrium.projectProvisional(
    state.aqueous[cell_index].hydrogen,
    state.aqueous[cell_index].hydroxide,
    (try state.activityCoefficients(cell_index, parameters.fractions)).monovalent_activity_coefficient,
    parameters.water_activity_product_mol2_per_m6,
);
state.aqueous[cell_index].hydrogen = water_proj.hydrogen_concentration_mol_per_m3;
state.aqueous[cell_index].hydroxide = water_proj.hydroxide_concentration_mol_per_m3;
```
This is strictly charge-neutral, elemental-conserving, eliminates the $45.5\text{ mol/m}^3$ initial $OH^-$ residual, and restores legacy's iteration-start water projection.
