# Review Round 4: Legacy Tillage Soil-Mixing Identification and Call Ordering

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Identification of legacy tillage soil-mixing routine, call ordering relative to WATSUB, and capacity awareness (`issue-078`).

---

### 1. LEGACY ROUTINE
`f77src/redist.f:11270-12830` (specifically soil water/ice mixing at lines `11900-12200`).
- Gated by `IF(ITILL(I,NY,NX).GE.0.AND.ITILL(I,NY,NX).LE.20.AND.XCORP(NY,NX).LT.1.0-ZERO2)THEN` (`redist.f:11278`).
- Governed by `CORP = 1.0 - XCORP(NY,NX)` (`redist.f:11429`), set in `f77src/day.f:345-360` based on disturbance code `ITILL`.
- Water redistribution formula (`redist.f:12180`):
  `VOLW(L,NY,NX)=TI*VOLW(L,NY,NX)+CORP*(FI*TVOLW-TI*VOLW(L,NY,NX))+TX*VOLW(L,NY,NX)+FI*TVOLWR`

### 2. CALL ORDER
**STRICTLY AFTER `WATSUB` within the same substep/hour.**
- Master orchestration loop in `f77src/soil.f:140-216`:
  ```fortran
  DO 9995 J=1,24                   ! Hourly loop
    CALL WTHR(...)
    DO 9990 NFZ=1,NFH             ! Subhourly loop (e.g., NFH=4)
      CALL HOUR1(...)
      CALL WATSUB(...)            ! line 151
      CALL NITRO(...)
      CALL HFUNC(...)
      CALL UPTAKE(...)
      CALL GROSUB(...)
      CALL EXTRACT(...)
      CALL SOLUTE(...)
      CALL TRNSFR(...)
      CALL TRNSFRS(...)
      CALL EROSION(...)
      CALL REDIST(...)            ! line 214
  9990 CONTINUE
  9995 CONTINUE
  ```
- `REDIST` is invoked at the very tail of every subhourly substep (`NFZ=1..NFH`), strictly downstream of `WATSUB`.
- **Critical architectural distinction**: In Fortran, `REDIST` executes `24 * NFH` (e.g., 96) times throughout the tillage day. Because `WATSUB` runs on the next iteration immediately following each small `CORP` fractional mixing step, `WATSUB`'s mechanical displacement relief continuously mitigates intermediate pore overflows.

### 3. CAPACITY AWARENESS
**NONE (Completely capacity-unaware).**
- Neither `f77src/redist.f:12180` nor any surrounding line contains a check against `VOLP`, `POROS`, or `VOLA`.
- Legacy relies entirely on the dynamic feedback loop: `REDIST` moves a fractional amount `CORP`, and the subsequent `WATSUB` execution on the next substep handles any induced hydraulic gradient / mechanical displacement.

### 4. CONFIDENCE
**HIGH**.
- Verified directly in `f77src/soil.f:151, 214`, `f77src/redist.f:11278, 12180`, and `f77src/day.f:345-360`. Option (b) ("run tillage before WATSUB") is architecturally unfaithful to legacy's intra-substep sequence (where mixing is always downstream of that step's `WATSUB`), though legacy's repeated subhourly cadence means a subsequent `WATSUB` always followed each fractional mixing step.
