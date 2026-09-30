# Adversarial Diagnosis: Round 00028 — Post-Tillage SOLUTE Convergence Stagnation (Day 107 Hour 4)

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target Snapshot**: `runs/r00015-strict/.../ecosys-ng-solute-failure-*-year1998-day107-hour4.bin`  
**Symptom**: `SoluteReactionSolverDidNotConverge` on 4/20/32 substeps; 64-substep crawl takes 2–4 min per hour.  
**Legacy Reference**: `f77src/solute.f:111, 822-860, 2334-2450`, `f77src/redist.f:12128-12400`  
**Modern Source**: `ecosys-ng/src/soil/solute/reaction_solve.zig:1720-1760, 2840-2930`, `ecosys-ng/src/soil/solute/reaction_physical_quality.zig:74-125`

---

### 1. Snapshot Inspection: Layer 0 Entry State at Day 107 Hour 4

- **Aqueous Concentrations & pH**:
  - $[H^+] = 1.666\times 10^{-7}\text{ mol/m}^3 = 1.666\times 10^{-10}\text{ M} \implies \mathbf{pH = 9.778}$
  - $[OH^-] = 1.939\times 10^{-5}\text{ mol/m}^3 = 1.939\times 10^{-8}\text{ M}$
  - $[H^+] \cdot [OH^-] = 3.23\times 10^{-18}\text{ M}^2 \ll K_w \sim 10^{-14}$ ($\approx 3100\times$ below water equilibrium before entry reset).
- **Cations & Complexes**:
  - $[Ca^{2+}] = 9.48\times 10^{-5}\text{ mol/m}^3$, $[CaOH^+] = 1.02\times 10^{-10}\text{ mol/m}^3$, $[CaCO_3^0] = 3.54\times 10^{-7}\text{ mol/m}^3$
  - $[Al^{3+}] = 2.33\times 10^{-10}\text{ mol/m}^3$, $[Al(OH)_4^-] = 1.05\times 10^{-7}\text{ mol/m}^3$
  - $[Fe^{3+}] = 1.83\times 10^{-14}\text{ mol/m}^3$, $[Fe(OH)_4^-] = 5.32\times 10^{-11}\text{ mol/m}^3$
- **Phosphate & Exchange Sites**:
  - Deprotonated sites: $11.81\text{ mol/Mg}$; Hydroxyl sites: $7.80\text{ mol/Mg}$; Protonated: $4.18\times 10^{-3}\text{ mol/Mg}$.
  - Minerals: $AlPO_4 = 15.33\text{ mol/m}^3$, $FePO_4 = 9.38\text{ mol/m}^3$, Hydroxyapatite $= 3.41\text{ mol/m}^3$.
  - Cation exchange: $XCa = 78.85\text{ mol/Mg}$, $XN4 = 3.24\text{ mol/Mg}$, $XAl = 2.25\text{ mol/Mg}$.

---

### 2. Iteration Trace Analysis: Stagnation Mechanism

In `err28.txt`:
1. Iterations 0–2 rapidly resolve macro-imbalances: $H_2PO_4^-$ drops from $26.1$ to $10^{-2}$, $HCO_3^-$ / $CO_2$ adjust.
2. From **iteration 3 to 99**, the solver stalls in a persistent 2-cycle oscillation between:
   - Component 47 (`phosphate_non_band.protonated_site_mol_per_megagram`, state $\approx 2.18\text{ mol/Mg}$, residual $\approx -0.44$)
   - Component 45 (`phosphate_non_band.deprotonated_site_mol_per_megagram`, state $\approx 15.0\text{ mol/Mg}$, residual $\approx +0.44$)
3. At iteration 100, `limiting_component` jumps to `aqueous.hydrogen` with scaled residual $1.60\times 10^3$ (physical quality $1.60\times 10^3 > 1$).
4. **Root Cause Diagnosis**:
   - This is **(a) a genuinely stiff, well-posed state caught in a high-pH surface-complexation boundary crawl**.
   - Tillage incorporated alkaline subsoil into layer 0 ($\text{pH} \approx 9.8$). At $\text{pH} > 9$, the protonated site concentration ($SOH_2^+$) is vanishingly small ($4\times 10^{-3}\text{ mol/Mg}$) while deprotonated sites ($SO^-$) dominate ($15\text{ mol/Mg}$).
   - The Newton/Anderson steps attempt to transfer protons between $SOH_2^+$ and $SO^-$, but the non-negativity boundary on $SOH_2^+$ repeatedly truncates the step (`inventory_fraction = 1.0` or line-search damping), producing infinitesimal progress per iteration ($\approx 0.001\text{ mol/Mg}$ per step).
   - In legacy `solute.f:822, 2334`, fixed Picard relaxation with `MRXN=60` iterations advances by damped substitution ($TX * XOH + \dots$), publishing the relaxed state without requiring residual closure $< 10^{-3}$.

---

### 3. Minimal Legacy-Faithful Remedy

1. **Targeted Damped Picard Step for Surface Sites**:  
   When the limiter is a trace protonated/deprotonated site ($SOH_2^+ / SO^-$) and full-network Newton truncates, execute a direct equilibrium Picard relaxation step on the site distribution (analogous to `reaction_local_speciation.zig` or `reaction_surface_charge.zig` candidate), which decouples site protonation from aqueous $H^+$ conditioning.
2. **Acceptance Threshold Tuning for Trace Surface Sites**:  
   In `reaction_physical_quality.zig:106`, evaluate relative site errors against total site capacity ($\Sigma S \approx 20\text{ mol/Mg}$) rather than the trace occupied fraction ($4\times 10^{-3}\text{ mol/Mg}$). This prevents trace fractions at extreme pH from monopolizing the convergence norm when total chemical mass is conserved to machine precision.
