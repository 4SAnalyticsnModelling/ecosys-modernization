# Round 00037 Comparability Root Cause: Soil Gas Initialization & Hour 1 State

## 1. Legacy Output Header Mislabeling
In legacy `outsh.f:57-103` and `fouts.f:101-150`:
- Choice 4 writes `O2_FLUX`. Choices 5–8 write `CO2_1..CO2_4`.
- Choices 9–10 write `CO2_5..CO2_6` (`CCO2S(5)` and `CCO2S(6)`).
- Choices 36–45 write `O2_2..O2_11` (`COXYS(2..11)`).
- `f77example/Cool Temperate Maize-Soybean ON/f25ch1` enables choices 3–10, 36–45, 53–55, 58–60.
- The CSV header in legacy `010101998f25ch1` labels columns 15–23 as `dissolved_oxygen_concentration_layer_5..layer_12` and `litter_O2`. This is a **pure header indexing artifact** from a misaligned translation script: the data columns are actually **$O_2$ in soil layers 2 through 11** (`COXYS(2)` through `COXYS(11)`).

## 2. Legacy vs ng Soil Gas Initialization
- **Legacy (`starte.f:1410-1433`)**:
  - Gaseous: $C_g = C_{atm} \cdot \text{VOLP}(L)$ (`lines 1411-1417`).
  - Aqueous: Solutes are scaled by field capacity $\text{FC}(L)$ (`lines 1419-1433`):
    $\text{CO2S}(L) = \text{CCO2EI} \cdot \frac{\text{SCO2X}}{\exp(\text{ACO2X} \cdot \text{CSTR1})} \cdot \exp(0.843 - 0.0281 \cdot \text{ATCA}) \cdot \mathbf{FC(L)}$.
    Importantly, in legacy, $\text{FC}(L)$ is dimensionless moisture ($0.28\text{ m}^3\text{ m}^{-3}$), **not liquid volume** $\text{VOLW}(L)$ ($0.00495\text{ m}^3$).
- **ng (`ecosys_ng.zig:12855-12867` $\to$ `soil/gas/transport.zig:83-120`)**:
  - ng intentionally replaces $\text{FC}$ with active $\text{matrix\_liquid\_water\_m3}$ ($0.00495\text{ m}^3$):
    $\text{dissolved\_mass\_g} = C_{atm} \cdot \frac{\text{solubility}}{\text{ionic\_divisor}} \cdot \mathbf{water\_volume\_m3}$.
  - Initial concentration $C_0$ in legacy is $\text{CO2S}/\text{VOLW} = C_{eq} \cdot \frac{\text{FC}}{\text{VOLW}} \approx 16.0\text{ g C m}^{-3}$, whereas in ng it is $C_{eq} \cdot \frac{\text{VOLW}}{\text{VOLW}} \approx 0.282\text{ g C m}^{-3}$ (documented in `soil/gas/inventory_initialization.zig:51-57`).

## 3. Hour 1 Sequencing & Temporal Alignment
- **Legacy Order (`soil.f:140-233`)**: In day 1, legacy runs `WTHR` $\to$ `HOUR1` $\to$ `WATSUB` $\to$ `NITRO` $\to$ `SOLUTE` $\to$ `TRNSFR` $\to$ `REDIST` $\to$ `OUTSH`. The first row labeled `hour 1` contains the state **after 1 full hour of physical transport, chemical equilibrium, and biological fluxes**.
- **ng Order (`ecosys_ng.zig:740, 831`)**: ng writes output at the end of each simulation step with zero-based hour index: `hour 0` is the state after hour 1 of simulation! ng `hour 0` corresponds directly to legacy `hour 1`.

## 4. Single Most Likely Cause of Hour-1 Layer-1 CO2 (0.60 vs 1.65 g C m-3)
The discrepancy is caused by **legacy seeding initial aqueous gas mass with volumetric field capacity $\text{FC}(L) \approx 0.28$ instead of layer water volume $\text{VOLW}(L) \approx 0.00495\text{ m}^3$** (`starte.f:1425`).
- Legacy enters hour 1 with an artificial $\sim 56\times$ over-concentration ($\sim 16.0\text{ g C m}^{-3}$). Degassing in TRNSFR over the first hour drops it to $1.65\text{ g C m}^{-3}$.
- ng correctly initialized dissolved mass using actual water volume ($C_0 \approx 0.28\text{ g C m}^{-3}$), which microbial respiration in hour 1 then raised to $0.60\text{ g C m}^{-3}$ (`hour 0` in ng).
