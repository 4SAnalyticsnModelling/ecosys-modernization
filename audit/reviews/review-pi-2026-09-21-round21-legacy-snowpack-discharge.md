# Adversarial Review Round 21: Legacy Snowpack Discharge & Disappearance Mechanics

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Identification of meltwater discharge fluxes, rate limits, retention capacity thresholds, and pack zeroing/disappearance branches in legacy Fortran (`watsub.f`, `redist.f`, `starts.f`).

---

### Detailed Findings

#### (1) Where Meltwater Leaves the Snowpack & Lines Where `VOLWS` is Decreased
Meltwater leaves the lowest snowpack layer ($L = \text{JS}$ or lowest active snow layer) to the surface litter and soil surface through the flux variables:
- **`FLWQR`**: meltwater flux from snowpack to surface residue/litter ($\text{m}^3\cdot\text{timestep}^{-1}$, calculated at `watsub.f:1632`).
- **`FLWQGS`**: meltwater flux from snowpack to soil surface micropores ($\text{m}^3\cdot\text{timestep}^{-1}$, calculated at `watsub.f:1626-1627`).
- **`FLWQGH`**: meltwater flux from snowpack to soil surface macropores ($\text{m}^3\cdot\text{timestep}^{-1}$, calculated at `watsub.f:1628-1629`).
- Combined flux: `FLWLT = FLWQGS` (`watsub.f:2229`), `FLWRT = FLWQR` (`watsub.f:2237`), `FLWQG = FLWQGS + FLWQGH` (`watsub.f:1630`).

**Decreases in State Variables**:
- In the fast sub-hourly water solver (`watsub.f:2275`):
  ```fortran
  VOLW02(L,NY,NX) = VOLW02(L,NY,NX) - FLWLT - FLWRT - FLWQGH
  ```
- In the hourly redistributor (`redist.f:3981`):
  `VOLWSL(L,NY,NX)` is updated with the accumulated net water flux `TFLWW(L,NY,NX)` (where `TFLWWX = FLW0W(L) - FLWRT - FLWLT - FLWQG` from `watsub.f:2255`):
  ```fortran
  VOLWSL(L,NY,NX) = VOLWSL(L,NY,NX) + TFLWW(L,NY,NX) + XWFLFS(L,NY,NX) + ...
  ```
- And upon pack extinction (`redist.f:4261`):
  ```fortran
  VOLWSL(1,NY,NX) = VOLWSL(1,NY,NX) - XFLWWX(NY,NX)
  ```
  transferred to litter via `VOLW(0,NY,NX) = VOLW(0,NY,NX) + XFLWWX(NY,NX)` (`redist.f:4264`).

---

#### (2) Rate Limiting & Bound Expressions
The unconstrained discharge from snow layer $L$ is generated at `watsub.f:1457-1458`:
```fortran
FLWQX = AMAX1(0.0, AMAX1(0.0, VOLW02(L,NY,NX)) - 0.05*AMAX1(0.0, VOLS02(L,NY,NX))) * XNPSX
```
When discharging to the underlying surface (soil/litter, `watsub.f:1625-1632`), it is partitioned and strictly limited:
- Soil surface fraction: `FLWQGX = FLWQX * BARE(NY,NX)` (`watsub.f:1625`).
- Micropore admittance limit:
  ```fortran
  FLWQGS = AMIN1(VOLP1(NUM(NY,NX),NY,NX) * XNPSX, FLWQGX * FGRD(NUM(NY,NX),NY,NX))
  ```
  (`watsub.f:1626-1627`) where `VOLP1` is the air capacity of the surface soil micropores and `XNPSX` is the sub-step rate.
- Macropore admittance limit:
  ```fortran
  FLWQGH = AMIN1(VOLPH1(NUM(NY,NX),NY,NX) * XNPSX, FLWQGX * FMAC(NUM(NY,NX),NY,NX))
  ```
  (`watsub.f:1628-1629`) where `VOLPH1` is the macropore air capacity.
- Litter absorption:
  ```fortran
  FLWQR = FLWQX - FLWQG
  ```
  (`watsub.f:1632`), where `FLWQG = FLWQGS + FLWQGH`. Any flux not accepted into soil micropores/macropores goes directly to litter surface storage `VOLW1(0,NY,NX)`.

Between internal snowpack layers ($L \to L+1$, `watsub.f:1480`):
```fortran
FLWQM = AMIN1(THETP2, FLWQX)
```
limited by destination air fraction `THETP2 = AMAX1(THETPI, VOLP02(L2,NY,NX)/VOLS1(L2,NY,NX))` (`watsub.f:1479`).

---

#### (3) Liquid Retention / Capacity Threshold
- **Exact Threshold**: **`0.05`** ($5\%$ by volume relative to snow volume).
- **Location**: `f77src/watsub.f:1457-1458`:
  ```fortran
  FLWQX = AMAX1(0.0, AMAX1(0.0, VOLW02(L,NY,NX)) - 0.05*AMAX1(0.0, VOLS02(L,NY,NX))) * XNPSX
  ```
- The liquid water volume `VOLW02` in a snowpack layer is held up to **$5\%$ of the snow water equivalent (`0.05 * VOLS02`)**. Any liquid water exceeding $5\%$ becomes mobile meltwater `FLWQX` available for downward drainage.

---

#### (4) Snowpack Disappearance & Final Zeroing
The explicit branch where a melting snowpack is finalized and completely moved to the litter surface occurs in two coordinated places:

1. **In `watsub.f:6655-6673`**:
   ```fortran
   IF(VHCPW(1,NY,NX).LE.VHCPWX(NY,NX) .AND. TKQG(M,NY,NX).GT.273.15)THEN
     FLWS=VOLS0(1,NY,NX)
     FLWW=VOLW0(1,NY,NX)
     FLWV=VOLV0(1,NY,NX)
     FLWI=VOLI0(1,NY,NX)
     HFLWS=(4.19*(FLWW+FLWV)+2.095*FLWS+1.9274*FLWI)*TK0(1,NY,NX)
     XFLWSX(NY,NX)=XFLWSX(NY,NX)+FLWS
     XFLWWX(NY,NX)=XFLWWX(NY,NX)+FLWW
     XFLWVX(NY,NX)=XFLWVX(NY,NX)+FLWV
     XFLWIX(NY,NX)=XFLWIX(NY,NX)+FLWI
     XHFLWX(NY,NX)=XHFLWX(NY,NX)+HFLWS
     VOLS0(1,NY,NX)=VOLS0(1,NY,NX)-FLWS
     VOLW0(1,NY,NX)=VOLW0(1,NY,NX)-FLWW
     VOLV0(1,NY,NX)=VOLV0(1,NY,NX)-FLWV
     VOLI0(1,NY,NX)=VOLI0(1,NY,NX)-FLWI
     VOLW1(0,NY,NX)=VOLW1(0,NY,NX)+FLWW
     VOLV1(0,NY,NX)=VOLV1(0,NY,NX)+FLWV
     VOLI1(0,NY,NX)=VOLI1(0,NY,NX)+FLWI+FLWS/DENSI
   ```
   - Trigger condition: Snowpack layer 1 heat capacity drops below minimum threshold `VHCPWX(NY,NX) = 8.380E-04 * AREA` (`starts.f:654`) while surface ground/canopy temperature `TKQG > 273.15 K`.
   - Action: All remaining liquid (`FLWW`), vapor (`FLWV`), ice (`FLWI`), and solid snow (`FLWS`) are zeroed out of the snowpack and added directly into the surface litter (`VOLW1(0)`, `VOLV1(0)`, `VOLI1(0)`).

2. **In `redist.f:4259-4266`**:
   At the end of the hourly step, if `XHFLWX(NY,NX) > ZEROS(NY,NX)`:
   ```fortran
   VOLSSL(1,NY,NX)=VOLSSL(1,NY,NX)-XFLWSX(NY,NX)
   VOLWSL(1,NY,NX)=VOLWSL(1,NY,NX)-XFLWWX(NY,NX)
   VOLVSL(1,NY,NX)=VOLVSL(1,NY,NX)-XFLWVX(NY,NX)
   VOLISL(1,NY,NX)=VOLISL(1,NY,NX)-XFLWIX(NY,NX)
   VOLW(0,NY,NX)=VOLW(0,NY,NX)+XFLWWX(NY,NX)
   VOLV(0,NY,NX)=VOLV(0,NY,NX)+XFLWVX(NY,NX)
   VOLI(0,NY,NX)=VOLI(0,NY,NX)+XFLWIX(NY,NX)+XFLWSX(NY,NX)/DENSI
   ```
   and the total pack state is zeroed:
   ```fortran
   VOLSS(NY,NX)=VOLSSL(1,NY,NX)
   VOLWS(NY,NX)=VOLWSL(1,NY,NX)
   VOLIS(NY,NX)=VOLISL(1,NY,NX)
   ```
   (`redist.f:4285-4287`).
