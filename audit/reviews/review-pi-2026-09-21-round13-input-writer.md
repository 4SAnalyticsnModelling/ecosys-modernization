# Adversarial Review Round 13: Kernel Snapshot Input Writer & STOMATE State Requirements

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Delivery of `kernel_writer.py`, mathematical verification protocol, and minimum physical input state definition for `STOMATE`.

---

### L1. The Binary Input Writer (`ecosys-audit/scripts/kernel_writer.py`)
- Tool committed directly under `ecosys-audit/scripts/kernel_writer.py`.
- **Validation & Loud Failure Guarantees**:
  1. *Unknown variable names*: Raises `WriterError` if any assigned name is absent from the `.layout.json` manifest.
  2. *Subscript dimension checks*: Requires `len(indices) == rank` for indexed updates.
  3. *Bounds checking*: Resolves declared Fortran bounds (e.g. `0:25`, `1:JB`, `1:JP`, `1:JY`, `1:JX`) and verifies each index sits within `[lower, upper]`.
  4. *Column-major element addressing*: Computes standard Fortran linear address:
     $$\text{linear\_idx} = \sum_{k=0}^{R-1} (i_k - \text{low}_k) \prod_{m=0}^{k-1} \text{extent}_m$$
  5. *Strict IEEE binary packing*: Enforces little-endian 64-bit IEEE double precision (`<d`) for all `f64` and 32-bit integer (`<i`) for `i32`. Non-finite floats (`NaN`, `Inf`) abort immediately.
  6. Supports both single-element subscript targeting (`"indices": [0, 1, 1, 1, 1], "value": 298.15`), whole-array broadcast (`"value": 0.0`), and sequential list assignments (`"values": [...]`).

---

### L2. Verification Protocol (Guaranteed Correctness without False Passes)
To prove zero offset drift without relying on trusting the Python code:
1. **Round-Trip Offset Probe**:
   - Write a known unique 64-bit IEEE bit pattern (e.g. `0x4059000000000000` = `100.0` or a distinct magic float like `3.141592653589793`) into a target member at a non-zero multi-dimensional coordinate (e.g., `TKC(NZ=1, NY=1, NX=1)`).
   - In Python: verify that `byte_offset + linear_idx * 8` in the generated `.in` byte stream contains that exact IEEE byte sequence.
2. **Oracle Invariant Read-Back**:
   - Pass an input with non-zero values in variables that `STOMATE` reads but never writes (e.g., atmospheric forcing `CO2Q(NY, NX)`, temperature `TKC(NZ, NY, NX)`).
   - Execute `kernel_stomate.exe`.
   - Inspect `kernel_stomate.out` at the exact same byte offset: the value must emerge bit-for-bit identical, proving the Fortran driver read and wrote the identical memory slot without address corruption.

---

### L3. Minimum Physical State for Non-Degenerate `STOMATE` Execution
In `f77src/stomate.f:2-80`, `STOMATE` calculates canopy stomatal resistance at maximum turgor. Running with all zeros triggers immediate division by zero (`1.2194E+04 / TKC` at line 55) or skips execution entirely via line 57's gate:
```fortran
IF(SSIN(NY,NX).GT.0.0 .AND. ARLFP(NZ,NY,NX).GT.ZEROP(NZ,NY,NX)) THEN
```
To obtain a valid, non-degenerate scientific calculation for coordinates `NZ=1, NY=1, NX=1`, the snapshot must provide non-zero values for:
1. **Canopy Temperatures & State**:
   - `TKC(1, 1, 1)`: Absolute canopy temperature, e.g. `298.15` K (25 °C). (Line 55: divides by `TKC`).
   - `TCC(1, 1, 1)`: Celsius canopy temperature, e.g. `25.0` °C. (Lines 69-70: aqueous solubility exponents).
2. **Radiation & Illumination**:
   - `SSIN(1, 1)`: Sine of solar elevation angle, $> 0.0$, e.g. `0.866` (60° elevation). (Gating condition at line 57).
   - `PAR(1, 1, 1)`: Photosynthetically active radiation, e.g. `1200.0` $\mu\text{mol m}^{-2}\text{ s}^{-1}$.
   - `PARDIF(1, 1, 1)`: Diffuse PAR, e.g. `200.0`.
3. **Canopy Geometry & PFT Traits**:
   - `ARLFP(1, 1, 1)`: Total PFT leaf area index, $> \text{ZEROP}$, e.g. `3.0` $\text{m}^2\text{ m}^{-2}$.
   - `ARLF(K=1..N, 1, 1, 1, 1)`: Node-specific leaf area, e.g. `0.5` $\text{m}^2$.
   - `WGLF(K=1..N, 1, 1, 1, 1)`: Node leaf carbon mass, e.g. `15.0` g C.
   - `FCO2(1, 1, 1)`: Intercellular to atmospheric $\text{CO}_2$ ratio, e.g. `0.70`.
4. **Atmospheric Environment**:
   - `CO2Q(1, 1)`: Atmospheric $\text{CO}_2$ mixing ratio, e.g. `400.0` $\mu\text{mol mol}^{-1}$.
   - `O2I(1, 1, 1)`: Oxygen concentration, e.g. `2.1E+05` $\mu\text{mol mol}^{-1}$.
   - `SURFX(1, 1, 1)`: Canopy surface air boundary conductance, $> 0.0$.
