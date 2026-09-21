# Adversarial Review Round 3: Audit of Matched-State Kernel Test (commit a39fe40)

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Author/Editor: Claude (claude-opus-5)  
Target: `ecosys-ng/src/soil/water/enthalpy_balance.zig` test `"issue-024: legacy top-layer freeze-rate ceiling versus unconstrained equilibrium partition"`

---

## Verdict

**SOUND AND ADVERSARIALLY DEFENDED**. The test is well-posed, conservative, and directly isolates the kinetic-vs-equilibrium formulation gap without manufacturing artifacts.

---

## Adversarial Attacks & Findings

### A1. Fair model of legacy compounding?
- **VERIFIED**: `watsub.f:2812` uses `VOLW2`, and line `2821` immediately updates it:
  `VOLW2(...) = VOLW2(...) + FLVGS + FLFGS`.
  Because `FLFGS = -VOLW2 * XNPSRX`, the next iteration evaluates against `VOLW2 * (1 - XNPSRX)`.
  Compounding `legacy_liquid_m3 -= legacy_liquid_m3 * xnpsrx` over 80 executions (`NFH * NPH = 4 * 20`) is structurally exact. If `VOLW2` were kept un-compounded at initial water, the ceiling would be `80 * 2.5e-4 = 2.00%` instead of `1.98%`—a negligible difference that does not alter the order of magnitude.

### A2. Evaluating at Oracle's 252.11 K: fair or flattering?
- **FAIR & CONSERVATIVE**:
  1. 252.11 K (-21.04 °C) is the oracle's actual accepted physical temperature at Hour 1.
  2. If evaluated at Zig's own warmer accepted temperatures (-6.05 °C / -11.04 °C from Rounds 2 & 9), `stateAtTemperature` still produces 50.9% – 53.4% ice conversion (a ~26x overshoot).
  3. The freezing curve flattens rapidly below 268 K (-5 °C) near residual water. 252.11 K does not artificially inflate the overshoot; it proves that given the exact same cold boundary state, equilibrium converts ~58% whereas the oracle's kinetics cap it at ~2%.

### A3. Sensitivity to Carsel-Parrish clay_loam curve choice?
- **INSENSITIVE AT THIS TEMPERATURE**:
  At 252.11 K, the thermal driving head (`(T - T0) * L / T0`) corresponds to tens of megapascals of suction. Across all USDA soil texture classes in `carselParrishDefault`, residual liquid water content ranges between 0.04 and 0.10 m³/m³. With initial water at 0.28, equilibrium liquid water fraction drops to near-residual (`theta_r`), forcing conversion of at least `(0.28 - 0.10) / 0.28 = 64%` (or ~58% when accounting for Clapeyron depression).
  No physically possible retention curve could yield a ~2% equilibrium conversion at -21 °C. The ~29x overshoot is robust to curve parameterization.

### A4. Over-assertion or unsupported claims in the test?
- **NONE**:
  The test conservatively asserts `equilibrium_converted_fraction > 10.0 * legacy_converted_fraction` (a 10x floor against a 29.35x measurement) and verifies mass conservation to `1e-15`. It claims kinetics divergence, not a mass-balance bug.
