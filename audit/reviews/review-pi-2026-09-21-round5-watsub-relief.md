# Review Round 5: Legacy WATSUB Pore Over-Capacity Relief and State Persistence

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial audit of premise that legacy WATSUB relieves pore over-capacity on subsequent substeps (`issue-078`).

---

### Q1. Legacy Relief Mechanism
**YES, IT EXISTS**: `f77src/watsub.f:4895-4903` (matrix face flux) and `f77src/watsub.f:3680-3687` (surface-to-topsoil boundary).
- At the start of `WATSUB` (`watsub.f:211-213`), excess pore occupancy is calculated as:
  ```fortran
  VOLP1Z(L,NY,NX) = VOLA1(L,NY,NX) - VOLW1(L,NY,NX) - VOLI1(L,NY,NX)
  VOLP1(L,NY,NX)  = AMAX1(0.0, VOLP1Z(L,NY,NX))
  ```
  When water+ice exceeds pore capacity `VOLA1`, `VOLP1Z` is **negative** (excess volume).
- In vertical transport (`watsub.f:4898-4903`):
  ```fortran
  IF(N.EQ.3.AND.VOLP1Z(N6,N5,N4).LT.0.0)THEN
  FLQL=FLQL+AMIN1(0.0,AMAX1(-VOLW2(N6,N5,N4)*XNPHX,VOLP1Z(N6,N5,N4)))
  FLQ2=FLQ2+AMIN1(0.0,AMAX1(-VOLW2(N6,N5,N4)*XNPHX,VOLP1Z(N6,N5,N4)))
  ENDIF
  ```
  (This is the exact counterpart of `ecosys-ng`'s `mechanicalFreezingDisplacementM3` in `flux.zig:80-112`).

### Q2. Direction of Movement
**MOVES UPWARD (to upper neighbor / surface).**
- In `watsub.f:4870-4900`, `N=3` is vertical flux, where `N3` is upper source and `N6` is lower destination (`N6 > N3`).
- When destination `N6` has `VOLP1Z < 0`, a **negative** adjustment is added to `FLQL`.
- At line 4927-4928:
  ```fortran
  VOLW2(N3,N2,N1) = VOLW2(N3,N2,N1) - FLQL  ! Upper layer GAINS (- negative)
  VOLW2(N6,N5,N4) = VOLW2(N6,N5,N4) + FLQL  ! Lower layer LOSES (+ negative)
  ```
- Thus, excess water is physically pushed **UPWARD** into the shallower layer (and eventually out to surface runoff via line 3684 if the top layer overflows).

### Q3. State Persistence Across Hour Boundaries
**PERSISTS UNCHECKED across the hour boundary.**
- `REDIST` updates the persistent state `VOLW(L,NY,NX)` at `redist.f:12180`.
- At the end of the day or hour (`soil.f:214`), no check against porosity exists.
- On the next hour (`J+1, NFZ=1`), `soil.f:151` calls `WATSUB`, which reads `VOLW1 = VOLW` (`watsub.f:206`), detects `VOLP1Z < 0` (`watsub.f:212`), and pushes the excess upward via `FLQL`.

### Q4. Commented-out Air Volume Updates in REDIST
**CONFIRMED COMMENTED OUT.**
- `f77src/redist.f:12186-12189`:
  ```fortran
  C     VOLP(L,NY,NX)=TI*VOLP(L,NY,NX)+CORP*(FI*TVOLP-TI*VOLP(L,NY,NX))
  C     VOLA(L,NY,NX)=TI*VOLA(L,NY,NX)+CORP*(FI*TVOLA-TI*VOLA(L,NY,NX))
  ```
- **Implication**: Legacy `REDIST` does not update pore/air space. It operates strictly on extensive mass (`VOLW`, `VOLI`) and is **completely blind** to over-capacity. It relies 100% on `WATSUB` at the next substep to compute `VOLP1Z < 0` and displace the excess.

### CONFIDENCE
**HIGH**. Verified directly in `watsub.f:212, 3684, 4898-4903` and `redist.f:12180-12189`. Option (c) is completely faithful to legacy physics.
