# Playbook: Solver Convergence & Mass/Energy Balance Failures

**Owner: CLAUDE.** CLAUDE leads the strategy and teaches it to DEEPSEEK. DEEPSEEK applies it, step by step.
Problem: the ReleaseFast Ottawa run stops progressing because of convergence failures, in one of two forms:
- the mass/energy balance does not close;
- the Newton/Anderson solver does not converge.

Examples so far:
- frozen topsoil at 269 K, ψ ≈ −4.6 MPa, stalling at 1.6e-7 of capacity at every substep count;
- phase stagnation;
- stiff solute chemistry at high pH.

## 0. First principle: legacy never iterates
- Legacy ecosys steps each hour **explicitly** in fixed sub-cycles; there is no convergence loop to fail:
  - `NPH=NPX` cycles per hour, from the options deck (`wthr.f:589-611`);
  - nested `NPT=NPY` cycles for gas, `NPR=30` litter, `NPS=20` snow, `NPRS=10` litter under snow.
- The Zig Newton/Anderson solves are **intentional numerics** (plan D2). They must reproduce the legacy
  trajectory. A non-converging hour is therefore a defect in *our* implicit formulation, not a legacy property.
- **The legacy trajectory is the oracle.** Any fix must keep (or restore) output parity with legacy.

## 1a. Rule out bugs first: DEEPSEEK, before any solver strategy
A solver that won't converge, or a ledger that won't close, is most often a **bug in the port**, not a
numerical problem. Check these four in order for the routines that touch the failing hour, layer and
variables. Record each check as PASS or FAIL in the round file, with `file:line` evidence. Use the
`ecosys-process-science-parity`, `ecosys-fortran-zig-traceability` and `ecosys-state-io-bindings` skills.

1. **Science bug**: does the Zig equation differ from the legacy Fortran?
   - Check every term, sign, unit conversion, constant and branch condition, against the exact `f77src` lines.
2. **Translation bug**: is a Fortran statement reproduced wrongly?
   - Check 0-based vs 1-based and column-major indexing, and loop bounds (`DO` inclusive ends).
   - Check implicit `-r8 -i4` typing (integer division, truncation) and intrinsic precision.
   - Check arithmetic `IF`/`GOTO` flow, `SAVE`/`DATA` initial state, and order of updates within a cycle.
3. **Binding bug**: is a COMMON variable mapped to the wrong, stale, uninitialized or default-zero Zig state?
   - Check for state read before it is updated, or an output, input or unit mismatch.
   - Check that the solver and the ledger read the *same* state.
4. **Duplication bug**: is something applied twice, or kept in two copies?
   - The same flux, source or sink added in two modules or two code paths, or counted in both a substep
     and the hourly total.
   - A double transfer (e.g. pond→soil, freeze/thaw, a fertilizer or tillage event) counted by two routines.
   - Duplicated state copies that drift out of sync.
   - The same conversion applied twice.

5. **Floor-bound bug**: does a guard use a different floor, scale, comparison or placement than legacy? See §1b.

Only when all five pass may DEEPSEEK move on to the numerical triage (§1) and the strategy ladder (§2).

## 1b. Floor-bound audit (`0.0` and the `ZERO*` family)
Legacy ecosys guards almost every division, logarithm, flux and transfer with floors. The floors differ in
value, in scale, and in how often they are recomputed. A Zig guard that uses the "wrong zero" changes a
branch exactly where the run stalls: thin sliver layers, near-dry or frozen layers, vanishing pools and
plants.

| Legacy floor | Value / definition | Scale | Notes |
|---|---|---|---|
| `0.0` literal | exactly zero | none | `.GT.0.0` is **not** `.GT.ZERO` |
| `ZERO` | 1.0E-15 (`starts.f:93`) | absolute | 418 legacy uses |
| `ZERO2` | 1.0E-06 (`starts.f:94`) | absolute | also `DLYRM=ZERO2` |
| `ZEROS(NY,NX)` | `ZERO*DH*DV` (`starts.f:269`) | grid-cell area | 477 uses |
| `ZEROS2(NY,NX)` | `ZERO2*DH*DV` (`starts.f:270`) | grid-cell area | 243 uses |
| `ZEROP(NZ,NY,NX)` | `ZERO*PP` (`startq.f:886`, `grosub.f:10914`) | plant population | **recomputed daily** as PP changes |
| `ZEROQ(NZ,NY,NX)` | `ZERO*PP/AREA(3,NU)` (`startq.f:887`, `grosub.f:10915`) | population per area | recomputed daily |
| `ZEROP2(NZ,NY,NX)` | `ZERO2*PP` (`startq.f:888`, `grosub.f:10916`) | plant population | recomputed daily |
| `ZEROC` | **1.0E-32 in `solute.f:131`; 1.0E-48 in `starte.f:100`** | routine-local PARAMETER | value depends on the routine |

Rules for each guard on the failing path:
1. **Same floor.** The Zig guard must use the same floor as the legacy line. The usual errors:
   - `ZERO` vs `ZERO2` vs `ZEROS`/`ZEROS2` vs `ZEROP`/`ZEROQ`/`ZEROP2` vs `ZEROC` vs `0.0`;
   - for `ZEROC`, using the other routine's value (1e-32 in SOLUTE, 1e-48 in STARTE).
2. **Same comparison.** Check the operator (`.GT.`/`.GE.`/`.LT.`/`.LE.`), the compared variable, and the sign.
   - `AMAX1(ZERO,X)` (floor the value) is not `IF(X.GT.ZERO)` (skip the process).
   - A `.GT.` turned into `>=` flips the branch at exactly the floor.
3. **Same scale, with no deck coincidence.**
   - `ZEROS`/`ZEROS2` scale with cell area. At Ottawa `DH*DV = 1 m²`, so a Zig literal `1e-15`/`1e-6`
     matches here only by coincidence. Derive the floor the legacy way: area-scaled, or from the current
     plant population.
   - Plant floors must be recomputed from the **current** population (as `grosub.f:10914-10916` does daily),
     never cached from startup.
4. **Same units.** If a Zig module changed units (per cell ↔ per m², g ↔ kg, MJ ↔ J, mol m-3 ↔ mol), the floor
   must be converted too.
5. **Same placement.** Legacy applies floors inside explicit cycles. A floor moved into an implicit
   Newton/Anderson residual or Jacobian (`max(x, floor)`) makes the function non-smooth and can stall Newton.
   A floor that clips state removes mass or energy, which is a class E leak.
   - Every clip must either match legacy exactly, or be booked in the ledger.
6. **Find the literals.** The Zig code hard-codes `1e-15` about 1,470 times and `1e-6` about 500 times, against
   418 legacy `ZERO` and 39 `ZERO2` uses. So many literals stand in for scaled floors or for other legacy
   constants.
   - For the routines on the failing path, list every guard (floor, threshold `IF`, `AMAX1`/`AMIN1`/`MAX`/`MIN`):

     `Zig file:line ↔ legacy file:line ↔ floor name ↔ value ↔ scale ↔ operator ↔ PASS/FAIL`

   - Fix each FAIL by citing the legacy line. Prefer a named Zig constant derived as legacy derives it over
     a bare literal.
A FAIL is fixed as a normal round, with legacy evidence, and the failing hour is replayed before going on.

## 1. Triage: DEEPSEEK, on every failure, before changing code
Build a **diagnostic packet** and save it under `audit/runs/<id>/` (cite only the receipt):
- the hour, substep, solver (water / heat / solute / gas / canopy), layer(s), and state:
  - T, ψ, θ, ice, pond, snow, and the bounding thresholds;
- the per-iteration history:
  - residual norm, increment norm, and which test failed (mass, energy or increment);
  - any NaN/Inf, and the Jacobian's smallest pivot.

Then:
1. **Replay the failing hour from the nearest checkpoint in `ReleaseSafe` and in `Debug`.**
   - ReleaseFast removes runtime safety: an out-of-bounds index, overflow or `unreachable` becomes silent
     undefined behaviour.
   - If ReleaseSafe panics, or Debug differs from ReleaseFast on the same hour, it is **a bug, not
     numerics**. Fix it first.
2. **Finite-difference check of the Jacobian** at the failing state. A wrong analytic derivative is the
   most common cause of a Newton stall.
3. **Classify the failure:**

   | Class | Signature | Typical fix (§2) |
   |---|---|---|
   | A. Code/translation bug | ReleaseSafe panic, Debug≠Fast, FD-Jacobian mismatch, legacy line not reproduced | fix the code |
   | B. Threshold crossing | iterate crosses freezing point T*, saturation, pond/snow on-off, θr, dry limit | S4, S3, S6 |
   | C. Degenerate/stiff | very dry ψ (MPa), frozen K→0, high-pH chemistry, sliver layers | S7, S5, S6 |
   | D. Oscillation | residual cycles between iterates; Anderson ping-pong | S3, S5 (restart AA) |
   | E. Balance leak | solver "converges" but the ledger does not close | S1, S2; missing flux/storage term |

## 2. Strategy ladder (how other land models handle it)
Apply the strategies in order; each rung is a separate, logged attempt. DEEPSEEK owns S1–S3, S6 and S7.
CLAUDE chooses and briefs S4, S5, S8 and S9.

- **S1. Converge on the conserved quantity.** Test the **residual of the mass/energy balance**, not only the
  size of the update.
  - Celia's mixed-form scheme tests water-balance closure; Dall'Amico tests the energy residual in W.
  - CLM5 for scale: it stops when energy error > 0.02 W m⁻² or water error > 1e-3 mm per step.
  - Use scaled, per-variable tolerances: relative to layer capacity, plus an absolute floor.
- **S2. Mass/energy-conservative formulation.**
  - Compute storage change as Θ(ψⁿ⁺¹) − Θ(ψⁿ) (mixed form). Use **chord-slope** capacities ΔΘ/Δψ and
    ΔH/ΔT, not point derivatives (Celia 1990; Clark et al. 2021 Eqs 44, 48).
  - Use enthalpy as the energy state through phase change.
  - If the residual converges but the ledger leaks, look for a flux or storage term updated with a
    different state than the one the solver used.
- **S3. Globalize Newton.**
  - **Backtracking line search** on ‖R‖: if ‖R‖ grows, scale the step by δ ≤ 1 (Dall'Amico Eqs 50–51;
    SUMMA accepts after about 5 backtracks).
  - **Cap the update per iteration**: e.g. PFLOTRAN `MAXIMUM_PRESSURE_CHANGE`; |ΔT| of about 1–2 K near
    T*; a relative |Δψ| cap.
  - Keep states physical by **shortening the step**, never by clamping the result afterwards.
- **S4. Phase change (freeze/thaw).**
  - When an iterate crosses T*, **split the step at T*** and restart on the other side.
  - Use the **maximum apparent heat capacity** on the crossing (Hansson "C-max").
  - Keep ψ(T) consistent with "freezing = drying" (Dall'Amico; Painter).
  - Any smoothing of the freezing curve is a DEV, decided by CLAUDE, and needs an A/B run showing legacy
    outputs unchanged.
- **S5. Robust fallback linearization.**
  - Start with Picard / modified Picard or the **L-scheme**, which converges even in degenerate dry or
    saturated cases, then **switch to Newton** near the solution (Stokke et al. 2023).
  - **Anderson**: use small depth (m = 1–5); **restart the history whenever the residual increases**; reject
    an AA step that is worse than the plain step (safeguarding, Walker & Ni).
  - AA speeds up linearly converging Picard, but not quadratic Newton.
- **S6. Time-step control.**
  - On failure, **reject the step**, restore the saved state, cut Δt (×0.25, the CVODE/IDA default; or ×0.5),
    and retry.
  - Grow Δt back gradually (×1.5–2 after several easy steps).
  - Cap consecutive cuts (CVODE gives up after about 7–10) and log every cut.
  - Align substeps with forcing discontinuities: rain onset, tillage, fertilizer, irrigation, snowfall.
    SUMMA restarts integration at each forcing window.
  - The legacy hour is the outer window: substeps must sum to it exactly.
- **S7. Scaling & conditioning.**
  - Nondimensionalize unknowns and residuals per layer (heat capacity, porosity).
  - Never apply a single absolute tolerance to a 1e-12 sliver or a frozen, dry layer. A stall "at 1.6e-7 of
    capacity at every substep count" is a scaling/tolerance problem (class C), not a reason to publish.
- **S8. Coupling / splitting.**
  - If the coupled heat–water solve fails, solve **sequentially**: water then heat, with a consistent ice
    update (Dall'Amico half steps; SUMMA splitting).
  - Follow the legacy `watsub.f` order, and confirm parity by A/B.
- **S9. Last rung: legacy-faithful explicit sub-cycling.**
  - If the implicit path cannot converge within budget for an hour, run that hour with the **translated
    legacy explicit cycles** (`NPH` from the deck). By construction this has legacy parity.
  - Report the number of such hours as a metric. The goal is to drive it to zero by fixing S1–S8.

## 3. Forbidden "fixes"
- Loosening a tolerance, or raising an iteration or step ceiling, to get past a failure. The only exception
  is a ceiling justified from legacy (plan D6).
- Clamping states after the solve; any change that drops mass or energy.
- Accepting a non-converged state whose ledger does not close.
- New "publish best-bounded endpoint" deviations in the style of DEV-009/011/014/015. These are **debt**:
  - no new one without CLAUDE's architecture ruling;
  - existing ones are to be retired by S1–S9.
- Silent retries. Every attempt, cut and fallback is logged with its reason.

## 4. Who does what
- **DEEPSEEK**:
  - builds the packet (§1);
  - runs the ReleaseSafe/Debug replay and the FD-Jacobian check;
  - applies S1, S2, S3, S6 and S7 itself, one per attempt, recording each in the round file.

  Escalate (status `ESCALATED`) with the packet when any of these holds:
  - two strategies have failed;
  - the class is B, C (stiff chemistry), D, or E with an unknown missing term;
  - a fix needs S4, S5, S8, S9, or a DEV.
- **CLAUDE** (lead):
  - classifies the failure and picks the strategy;
  - writes a **Strategy Brief** in §3 of the round (≤ 6k tokens), containing:
    1. the class and evidence;
    2. the chosen rung and why;
    3. exact steps with `file:line` and the commands to run;
    4. the acceptance test (balance thresholds, iteration and substep counts, legacy comparison);
    5. what not to do.

  CLAUDE also reviews the result and adds a **Lesson** below, so that Qwen reuses it next time.

## 5. Metrics (report in every solver round)
- Newton/Anderson iterations per hour (median / max).
- Substep cuts per hour.
- S9 fallback hours.
- Max mass and energy balance residual per hour.
- ReleaseFast wall time per simulated day.

## 6. Lessons (CLAUDE appends one line each: date, round, class, fix, result)
-

## Sources
- Clark et al. 2021, *The Numerical Implementation of Land Models: Problem Formulation and Laugh Tests*, J. Hydrometeorol. 22 (doi:10.1175/JHM-D-20-0175.1): chord-slope capacities, restart at forcing windows, balance checks.
- Spiteri et al. 2024, *Accurate and Efficient Numerical Simulation of Land Models Using SUMMA With SUNDIALS*, JAMES: https://agupubs.onlinelibrary.wiley.com/doi/10.1029/2024MS004256
- Dall'Amico et al. 2011, *A robust and energy-conserving model of freezing variably-saturated soil*, The Cryosphere 5: https://tc.copernicus.org/articles/5/469/2011/ (globally convergent Newton, C-max, energy residual).
- Stokke et al. 2023, *An adaptive solution strategy for Richards' equation*: https://arxiv.org/abs/2301.02055 (L-scheme ↔ Newton switching; Newton failure in degenerate cases).
- List & Radu 2016, *A study on iterative methods for solving Richards' equation*, Comput. Geosci.: https://arxiv.org/abs/1507.07837
- Celia, Bouloutas & Zarba 1990, mixed-form mass-conservative Richards (modified Picard); Kavetski, Binning & Sloan 2001, *Adaptive time stepping and error control in a mass conservative numerical solution of the mixed form of Richards equation*.
- PFLOTRAN Newton solver card (`MAXIMUM_PRESSURE_CHANGE`, divergence tests): https://documentation.pflotran.org/user_guide/cards/subsurface/newton_solver_card.html
- CLM5 Technical Note (BalanceCheck limits, adaptive Richards substepping): https://www2.cesm.ucar.edu/models/cesm2/land/CLM50_Tech_Note.pdf
- SUNDIALS CVODE/IDA step-failure recovery (η = 0.25 after convergence failure): https://sundials.readthedocs.io/en/latest/cvode/Mathematics_link.html
- Walker & Ni 2011, *Anderson Acceleration for Fixed-Point Iterations*, SIAM J. Numer. Anal.
- Zig build modes (ReleaseFast removes safety checks; `unreachable` is UB): https://ziglang.org/learn/overview/
