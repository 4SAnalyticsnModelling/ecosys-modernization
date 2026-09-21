# Adversarial Review Round 12: Independent Oracle Kernel Generator (`kernelgen.py`)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Technical assessment of `ecosys-audit/scripts/kernelgen.py`, its generated test harness (`kernel_stomate.*`), and feasibility for extracting `WATSUB` and `REDIST` isolated kernels.

---

### K1. What `kernelgen.py` Does, What `kernel_stomate.f` Is, and Build/Run Status

1. **Tool Purpose (`kernelgen.py`)**:
   - Queries `audit/manifest/f77index.json` to extract an authoritative F77 subroutine unit.
   - Traces all `INCLUDE "blk*.h"` and `COMMON` declarations included by the unit.
   - Computes an exact, byte-aligned binary memory layout (`.layout.json`) for all variables referenced by the routine under Intel legacy precision rules (`-r8 -i4`: 8-byte IEEE reals, 4-byte integers).
   - Generates a standalone Fortran 2003 stream I/O driver (`.f`) and a PowerShell build script (`.build.ps1`). The driver reads `kernel_<name>.in` (raw binary stream of the exact pre-call COMMON state), calls the subroutine once with target coordinates/timesteps, and writes `kernel_<name>.out` (post-call state stream).

2. **What `kernel_stomate.f` Is**:
   - A generated test probe for `STOMATE` (`f77src/stomate.f:2-673`), scoping 74 COMMON variables across 15 include blocks, resulting in an exact binary payload of 36,994,008 bytes.

3. **Build & Execution Status**:
   - **NOT BUILT, NOT RUN**. In strict accordance with the runner-lane lock, neither `gfortran` nor the PowerShell build script has been invoked. The files were generated purely via offline text emission from Python.

---

### K2. Target Scope: Can It Extract `WATSUB` and `REDIST` Blocks?

1. **At the Subroutine Level**:
   - **YES**. `kernelgen.py` can immediately target whole subroutines: `python kernelgen.py watsub` and `python kernelgen.py redist`.
   - It will lay out every referenced COMMON variable and generate a driver that calls `SUBROUTINE WATSUB` or `SUBROUTINE REDIST`.

2. **At the Internal Block Level (`watsub.f:2802-2823`, `redist.f:12137-12203`)**:
   - **NOT DIRECTLY AS-IS (Requires minor extension or wrapper)**:
     - `kernelgen.py` currently targets callable Fortran units (`SUBROUTINE` or `FUNCTION`).
     - Neither the `watsub.f` freeze-thaw block nor the `redist.f` tillage block is a standalone subroutine in legacy Fortran; both are embedded inside monolithic ~7,000–13,000 line subroutines wrapped in loop headers.
   - **To extract internal blocks**:
     - Either wrap the target lines (e.g., `watsub.f:2802-2823`) into a clean standalone subroutine file in `audit/tests/kernels/` (referencing the same common blocks), OR
     - Extend `kernelgen.py` with a line-range slicer that wraps the specified statements into an extracted `SUBROUTINE watsub_freezethaw(...)`.

---

### K3. Requirements for Closed-Loop Matched-State Testing (Legacy <-> Zig)

To achieve bit-for-bit numerical parity evaluation:
1. **Binary Input Generation (`kernel_<name>.in`)**:
   - A 50-line Python or Zig script reads the JSON layout (`.layout.json`) and populates the binary buffer at the prescribed byte offsets for the test condition (e.g. setting $T = 252.11\text{ K}$, $\text{VOLW} = 0.0028\text{ m}^3$, all other fields zero or background).
2. **Oracle Execution**:
   - Run `kernel_<name>.exe`, which reads `kernel_<name>.in` and produces `kernel_<name>.out`.
3. **Zig Verification Harness**:
   - A targeted `zig test` loads `kernel_<name>.in` into the corresponding Zig struct (mapped via `bindcheck.py`), runs the Zig kernel (e.g., `enthalpy_balance` or `runtime_adapter`), and compares the resulting fields against `kernel_<name>.out`.
