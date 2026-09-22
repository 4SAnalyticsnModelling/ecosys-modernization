# Adversarial Review Round 18: Output Units and Sign Semantics for Hourly Carbon Stream (`f25ch1`)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Determination of exact mathematical expressions, COMMON variables, multipliers, time bases, physical units, and sign conventions for columns in the hourly soil carbon output file (`f25ch1`), per legacy routines `outsh.f` and `fouts.f`.

---

### Summary Table: Requested Six Columns

| Column Name | Slot | Legacy Variable / Expression in `outsh.f` | Multiplier / Derivation | Physical Units | Time Basis | Sign Convention |
|---|---|---|---|---|---|---|
| `SOIL_CO2_FLUX` | 1 | `HCO2G(NY,NX) / AREA(3,NU(NY,NX),NY,NX) * 23.14815` | `23.14815` ($= \frac{10^6}{12.0 \times 3600}$) | $\mu\text{mol C m}^{-2}\text{ s}^{-1}$ | Rate over current hour | Positive = net flux from atmosphere to soil (or ground surface gain); Negative = emission from soil to atmosphere |
| `ECO_CO2_FLUX` | 2 | `TCNET(NY,NX) / AREA(3,NU(NY,NX),NY,NX) * 23.14815` | `23.14815` ($= \frac{10^6}{12.0 \times 3600}$) | $\mu\text{mol C m}^{-2}\text{ s}^{-1}$ | Rate over current hour | Positive = net ecosystem C gain/uptake; Negative = net ecosystem C emission/loss |
| `CH4_FLUX` | 3 | `HCH4G(NY,NX) / AREA(3,NU(NY,NX),NY,NX) * 23.14815` | `23.14815` ($= \frac{10^6}{12.0 \times 3600}$) | $\mu\text{mol C m}^{-2}\text{ s}^{-1}$ | Rate over current hour | Positive = ground surface CH4 uptake; Negative = net CH4 emission to atmosphere |
| `O2_FLUX` | 4 | `HOXYG(NY,NX) / AREA(3,NU(NY,NX),NY,NX) * 8.68056` | `8.68056` ($= \frac{10^6}{32.0 \times 3600}$) | $\mu\text{mol O}_2\text{ m}^{-2}\text{ s}^{-1}$ | Rate over current hour | Positive = downward O2 flux from atmosphere into soil; Negative = upward O2 flux |
| `CO2_1` | 5 | `CCO2S(1,NY,NX)` | None (`1.0`) | $\text{g C m}^{-3}\text{ water}$ | Instantaneous hourly state | Positive concentration |
| `O2_1` | 35 | `COXYS(1,NY,NX)` | None (`1.0`) | $\text{g O}_2\text{ m}^{-3}\text{ water}$ | Instantaneous hourly state | Positive concentration |

---

### Detailed Derivations & Code Provenance

#### 1. Column 1: `SOIL_CO2_FLUX` (Slot 1)
- **Heading Assignment**: `f77src/fouts.f:102`: `IF(L.EQ.1)HEAD(M)='SOIL_CO2_FLUX'`.
- **Value Assignment**: `f77src/outsh.f:54`:
  ```fortran
  IF(K.EQ.1)HEAD(M)=HCO2G(NY,NX)/AREA(3,NU(NY,NX),NY,NX)*23.14815
  ```
- **COMMON Variable**: `HCO2G` in `COMMON /FLUXS/` (`f77src/blkc.h:32`).
- **Definition & Units in Source**:
  - `f77src/redist.f:10639`: `C HCO2G=ground surface CO2 exchange (g C h-1)`.
  - `AREA(3,NU(NY,NX),NY,NX)` is surface grid-cell horizontal area in $\text{m}^2$.
- **Multiplier & Unit Conversion**:
  $$23.14815 \approx \frac{10^6 \mu\text{mol}\cdot\text{mol}^{-1}}{12.011 \text{ g C}\cdot\text{mol}^{-1} \times 3600\text{ s}\cdot\text{h}^{-1}} = \frac{10^6}{43200} = 23.148148...$$
  Converts $\text{g C}\cdot\text{m}^{-2}\cdot\text{h}^{-1} \to \mu\text{mol C}\cdot\text{m}^{-2}\cdot\text{s}^{-1}$.
- **Accumulation & Time Basis**:
  - Cleared hourly in `hour1.f:191`: `HCO2G(NY,NX)=0.0`.
  - Accumulated over subhourly substeps `NFZ=1..NFH` in `redist.f:4478`: `HCO2G(NY,NX)=HCO2G(NY,NX)+CI` and `redist.f:6573`: `HCO2G(NY,NX)=HCO2G(NY,NX)+CIB`.
  - Represents the total flux across that 1-hour interval.
- **Sign Convention**:
  - Look at `redist.f:4465-4468`:
    `CI = XCODFS + XCOFLG(3,NU) + TCO2Z + XCOFLG(3,0) + XCODFR + ...`
    In `trnsfr.f:3282-3283`, `DFVCOG = AMIN1(..., DCO2GQ*(CCO2E - CCO2G2))`.
    When atmospheric concentration exceeds litter/soil concentration ($C_{atm} > C_{soil}$), flux into soil is positive ($CI > 0$).
    When respiration causes upward soil-to-atmosphere degassing ($C_{soil} > C_{atm}$), $DFVCOG < 0$, making $CI < 0$ and $HCO2G < 0$.
  - Therefore, in legacy ECOSYS output, **negative values represent net emission to the atmosphere**, and **positive values represent net absorption by the soil**.
  - *Oracle Check*: Oracle Ottawa hour 1 emits `-0.8703152E+001` $\mu\text{mol}\cdot\text{m}^{-2}\cdot\text{s}^{-1}$ (respiration emission to cold air).

#### 2. Column 2: `ECO_CO2_FLUX` (Slot 2)
- **Heading Assignment**: `f77src/fouts.f:103`: `IF(L.EQ.2)HEAD(M)='ECO_CO2_FLUX'`.
- **Value Assignment**: `f77src/outsh.f:55`:
  ```fortran
  IF(K.EQ.2)HEAD(M)=TCNET(NY,NX)/AREA(3,NU(NY,NX),NY,NX)*23.14815
  ```
- **COMMON Variable**: `TCNET` in `COMMON /BALANS/` (`f77src/blkc.h:20`).
- **Definition & Units in Source**:
  - `f77src/redist.f:10637`: `C TCNET=ecosystem net CO2 exchange (g C h-1)`.
  - `redist.f:10654`: `TCNET(NY,NX)=TCCAN(NY,NX)+HCO2G(NY,NX)` at the final substep `NFZ=NFH`.
  - `TCCAN` is net canopy carbon fixation rate ($\text{g C}\cdot\text{h}^{-1}$, from `extract.f:940`).
- **Multiplier & Unit Conversion**: Identical factor $23.14815$ ($\mu\text{mol C}\cdot\text{m}^{-2}\cdot\text{s}^{-1}$).
- **Sign Convention**: Sum of canopy fixation (`TCCAN`) and ground exchange (`HCO2G`). Positive = net ecosystem C sink/uptake; Negative = net ecosystem C source/loss. In hour 1 (winter, no canopy), `TCCAN = 0`, so `TCNET == HCO2G`, producing `-0.8703152E+001`.

#### 3. Column 3: `CH4_FLUX` (Slot 3)
- **Heading Assignment**: `f77src/fouts.f:104`: `IF(L.EQ.3)HEAD(M)='CH4_FLUX'`.
- **Value Assignment**: `f77src/outsh.f:56`:
  ```fortran
  IF(K.EQ.3)HEAD(M)=HCH4G(NY,NX)/AREA(3,NU(NY,NX),NY,NX)*23.14815
  ```
- **COMMON Variable**: `HCH4G` in `COMMON /FLUXS/` (`f77src/blkc.h:32`).
- **Definition & Units in Source**:
  - `HCH4G`: ground surface $\text{CH}_4$ exchange ($\text{g C}\cdot\text{h}^{-1}$).
  - Multiplier $23.14815$ converts $\text{g C}\cdot\text{m}^{-2}\cdot\text{h}^{-1} \to \mu\text{mol C}\cdot\text{m}^{-2}\cdot\text{s}^{-1}$.
- **Sign Convention**: Same as `HCO2G`. Negative = net $\text{CH}_4$ emission from ground to atmosphere; Positive = $\text{CH}_4$ deposition/uptake into ground.
- *Oracle Check*: Oracle Ottawa hour 1 emits `0.3513212E-003` $\mu\text{mol}\cdot\text{m}^{-2}\cdot\text{s}^{-1}$ (small atmospheric methane oxidation/uptake into topsoil).

#### 4. Column 4: `O2_FLUX` (Slot 4)
- **Heading Assignment**: `f77src/fouts.f:105`: `IF(L.EQ.4)HEAD(M)='O2_FLUX'`.
- **Value Assignment**: `f77src/outsh.f:57`:
  ```fortran
  IF(K.EQ.4)HEAD(M)=HOXYG(NY,NX)/AREA(3,NU(NY,NX),NY,NX)*8.68056
  ```
- **COMMON Variable**: `HOXYG` in `COMMON /FLUXS/` (`f77src/blkc.h:32`).
- **Definition & Units in Source**:
  - `HOXYG`: ground surface $\text{O}_2$ exchange ($\text{g O}_2\cdot\text{h}^{-1}$).
  - Cleared hourly in `hour1.f:193`: `HOXYG(NY,NX)=0.0`.
  - Accumulated subhourly in `redist.f:4502`: `HOXYG(NY,NX)=HOXYG(NY,NX)+OI` and `redist.f:6584`: `HOXYG(NY,NX)=HOXYG(NY,NX)+OIB`.
- **Multiplier & Unit Conversion**:
  $$8.68056 \approx \frac{10^6 \mu\text{mol}\cdot\text{mol}^{-1}}{31.9988 \text{ g O}_2\cdot\text{mol}^{-1} \times 3600\text{ s}\cdot\text{h}^{-1}} = \frac{10^6}{115200} = 8.680555...$$
  Converts $\text{g O}_2\cdot\text{m}^{-2}\cdot\text{h}^{-1} \to \mu\text{mol O}_2\cdot\text{m}^{-2}\cdot\text{s}^{-1}$.
- **Sign Convention**: In `trnsfr.f:3286-3287`, $DFVOXG$ is positive when $C_{atm} > C_{soil}$ (downward diffusion into soil). If atmospheric oxygen enters the soil to satisfy respiration demand, $HOXYG$ is positive. If oxygen is pushed upward/outgassed, $HOXYG$ is negative.
- *Oracle Check*: Oracle Ottawa hour 1 emits `-0.1296639E+003` $\mu\text{mol O}_2\cdot\text{m}^{-2}\cdot\text{s}^{-1}$.

#### 5. Column 5: `CO2_1` (Slot 5)
- **Heading Assignment**: `f77src/fouts.f:106`: `IF(L.EQ.5)HEAD(M)='CO2_1'`.
- **Value Assignment**: `f77src/outsh.f:58`:
  ```fortran
  IF(K.EQ.5)HEAD(M)=CCO2S(1,NY,NX)
  ```
- **COMMON Variable**: `CCO2S` in `COMMON /GASES/` (`f77src/blkc.h:36`).
- **Definition & Units in Source**:
  - `f77src/hour1.f:3758`: `C C*S=soil gas aqueous concentration (g m-3)`.
  - `hour1.f:3778`:
    ```fortran
    IF(VOLW(L,NY,NX).GT.ZEROS(NY,NX))THEN
    CCO2S(L,NY,NX)=AMAX1(0.0,CO2S(L,NY,NX)/VOLW(L,NY,NX))
    ```
  - `CO2S` is aqueous $\text{CO}_2$ mass in grams of carbon ($\text{g C}$); `VOLW` is soil liquid water volume in $\text{m}^3$.
  - Therefore, `CCO2S` is in **$\text{g C m}^{-3}\text{ water}$**.
- **Multiplier & Time Basis**: No multiplier ($1.0$). Instantaneous dissolved concentration in layer 1 liquid at the hour mark. Always non-negative.
- *Oracle Check*: Oracle Ottawa hour 1 emits `0.2561241E+001` $\text{g C}\cdot\text{m}^{-3}\text{ water}$.

#### 6. Column 35: `O2_1` (Slot 35)
- **Heading Assignment**: `f77src/fouts.f:136`: `IF(L.EQ.35)HEAD(M)='O2_1'`.
- **Value Assignment**: `f77src/outsh.f:88`:
  ```fortran
  IF(K.EQ.35)HEAD(M)=COXYS(1,NY,NX)
  ```
- **COMMON Variable**: `COXYS` in `COMMON /GASES/` (`f77src/blkc.h:36`).
- **Definition & Units in Source**:
  - `f77src/hour1.f:3758`: `C C*S=soil gas aqueous concentration (g m-3)`.
  - `hour1.f:3780`:
    ```fortran
    IF(VOLW(L,NY,NX).GT.ZEROS(NY,NX))THEN
    COXYS(L,NY,NX)=AMAX1(0.0,OXYS(L,NY,NX)/VOLW(L,NY,NX))
    ```
  - `OXYS` is dissolved $\text{O}_2$ mass in grams ($\text{g O}_2$); `VOLW` is soil liquid water volume in $\text{m}^3$.
  - Therefore, `COXYS` is in **$\text{g O}_2\text{ m}^{-3}\text{ water}$**.
- **Multiplier & Time Basis**: No multiplier ($1.0$). Instantaneous dissolved concentration in layer 1 liquid at the hour mark. Always non-negative.
- *Oracle Check*: Oracle Ottawa hour 1 emits `0.1665974E+002` $\text{g O}_2\cdot\text{m}^{-3}\text{ water}$.
