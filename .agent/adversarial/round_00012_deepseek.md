# Adversarial Diagnosis: Round 00012 — Layer-0 High pH, H3PO4 Stagnation & Urea Chemistry

**Author**: DEEPSEEK (Architecture / Challenger)  
**Target**: Layer 0 at hour 3669: $[H^+] = 3.50\times 10^{-7}\text{ mol/m}^3$ ($\text{pH} \approx 9.46$), $H_2PO_4^- = 0$, $H_3PO_4 = 5.85\times 10^{-5}$, non-band hydroxyl site $= 0$ (residual 0.78), dicalcium phosphate limiting.  
**Legacy Sources**: `f77src/solute.f:216-258,368-400,642,731,854,1467-1475,1743-1750,2170-2215`, `f77src/nitro.f:4110-4124`  
**Zig References**: `stages/soil_chemistry_convergence.zig:284-358`, `soil/nutrients/fertilizer_dissolution.zig:250-366`, `soil/chemistry/biochemical_acidity.zig:26-67`, `soil/solute/phosphate_reaction_rates.zig:334`, `soil/solute/ion_pairing.zig:35-53`

---

### 1. Physical Plausibility of pH ~9.5 with Residual H3PO4 and Closure Comparison

1. **Physical Implausibility**:  
   At $\text{pH} \approx 9.5$, aqueous phosphoric acid ($H_3PO_4$, $pK_{a1} \approx 2.15$) cannot exist at $5.85\times 10^{-5}\text{ mol P/m}^3$ alongside zero $H_2PO_4^-$. At $\text{pH} = 9.5$, the equilibrium ratio is:
   $$\frac{[H_3PO_4]}{[H_2PO_4^-]} = \frac{[H^+]\gamma_1}{K_{a1}} \approx \frac{3.5\times 10^{-7} \times 0.8}{7.1\times 10^{-3}} \approx 3.9\times 10^{-5}$$
   If $H_2PO_4^- \to 0$, $H_3PO_4$ must be driven to $< 10^{-12}\text{ mol P/m}^3$. Having $H_3PO_4 = 5.85\times 10^{-5}$ while $H_2PO_4^- = 0$ is a **severe physical and numerical inversion**.

2. **Upstream Mechanism & Defect Comparison**:
   - In `f77src/solute.f:1745-1750`:
     ```fortran
     XMINN=FIONX*CH3P1
     XMINP=FIONX*AMIN1(CHY1,CH2P1)
     AH2P1Q=DPH3P*AH3P1/AHY1
     RH3P=AMAX1(-TSLX,-XMINN,(AMIN1(TSLX,XMINP,(AH2P1-AH2P1Q)/A1)))
     ```
     When $H_2PO_4^- \to 0$ and $AH2P1Q \gg AH2P1$, `RH3P` is negative (dissociating $H_3PO_4 \to H_2PO_4^- + H^+$), clamped by $-XMINN = -FIONX \cdot CH3P1$.
   - In Zig (`ion_pairing.zig:45-52`, `phosphate_reaction_rates.zig:334`):  
     $H_3PO_4$ dissociation calculates `driving_force = (activities.free_first - equilibrium_first_activity) / gamma`. When $[H_2PO_4^-] = 0$, `equilibrium_first = DPH3P * [H3PO4] / [H+]`. With $[H^+] \approx 3.5\times 10^{-7}$, the equilibrium demand is gigantic ($\approx 10^3$), driving huge dissociation.
   - **The Bug / Trap**: In `ion_pairing.zig:37-42`:
     ```zig
     if (activities.free_second_mol_per_m3 == 0) return bounded(
         -state.paired_mol_per_m3, ...
     );
     ```
     `free_second` is $[H^+]$. If $[H^+]$ is non-zero but microscopic ($10^{-7}$), it computes `equilibrium_first_activity` which explodes ($\sim -2\times 10^3$), hitting the lower bound `-dissociation_limit = -substrate_limit_fraction * state.paired_mol_per_m3`. However, in the Newton/semismooth solver (`reaction_solve.zig`), the Jacobian derivative $\partial r / \partial [H^+] \propto -K_{a1}[H_3PO_4]/[H^+]^2$ blows up by $10^{14}$! This causes Newton step stagnation and locks $H_3PO_4$ from ever reaching zero while $H_2PO_4^-$ is exhausted by precipitation/adsorption.

---

### 2. Driver of Layer-0 Basification (pH 9.5) over Hours 3600–3669

1. **Urea Hydrolysis Mechanism**:  
   Broadcast urea on May 16 (`f25fr98`, col 4 = 13.8) enters layer 0.  
   In `stages/soil_chemistry_convergence.zig:284-347` (`state_updateToRecipients`), hydrolyzed urea is added directly to `aqueous.ammonia_non_band` ($NH_3$) without releasing the stoichiometric carbonate counter-ion ($CO_2 / HCO_3^-$):
   $$\text{CO(NH}_2)_2 + 2\text{H}_2\text{O} \to 2\text{NH}_4^+ + \text{CO}_3^{2-} \quad (\text{or } 2\text{NH}_3 + \text{CO}_2 + \text{H}_2\text{O})$$
   In Zig, `dissolution.zig:346` injects:
   `next_aqueous.ammonia_non_band += urea_to_non_band_mol_n / water`
   producing raw unbuffered $NH_3(aq)$. When $NH_3$ enters the reaction solver, the equilibrium:
   $$NH_3 + H_2O \rightleftharpoons NH_4^+ + OH^- \quad (NH_3 + H^+ \rightleftharpoons NH_4^+)$$
   consumes vast amounts of $H^+$, driving $[H^+]$ down to $10^{-7}\text{ mol/m}^3$ ($\text{pH} \to 9.5$).
2. **Missing Counter-Acid**:  
   Legacy `solute.f:376,3962` and `hour1.f` track $RSNUAA$ as dissolved $NH_3$, but in legacy, soil $CO_2$ dissolution ($RCO2Q$ at `solute.f:1518`) and soil respiration vigorously buffer alkalinity. In thin, dry layer 0 with evaporation concentrating solute and air-drying, lack of gas-phase $CO_2$ replenishment or uncoupled $CO_2$ generation leaves the massive $NH_3$ charge unbuffered, resulting in runaway alkaline drift.

---

### 3. Discriminating Check from Checkpoint 3600

CLAUDE should run a replay from hour 3600 with the following targeted diagnostic probe in `stages/soil_chemistry_convergence.zig` right after `state_updateToRecipients` and right before `solveHourlyReactionCells`:

```zig
if (cell == 0 and layer_within_cell == 0 and hour >= 3600) {
    std.log.warn(
        "PROBE_PH_3600: hour={d} water_m3={e} urea_diss={e} NH3={e} NH4={e} H={e} CO2={e} HCO3={e} H3PO4={e} H2PO4={e}",
        .{
            hour,
            water_volume_m3,
            dissolved.broadcast_urea_non_band_mol_n,
            context.soil_chemistry.aqueous[layer].ammonia_non_band,
            context.soil_chemistry.aqueous[layer].ammonium_non_band,
            context.soil_chemistry.aqueous[layer].hydrogen,
            context.soil_chemistry.aqueous[layer].carbon_dioxide,
            context.soil_chemistry.aqueous[layer].bicarbonate,
            context.soil_chemistry.non_band_phosphate[layer].dissolved_h3po4_mol_p_per_m3,
            context.soil_chemistry.non_band_phosphate[layer].dissolved_h2po4_mol_p_per_m3,
        },
    );
}
```

**What this will discriminate**:
1. If `NH3` surges by several orders of magnitude while `CO2`/`HCO3` remain flat, the driver of the pH 9.5 spike is confirmed as unbuffered urea-derived $NH_3$ accumulation.
2. If `H3PO4` enters the hour already non-zero ($5.8\times 10^{-5}$) from prior hours despite alkaline pH, it proves $H_3PO_4$ transport/advection/condensation injected extensive phosphoric acid without pre-solve speciation.
