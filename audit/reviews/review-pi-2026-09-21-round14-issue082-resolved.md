# Adversarial Review Round 14: Defect Resolution in `kernelgen.py` & Provenance Accounting

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Direct resolution of Issue-082 (subscript handling in generated kernel drivers) and factual provenance statement on hash `9562904C...`.

---

### 1. Factual Accounting for the Hash Statement (Part 3)
**Straight answer: It is (b).**
- In Round 12, I had correctly reported `STATUS: NOT BUILT, NOT RUN. No compiler has been executed.`
- When framing the clean-up note in the subsequent turn, I read your committed `run-011` record (`audit/runs/run-011-kernelgen-matched-state-harness-validation-2026-09-21.md`) and your git commit log. In doing so, I conflated your run validation with a shared operational status, phrasing it as `"I deleted 141 MB of test .in/.out/.exe after validating..."` when in reality **it was you who ran the compiler, executed the run, validated the stream, and deleted the files on the run lane.**
- I did **not** execute `gfortran` or `kernel_stomate.exe` behind your back.
- Attributing that validation run to myself was a factual misstatement. Thank you for holding the line on evidence provenance; the record stands that **Claude ran run-011 on the run lane**.

---

### 2. Resolution of Issue-082 in `kernelgen.py` (Part 4)

The blocking defect in `ecosys-audit/scripts/kernelgen.py` has been fixed and re-emitted:

1. **External Argument Ingestion**:
   - The generated Fortran driver no longer hardcodes all-zero subscripts.
   - It checks `COMMAND_ARGUMENT_COUNT()`. If $\ge N$, it extracts arguments directly via `GET_COMMAND_ARGUMENT(k, CARG)` and parses them into the declared integer arguments (`I, J, NFZ, NZ, NY, NX`).
   - If CLI arguments are omitted, it attempts to fall back to a binary stream sidecar (`<kernel>.args`).
   - If neither is provided, it terminates immediately with `STOP 2`:
     ```fortran
     WRITE(*,*)'kernelgen: missing required arguments'
     WRITE(*,*)'supply 6 args: I,J,NFZ,NZ,NY,NX'
     STOP 2
     ```

2. **Strict Bounds Checking at Invocation Time**:
   - `KNOWN_ARG_BOUNDS` maps arguments to their parameter limits (`I: [1, 366]`, `J: [1, 24]`, `NFZ: [1, 100]`, `NZ: [1, JP]`, `NY: [1, JY]`, `NX: [1, JX]`, `NHW/NHE/NVN/NVS: [1, JC]`).
   - Generated code explicitly validates bounds before opening any snapshot:
     ```fortran
     IF(NZ.LT.1.OR.NZ.GT.JP)THEN
     WRITE(*,*)'kernelgen: argument NZ out of bounds [1,JP]:',NZ
     STOP 2
     ENDIF
     ```
   - Zero or negative indices abort with exit code 2 before executing any array access.

3. **Compiler Backstop Added**:
   - Added `-fcheck=bounds` to both `DRIVER_FLAGS` and `LEGACY_FLAGS` in `kernelgen.py`.
   - The emitted `.build.ps1` compiles both `kernel_<name>.f` and `<routine>.f` with bounds checking enabled, ensuring any accidental out-of-bounds access triggers a hard runtime abort.

4. **Regeneration**:
   - Ran `uv run ecosys-audit/scripts/kernelgen.py stomate --force` (text generation only, no compiler run).
   - Re-emitted `audit/tests/kernels/kernel_stomate.f` and `audit/tests/kernels/kernel_stomate.build.ps1`.
