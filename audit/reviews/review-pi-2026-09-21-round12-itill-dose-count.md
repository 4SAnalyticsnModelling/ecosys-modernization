# Adversarial Review Round 12: Legacy Tillage Dose Count Verification (Issue-080)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Falsification of Issue-080 claim regarding legacy Fortran `ITILL` indexing, clearing, and per-substep tillage dose count ($24 \times \text{NFH}$).

---

### Verdict: NOT FALSIFIED

The claim in `audit/issues/issue-080-tillage-mixing-applied-once-per-event-versus-legacy-per-substep-dosing.md` is **CONFIRMED** on all points:
1. `ITILL` is indexed by day `I` and is never cleared or updated within a simulation day.
2. `XCORP` is assigned once daily in `DAY` and remains constant throughout the day.
3. The tillage mixing block in `redist.f` is gated solely by day-level variables and contains no reset logic.
4. Because `REDIST` is invoked inside the nested hourly (`J=1,24`) and subhourly (`NFZ=1,NFH`) loops in `soil.f`, the tillage mixing block executes exactly $24 \times \text{NFH}$ times on a tillage day (e.g. 96 doses at $\text{NFH}=4$).

---

### 1. File and Line Citations

#### A. Where `ITILL` is initialized and set
- `f77src/reads.f:792`: Initialized to `-1` for all days $I \in [1, 366]$ across all grid cells:
  ```fortran
  DO 325 I=1,366
  ITILL(I,NY,NX)=-1
  DCORP(I,NY,NX)=0.0
  325 CONTINUE
  ```
- `f77src/reads.f:902`: Populated from the disturbance management file indexed by day `IDY`:
  ```fortran
  ITILL(IDY,NY,NX)=IDIST
  DCORP(IDY,NY,NX)=DDIST
  ```
- `f77src/routs.f:46`: Reinitialized to `0` across days $M \in [1, 366]$ during restart writes if `IMNG.EQ.0`.

#### B. Where `ITILL` is evaluated and `XCORP` is set
- `f77src/day.f:347-358`: Evaluated once per day when `soil.f:131` calls `CALL DAY(I,NHW,NHE,NVN,NVS)`.
  - For $0 \le \text{ITILL} \le 10$: `CORP = AMIN1(1.0, AMAX1(0.05, ITILL(I,NY,NX)/10.0))` and `XCORP(NY,NX) = 1.0 - CORP` (`day.f:348-349`).
  - For $11 \le \text{ITILL} \le 20$: `CORP = AMIN1(1.0, AMAX1(0.05, (ITILL(I,NY,NX)-10.0)/10.0))` and `XCORP(NY,NX) = 1.0 - CORP` (`day.f:354-355`).
  - Non-tillage: `XCORP(NY,NX) = 1.0` (`day.f:357`).

#### C. Where `ITILL` is tested in `REDIST`
- `f77src/redist.f:11277-11278`:
  ```fortran
  IF(ITILL(I,NY,NX).GE.0.AND.ITILL(I,NY,NX).LE.20
 2.AND.XCORP(NY,NX).LT.1.0-ZERO2)THEN
  ```
  The block terminates at `f77src/redist.f:12840` (`C END TILLAGE` at line 12842).
- **Clearing check**: There are zero assignments to `ITILL` or `XCORP` between lines 11277 and 12840 (or anywhere else in `redist.f`). Neither variable is cleared or modified during execution of `REDIST`.

#### D. Loop Nesting in `soil.f`
- `f77src/soil.f:115-127`: Daily time progression where day index `I` advances.
- `f77src/soil.f:131`: `CALL DAY(I,NHW,NHE,NVN,NVS)` updates daily variables, including `XCORP`.
- `f77src/soil.f:135`: `DO 9995 J=1,24` (hourly loop).
- `f77src/soil.f:145`: `DO 9990 NFZ=1,NFH` (subhourly substep loop).
- `f77src/soil.f:221`: `CALL REDIST(I,J,NFZ,NHW,NHE,NVN,NVS)` is called inside both loops.
- `f77src/soil.f:223`: `9990 CONTINUE` (closes subhourly loop).
- Closing loop for hourly index `J`: `soil.f:9995 CONTINUE` occurs at the end of the hourly sequence.

---

### 2. Arithmetic & Dose Count

$$\text{Doses per day} = 24 \text{ hours/day} \times \text{NFH substeps/hour} = 24 \times \text{NFH}$$

For the Ottawa production deck with $\text{NFH} = 4$:
$$\text{Total doses} = 24 \times 4 = 96$$

Because neither `ITILL(I,NY,NX)` nor `XCORP(NY,NX)` is modified within the intraday loops, the condition at `redist.f:11277-11278` evaluates to `.TRUE.` on every call to `REDIST`, resulting in exactly 96 executions of the tillage mixing block on that day.
