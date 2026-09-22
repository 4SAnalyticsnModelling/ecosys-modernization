# Adversarial Review Round 19: Dissolved Gas Initialization & Output Denominator Analysis

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Verification of the initialization and derivation chain for dissolved gas concentrations `CCO2S` and `COXYS` in legacy Fortran (`starte.f`, `starts.f`, `hour1.f`) versus `ecosys-ng`.

---

### Verdict: NOT FALSIFIED (The Denominator is `VOLW(L,NY,NX)`)

The exact denominator used by the legacy model to compute dissolved concentrations `CCO2S` and `COXYS` is **`VOLW(L,NY,NX)`** (the layer's soil liquid water volume in $\text{m}^3$).

Furthermore, an important structural finding in `starte.f:1419-1425` (documented as `STARTE-010` in `docs/discrepancy_register.md`) confirms that **legacy initializes aqueous mass using `FC` (dimensionless field capacity fraction, $\text{m}^3\cdot\text{m}^{-3}$) instead of liquid water volume $\text{m}^3$**, whereas `ecosys-ng` initialized aqueous mass using `matrix_liquid_water_m3`. This creates a first-hour mass divergence of exactly $\frac{\text{FC}}{\text{VOLW}}$, directly explaining the initial-state gap.

---

### Detailed Findings

#### (1) Where `CCO2S` and `COXYS` are First Assigned (Expressions & Locations)
- **Derived Concentrations**: In the legacy Fortran codebase, `CCO2S` and `COXYS` are **NOT** persistent state variables; they are derived concentrations computed at the start of each substep in `hour1.f`.
- **First Assignment in Execution**:
  - `f77src/hour1.f:3778`:
    ```fortran
    IF(VOLW(L,NY,NX).GT.ZEROS(NY,NX))THEN
    CCO2S(L,NY,NX)=AMAX1(0.0,CO2S(L,NY,NX)/VOLW(L,NY,NX))
    ```
  - `f77src/hour1.f:3780`:
    ```fortran
    COXYS(L,NY,NX)=AMAX1(0.0,OXYS(L,NY,NX)/VOLW(L,NY,NX))
    ```
- **Surface Litter ($L=0$)**:
  - `f77src/hour1.f:4606`:
    ```fortran
    CCO2S(0,NY,NX)=AMAX1(0.0,CO2S(0,NY,NX)/VOLW(0,NY,NX))
    ```

#### (2) What They Are a Function Of (The Initialization of `CO2S` and `OXYS` in `starte.f`)
Before `hour1.f` evaluates `CO2S/VOLW`, the dissolved masses `CO2S` and `OXYS` are initialized in `f77src/starte.f:1419-1425`:

- **Dissolved Oxygen Mass (`OXYS`)**:
  `f77src/starte.f:1418-1423`:
  ```fortran
  IF(CDPTH(L-1,NY,NX).LT.DTBLZ(NY,NX))THEN
  OXYS(L,NY,NX)=COXYE(NY,NX)*SOXYX/(EXP(AOXYX*CSTR1))
 2*EXP(0.516-0.0172*ATCA(NY,NX))*FC(L,NY,NX)
  ELSE
  OXYS(L,NY,NX)=0.0
  ENDIF
  ```
- **Dissolved Carbon Dioxide Mass (`CO2S`)**:
  `f77src/starte.f:1424-1425`:
  ```fortran
  CO2S(L,NY,NX)=CCO2EI(NY,NX)*SCO2X/(EXP(ACO2X*CSTR1))
 2*EXP(0.843-0.0281*ATCA(NY,NX))*FC(L,NY,NX)
  ```

**Inputs and Their Provenance**:
1. **Atmospheric Gas Concentrations**:
   - `COXYE(NY,NX)`: Atmospheric $\text{O}_2$ concentration ($\text{g}\cdot\text{m}^{-3}$), initialized in `starts.f:498` / `readi.f:233`.
   - `CCO2EI(NY,NX)`: Initial atmospheric $\text{CO}_2$ concentration ($\text{g C}\cdot\text{m}^{-3}$), read from options file in `readi.f:230` and stored in `starts.f:495`.
2. **Solubility Constants**:
   - `SOXYX = 2.925E-02` (reference $\text{O}_2$ Bunsen solubility at $25^\circ\text{C}$, $\text{m}^3\text{ gas}\cdot\text{m}^{-3}\text{ water}$, `starte.f:32`).
   - `SCO2X = 7.391E-01` (reference $\text{CO}_2$ Bunsen solubility at $25^\circ\text{C}$, `starte.f:32`).
3. **Temperature Dependency (Henry's Law Van 't Hoff Form)**:
   - `ATCA(NY,NX)`: Mean annual air temperature ($^\circ\text{C}$), from site file.
   - For $\text{O}_2$: $\exp(0.516 - 0.0172 \times \text{ATCA})$.
   - For $\text{CO}_2$: $\exp(0.843 - 0.0281 \times \text{ATCA})$.
4. **Ionic Strength Activity Divisor (Salinity Correction)**:
   - $\exp(\text{AOXYX} \times \text{CSTR1})$ where $\text{AOXYX} = 0.31$, $\text{ACO2X} = 0.14$ (`starte.f:34-35`).
   - `CSTR1` is the ionic strength of the soil solution, computed at `starte.f:426` ($0$ in non-saline soil).
5. **The Multiplier / Volume Proxy**:
   - Notice the trailing term: **`* FC(L,NY,NX)`**!
   - `FC(L,NY,NX)` is the **field capacity moisture fraction** ($\text{m}^3\cdot\text{m}^{-3}$), read from the soil file (`readi.f:332`).

---

#### (3) The Denominator: `VOLW(L,NY,NX)` & The Root Cause of Hour 1 Divergence

1. **Exact Denominator Variable**:
   **`VOLW(L,NY,NX)`** in `f77src/hour1.f:3778` and `:3780`.
   - `VOLW` is the total soil liquid water volume in layer $L$, cell $(NY, NX)$, in units of **$\text{m}^3$**.
   - It is initialized in `starts.f:1178`: `VOLW(L,NY,NX) = THETW(L,NY,NX) * VOLX(L,NY,NX)`.

2. **The Resulting Hour 1 Concentration Formula in Legacy**:
   At the start of Hour 1, combining `starte.f:1424` with `hour1.f:3778`:
   $$\text{CCO2S}_{\text{legacy}} = \frac{\text{CO2S}}{\text{VOLW}} = \frac{\text{CCO2EI} \times \text{Solubility}(\text{ATCA}) \times \text{FC}(L)}{\text{THETW}(L) \times \text{VOLX}(L)}$$
   Notice the dimensional discrepancy:
   - In legacy Fortran, `CO2S` is multiplied by `FC(L)` (a dimensionless fraction $\approx 0.28\text{ m}^3\cdot\text{m}^{-3}$), rather than an extensive water volume ($\text{m}^3$).
   - When divided by `VOLW` ($\approx \text{THETW} \times \text{VOLX}$), the legacy concentration is scaled by $\frac{\text{FC}}{\text{VOLW}} \approx \frac{\text{FC}}{\text{THETW} \times \text{VOLX}}$.
   - For layer 1 with $\text{VOLX} \approx 0.01\text{ m}^3$ (or layer thickness $0.01\text{ m}$ per unit area), dividing by $\text{VOLX} \approx 0.01$ inflates the legacy concentration by a factor of roughly $\sim 100 \times \frac{\text{FC}}{\text{THETW}}$!

3. **How `ecosys-ng` Handles This (`STARTE-010`)**:
   - In `ecosys-ng/src/soil/gas/transport.zig:114`:
     ```zig
     state.dissolved_mass_g[index] = concentration * solubility[species] / ionic_divisor * water_volume_m3;
     ```
   - In `ecosys-ng/src/ecosys_ng.zig:12735`:
     `ecosys_ng` passes `state.matrix_liquid_water_m3[layer_cell]` (an extensive volume in $\text{m}^3$) instead of `FC`.
   - When `biogeochemistry_output.zig:15` evaluates `mass / water`, `water_volume_m3` cancels out, yielding the theoretical equilibrium Henry's law concentration.
   - Legacy Fortran did **NOT** cancel out the volume because it multiplied by dimensionless `FC` instead of `VOLW`.

---

### Conclusion

The denominator is definitively **`VOLW(L,NY,NX)`** (soil liquid water volume in $\text{m}^3$).  
Because legacy `starte.f:1420, 1425` multiplies the initial dissolved mass by dimensionless `FC(L)` instead of `VOLW(L)`, legacy initial aqueous gas mass is missing a layer volume factor $\text{VOLX}$. When `hour1.f:3778` divides by `VOLW`, the legacy concentration is shifted by $\frac{\text{FC}}{\text{VOLW}}$, producing the initial-hour discrepancy between legacy output and `ecosys-ng`.
