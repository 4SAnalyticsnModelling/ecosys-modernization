# Adversarial Review Round 13: Legacy Soil Layer Overfill Domain & Pore Capacity Verification

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Falsification of Claim that legacy Fortran admits soil states where `VOLW + VOLI > VOLA` (overfill), tolerates negative air volumes (`VOLP1Z < 0`), applies gradual drainage without stopping/aborting, and does not hard-clamp `VOLW` to capacity at substep entry.

---

### Verdict: NOT FALSIFIED

The editor's claim is **CONFIRMED** in every specific:
1. **Admittance of Overfill**: Legacy explicit state allows `VOLW + VOLI > VOLA` (micropore overfill) and `VOLWH + VOLIH > VOLAH` (macropore overfill).
2. **Dual Representation**: Legacy stores a signed volume (`VOLP1Z` / `VOLPH1Z`) that directly represents excess water+ice when negative, alongside a non-negative derived volume (`VOLP1` / `VOLPH1`) computed via `AMAX1(0.0, ...)`.
3. **No Fatal Abort or Stop**: There is no check in `watsub.f`, `hour1.f`, `redist.f`, or `soil.f` that terminates, halts with `STOP`, or errors out when pore capacity is exceeded.
4. **No Hard Clamp on `VOLW`**: `VOLW` is never clamped to `VOLA` at substep entry or during state updates. Derived fractional concentrations like `THETW` are clamped to `POROS` for constitutive relationships (`hour1.f:3615-3616`), but extensive state variable `VOLW` retains its unconstrained mass.
5. **Gradual Donor-Bounded Relief**: `watsub.f:4898-4902` and `watsub.f:3683-3685` drain excess volume upward with a donor substep fraction `XNPHX` / `XNPZX`, preserving excess across substeps.
6. **Tillage Injection**: `redist.f:12180-12181` updates `VOLW` with no capacity checks, and the `VOLP`/`VOLA` updates are commented out (`redist.f:12186-12189`).

Therefore, ecosys-ng's `RuntimeSoilPoreCapacityExceeded` guard in `soil/profile/runtime_material_refresh.zig:245-264` enforces an entry domain strictly narrower than legacy Fortran.

---

### Falsification Checks & Findings

#### (1) Does any legacy routine stop, abort, write a fatal diagnostic, or hard-clamp `VOLW` to capacity?
- **Finding: NO.**
- Whole-codebase scan for `STOP` reveals only two active occurrences in the entire legacy codebase:
  - `f77src/main.f:124`: `1000 STOP` at normal completion of simulation.
  - `f77src/grosub.f:5231`: comment only.
- In `f77src/hour1.f:3604-3606`:
  ```fortran
  VOLP(L,NY,NX)=AMAX1(0.0,VOLA(L,NY,NX)-VOLW(L,NY,NX)
 2-VOLI(L,NY,NX))+AMAX1(0.0,VOLAH(L,NY,NX)-VOLWH(L,NY,NX)
 3-VOLIH(L,NY,NX))
  ```
  `VOLP` is clamped to $0.0$, but `VOLW` is unmodified.
- In `f77src/hour1.f:3615-3616`:
  ```fortran
  THETW(L,NY,NX)=AMAX1(0.0,AMIN1(POROS(L,NY,NX)
 2,VOLW(L,NY,NX)/VOLY(L,NY,NX)))
  ```
  The volumetric water content fraction `THETW` is capped at `POROS`, but `VOLW` itself remains un-clamped.
- In `f77src/redist.f:5968-5969`:
  ```fortran
  VOLP(L,NY,NX)=AMAX1(0.0,VOLA(L,NY,NX)-VOLW(L,NY,NX)
 2-VOLI(L,NY,NX)+VOLAH(L,NY,NX)-VOLWH(L,NY,NX)-VOLIH(L,NY,NX))
  ```
  Only `VOLP` is clamped.
- In `f77src/redist.f:8397-8402` (subsidence / geometry relayering):
  ```fortran
  XVOLWP=AMAX1(0.0,VOLW(L,NY,NX)+VOLI(L,NY,NX)-VOLA(L,NY,NX))
  IF(XVOLWP.GT.ZEROS(NY,NX))THEN
  DDLYRX(NN)=(-XVOLWP)/AREA(3,L,NY,NX)
  ```
  Excess water over `VOLA` triggers vertical layer expansion/relayering (`DLYR(3,L+1) = DLYR(3,L+1) - DDLYRX`), but does NOT clamp or discard `VOLW`.

#### (2) Does any code path reset `VOLW1` / `VOLW2` to at-most-capacity at substep entry?
- **Finding: NO.**
- In `f77src/watsub.f:204-213`:
  ```fortran
  VOLA1(L,NY,NX)=VOLA(L,NY,NX)
  VOLV1(L,NY,NX)=VOLV(L,NY,NX)
  VOLW1(L,NY,NX)=VOLW(L,NY,NX)
  VOLWX1(L,NY,NX)=VOLWX(L,NY,NX)
  VOLI1(L,NY,NX)=VOLI(L,NY,NX)
  VOLWH1(L,NY,NX)=VOLWH(L,NY,NX)
  VOLIH1(L,NY,NX)=VOLIH(L,NY,NX)
  IF(BKDS(L,NY,NX).GT.ZERO)THEN
  VOLP1Z(L,NY,NX)=VOLA1(L,NY,NX)-VOLW1(L,NY,NX)-VOLI1(L,NY,NX)
  VOLP1(L,NY,NX)=AMAX1(0.0,VOLP1Z(L,NY,NX))
  ```
  `VOLW1` directly receives `VOLW` without any bounds test or adjustment. If `VOLW1 + VOLI1 > VOLA1`, `VOLP1Z` becomes strictly negative, and `VOLP1` is set to $0.0$.
- In `f77src/watsub.f:4927-4932`:
  ```fortran
  VOLW2(N3,N2,N1)=VOLW2(N3,N2,N1)-FLQL
  VOLW2(N6,N5,N4)=VOLW2(N6,N5,N4)+FLQL
  VOLP2(N3,N2,N1)=AMAX1(0.0,VOLA1(N3,N2,N1)
 2-VOLW2(N3,N2,N1)-VOLI2(N3,N2,N1))
  ```
  `VOLW2` changes solely by the physical flux `FLQL`. Only `VOLP2` is clamped to zero.

#### (3) Is `VOLA1` recomputed such that `VOLP1Z` cannot go negative in practice?
- **Finding: NO.**
- `VOLA1` is assigned from `VOLA` at `watsub.f:204`.
- The only conditional reassignment of `VOLA1` occurs at `watsub.f:6833`:
  ```fortran
  ELSE
  VOLP1Z(L,NY,NX)=0.0
  VOLP1(L,NY,NX)=0.0
  VOLPH1Z(L,NY,NX)=0.0
  VOLPH1(L,NY,NX)=0.0
  VOLA1(L,NY,NX)=VOLW1(L,NY,NX)+VOLI1(L,NY,NX)
  VOLAH1(L,NY,NX)=0.0
  ENDIF
  ```
  This is inside the `ELSE` branch of `IF(BKDS(L,NY,NX).GT.ZERO)`, which applies exclusively to non-mineral/zero-bulk-density layers (such as water or surface boundary cells). For any valid soil layer (`BKDS > 0`), lines `6821-6827` execute:
  ```fortran
  IF(BKDS(L,NY,NX).GT.ZERO)THEN
  VOLP1Z(L,NY,NX)=VOLA1(L,NY,NX)-VOLW1(L,NY,NX)-VOLI1(L,NY,NX)
  VOLP1(L,NY,NX)=AMAX1(0.0,VOLP1Z(L,NY,NX))
  ```
  Here `VOLA1` remains the static pore volume and `VOLP1Z` remains negative if overfilled.
- Furthermore, `watsub.f:4898-4903` explicitly tests `IF(N.EQ.3.AND.VOLP1Z(N6,N5,N4).LT.0.0)` and `watsub.f:3683-3686` tests `IF(VOLP1ZN.LT.0.0)`, proving the codebase's control flow actively expects and handles $\text{VOLP1Z} < 0$.

---

### Conclusion

The evidence holds across all surveyed routines. The legacy oracle explicitly anticipates overfilled soil layers at substep entry, tracks the excess via signed `VOLP1Z < 0`, and evacuates it gradually via upward displacement without restricting the valid entry domain.
