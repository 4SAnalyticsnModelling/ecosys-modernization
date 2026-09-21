# Adversarial Review Round 8: Audit of Issue-080 Tillage Cadence Discrepancy

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial verification of F1, F2, and F3 for `issue-080` (single event vs 96 legacy substep doses).

---

### F1. Is ecosys-ng using legacy's per-substep `CORP` or an already-cumulative fraction?
**VERIFIED: IT USES LEGACY'S PER-SUBSTEP `CORP` RAW (NO CUMULATIVE CONVERSION).**
- In `ecosys-ng/src/management/disturbance_schedule.zig:75, 79`:
  - `code <= 10`: `mixing_fraction = @max(0.05, @as(f64, @floatFromInt(code)) / 10.0)`
  - `code > 10`: `mixing_fraction = @max(0.05, @as(f64, @floatFromInt(code - 10)) / 10.0)`
  This translates `day.f:348, 354` line-for-line (`CORP = AMIN1(1.0, AMAX1(0.05, ITILL / 10.0))`).
- In `disturbance_management_dispatch.zig:1110` -> `runtime_adapter.zig:999` -> `physical_redistribution.zig:redistribute`, this raw `mixing_fraction` is passed directly as `CORP` into `redist.f:12180`'s formula:
  `VOLW = TI * VOLW + CORP * (FI * TVOLW - TI * VOLW) + ...`
- There is **no cumulative conversion** (e.g. $1 - (1 - \text{CORP})^{96}$ or equivalent). Ecosys-ng takes the exact single-substep legacy fraction and applies it only once.

### F2. Does anything in legacy clear `ITILL` or raise `XCORP` mid-day?
**VERIFIED: NOTHING CLEARS THEM MID-DAY.**
- Comprehensive search across `f77src/`:
  - `ITILL(366, JY, JX)` is populated at read-time in `reads.f:902` and only reset at yearly rollover (`routs.f:46`).
  - `XCORP(JY, JX)` is modified **only** in `day.f:349, 355, 357`.
  - `soil.f` executes `DO 9995 J=1,24` / `DO 9990 NFZ=1,NFH`, calling `REDIST` `24 * NFH` times. Neither `soil.f`, `redist.f`, nor any sub-routine resets `XCORP` or `ITILL` during the 24 hours of that calendar day.
- Legacy's tillage gate (`redist.f:11278`) unconditionally executes **96 times** on a tillage day at `NFH=4`.

### F3. Mathematical difference between 1 dose vs 96 doses at `CORP = 0.8`
**RADICALLY DIFFERENT END STATES (Order-of-magnitude departure):**
- Let deviation from layer mean be $\Delta_n = V_n - \bar{V}$. Each substep contracts deviation by:
  $$\Delta_{n+1} = (1 - \text{CORP}) \Delta_n = 0.2 \Delta_n$$
- **1 Dose (ecosys-ng)**:
  $$\Delta_1 = 0.2 \Delta_0 \quad (\mathbf{80\% \text{ homogenized, } 20\% \text{ residual gradient}})$$
- **96 Doses (legacy)**:
  $$\Delta_{96} = (0.2)^{96} \Delta_0 \approx 7.9 \times 10^{-68} \Delta_0 \quad (\mathbf{100.000\% \text{ complete homogenization}})$$
- Even for mild tillage (`ITILL=1`, `CORP=0.1`):
  - 1 dose: $(1 - 0.1)^1 = 0.90$ (10% mixing).
  - 96 doses: $(0.9)^{96} \approx 3.9 \times 10^{-5}$ (>99.99% complete homogenization).
- **Conclusion**: Legacy tillage completely homogenizes all soil properties across the tilled depth by the end of the day. Ecosys-ng leaves massive residual gradients after a single partial blend.
