# Near-zero, balance, finite-state and nonlinear recovery

Authority: [protocol](../protocol.md). Scientific accuracy and prompt forward progress are
joint requirements. A benign zero/trace state must complete with validated finite work, without
spurious errors; a real defect must be repaired. No-change retries, larger acceptance bands,
or publishing an unresolved iterate do not satisfy either requirement. Legacy uses explicit
fixed subcycles: its completion is an oracle for process semantics, not proof that a new
implicit equation converged or that legacy's negative pools and balance warnings are acceptable.
NaN/Inf, impossible inventories and unexplained transient excursions are unacceptable even
when legacy continues or a later hour cancels them. Diagnose and repair the Zig model; if valid
recovery cannot be demonstrated, an explicit failed run is preferable to contaminated results.

## Diagnose once, on the smallest state

1. Reconcile existing edits/jobs and reuse a hash-matched captured failure. If absent, reproduce
   the parent once and capture the earliest failing kernel/layer/hour. Do not repeat a full
   trajectory for a local numerical question. Separate solver, conservation and admissibility gates.
2. Record source/deck/executable/fixture identities, units and time support, old/trial state,
   signed raw residual, absolute/relative allowance, normalization reference, arithmetic-error
   estimate, active floors/branches, Newton step and damping, residual/Jacobian evaluations,
   recovery/substep counts and total work budget. Keep a bounded trace of first/last iterations,
   worst components and branch changes; put full evidence on disk, not in handoffs.
3. Re-derive producers, exchanges and consumers with `f77query.py`: signs, units, binding,
   ordering, shared supply, precision and floor placement first. Then test the implicit residual
   and its Jacobian; an equation introduced by modernization needs its own derivation even when
   there is no legacy solver counterpart. A small magnitude alone does not establish roundoff.
4. Choose one discriminating experiment from the table. Predict its numerical and physical
   outcome before running it. After three unproductive experiments reduce the state or change
   hypothesis. Preserve rejected hypotheses with their binding and falsifier.

| Evidence | Next experiment and remedy |
|---|---|
| Raw residual falls but normalized residual stalls/grows | Inspect the denominator; use fixed, unit-correct entry/source/family references and a justified absolute allowance. Never scale by the current residual or only by a vanishing iterate. |
| Residual plateaus near arithmetic resolution | Independently estimate cancellation error from operands/operations; compare a stable formulation or higher-precision diagnostic oracle. Use conserved increments, shared fluxes and compensated sums before changing precision policy. |
| Iterate crosses dry/wet, phase or floor boundaries | Evaluate each branch and one-sided derivatives. Use feasible steps or an active-set/semismooth treatment of the actual constraint; reset incompatible Anderson history. Do not smooth away physics or replace a required equality with a bound. |
| Newton direction disagrees with directional differences | Check residual/unknown units, row/column scales, perturbation sizes and bounds; repair Jacobian or stale coefficients. Perturbations must be representable and must not cross an unintended branch. |
| Oscillation or repeated feasible states | Inspect line-search merit and coupling order; use damped Newton and bounded Anderson recovery with refreshed derivatives/history. Tiny steps alone never certify convergence. |
| Negative pool or balance defect exceeds arithmetic uncertainty | Trace the earliest unmatched debit/credit and combined consumers. Repair supply competition, stoichiometry, ownership or accounting; normalization cannot repair missing material. |
| First NaN/Inf or invalid arithmetic domain | Capture the producing operation and operands before further arithmetic; distinguish bad input/state from a rejected private solver probe. Repair the domain, stable formulation or ownership; never substitute zero or a large finite sentinel. |
| Finite spike followed by a compensating hour | Trace the first anomalous producer/transfer, units, timestep factors, lag/reset and available supply/energy. Check each interval and component; later cancellation cannot validate the earlier state. |
| Iteration limit exhausted | Inspect actual progress and nested evaluation counts. Fix the diagnosed cause; use a justified bounded recovery/substep schedule sharing the remaining budget. Never reset the budget on each retry. |

## Keep four numerical meanings separate

- **Legacy process thresholds:** preserve value, units, area/population scaling, comparison,
  time of refresh and placement. `ZERO=1e-15`, `ZERO2=1e-6`; `ZEROS/ZEROS2` scale with area,
  `ZEROP/ZEROQ/ZEROP2` with population/area; `ZEROC=1e-32` in SOLUTE and `1e-48` in STARTE.
  Distinguish a working-concentration floor, denominator guard, branch test and stored-pool
  mutation. None automatically defines a mass-balance allowance or Newton stopping tolerance.
- **Solver allowance:** for each residual row use `T_i = A_i + r_i*S_i` in that row's units.
  Establish `A_i` and the reference recipe before candidate qualification. Freeze `S_i` during
  an attempt from relevant entry inventory, known integrated supply or participating chemical
  family/site capacity; include newly supplied species. Do not dilute an active trace equation
  with unrelated dormant stock. Keep unknown scaling distinct from residual scaling.
  Require finite nonnegative scales/allowances and compare `abs(R_i) <= T_i` directly. If
  `T_i=0`, only an exact finite zero residual passes; do not compute `0/0` for a reported score.
  Do not replace a zero reference with the smallest floating-point number and amplify noise.
- **Conservation allowance:** independently evaluate `R = (new-old)-sources+sinks`, with
  integrated amounts and an established absolute-plus-relative rule for each quantity/scope.
  Use relevant interval activity for process diagnostics; no huge unrelated stock or cancelling
  net flux may hide a local leak. Report the rule's exact denominator. Runtime and F2 raw
  validation must both pass; a different normalization in the validator needs explicit scientific
  reconciliation, not a runtime-only exemption or an undocumented schema change.
- **Arithmetic uncertainty:** derive a separate bound from actual operations and magnitudes
  before cancellation, including upstream rounding. Reproduce decisive cases with a stable or
  higher-precision independent calculation. A chemistry floor is not machine precision; a
  multiplier fitted to the observed failure is not an error analysis. Retain the raw signed
  residual. Account for any existing roundoff allowance within the established physical error
  budget; if uncertainty prevents demonstrating that budget, improve the formulation/precision
  or classify it INCONCLUSIVE. Never enlarge the scientific allowance to match the noise.

A concentration floor `c` in mol/m3 corresponds to `c*participating_water_volume` in mol,
or `c*participating_water_volume/area` in mol/m2. A mol/Mg coordinate instead uses its owning
soil mass. Include zone fractions and stoichiometric conversions exactly once. Literal reuse
of `1e-32` across these units requires evidence; DEV-010 is an audit target, not a blanket waiver.
Tiny H+ or trace nutrient pools can control pH/rates: numerical size alone does not establish
scientific insignificance. Preserve legitimate small pools even when their equation passes.

## Signed outstanding balances and negative pools

For the identity above, `R>0` is an unexplained surplus relative to recorded transfers;
`R<0` is an unexplained deficit. Neither sign locates the cause: a missing recorded input can
also appear as a surplus, and an omitted output as a deficit. Audit storage and fluxes separately.

| Condition | Required handling |
|---|---|
| Exact inactive state: zero residual, no entry inventory or active/incoming source | Return a validated no-op through all normal acceptance/ledger checks. Prove coupled transfers and dependent reactions are inactive; do not skip an entire family because one species is zero. |
| Positive or negative residual within all established allowances | Accept promptly without a spurious warning. Preserve signed defect and numerical uncertainty in local and cumulative evidence; passing is not permission to erase the discrepancy. |
| Either sign outside any applicable allowance | Keep the step private, diagnose and correct the responsible equation/transfer, then re-evaluate. No baseline rebase, phantom source/sink, arbitrary redistribution or unmodeled balancing reservoir. |
| Actual negative mass pool | Distinguish from a negative residual. Constrain the coupled rates/reaction extents so all consumers share available supply and every donor/recipient changes consistently. A globally closed ledger cannot legalize a negative pool. |
| Tiny negative value alleged to be roundoff | Prove the operation-specific error bound and conservative representation. Prefer recomputing the shared transfer/endpoint; no after-solve clipping. Any existing sanctioned roundoff normalization must retain its signed correction and pass independent local/global/cumulative ledgers. |
| Per-step residuals pass but cumulative signed drift or absolute defect exceeds its budget | Reject the affected acceptance claim and fix the repeated bias. Opposite signs and spatial cancellation must not erase evidence. |

Use one shared transfer amount for equal/opposite debit and credit; chemical extents preserve
elemental stoichiometry and charge, heat uses the consistent sensible/latent/reference terms.
Fix excess withdrawal jointly across processes, not by charging an arbitrary reserve or making
one pool absorb another's deficit. If a changed allocation departs from legacy semantics,
register and validate its science/output effect before production acceptance.

Retain signed cumulative defects, sums of absolute local defects, worst location and numerical
corrections across hours, scenes, restarts and substeps. Do not reset away a failed interval.
Maintain each scope separately; do not double-count a transfer across nested layer/domain ledgers.
Carry a predeclared cumulative error budget; do not grant the full hourly allowance to every
substep or multiply it by retries. Diagnostic accumulators record discrepancies, never act as
physical pools or authorize their later repayment. An already committed invalid state requires
quarantining its dependent evidence and replaying from the last valid checkpoint after the fix.

## Prevent nonfinite values and unexplained spikes

Audit inputs/restarts → producers → exchanges → consumers → solver → acceptance → writers.
Start with the failing path, then inventory analogous hazards in shared and dormant paths with
legacy/Zig source anchors, a minimal reproducer, repair/DEV disposition and affected tests.
Use historical reports as leads, not verified numerical fixtures. Fix demonstrated legacy
vulnerabilities in Zig and attribute the differences; never reproduce a defect just for parity.

- Require explicit finite/domain validation at input and restart ingestion, hazardous arithmetic,
  process/solver boundaries and before state/output/checkpoint commitment. Check operands and
  results, individual residual/Jacobian components, scales, tolerances, fluxes and accumulated
  sums. Finite operands can overflow. Validate before norms, min/max or comparisons; a test
  only of `abs(residual) > tolerance` does not safely reject NaN. The accepting branch must
  require finite, valid quantities and every physical gate.
- Guard zero/invalid volumes, masses, timestep and denominators; log/sqrt/power domains;
  exponential/product overflow; and uninitialized, stale, aliased or out-of-range state. A dry
  or absent phase needs its derived inactive/limiting equation, not an invented epsilon supply.
  Prefer stable equivalent algebra and constraint-aware steps. Investigate underflow when it
  erases scientifically active trace chemistry; no arbitrary caps or flush-to-zero policy.
- Invalid input or committed state stops the run immediately with context. An invalid private
  Newton/line-search probe may be rejected and recovered within the existing finite budget
  from the last valid state; its numbers must never enter history, coupled state or ledgers.
  On unrecoverable domain/nonfinite/admissibility failure, propagate an explicit error to a
  nonzero simulation exit, restore the transaction and preserve the last valid checkpoint.
  Preserve offending operands in a clearly invalid diagnostic artifact. No catch-and-continue,
  warning-only success, NaN-to-zero, stale-value substitution or best-iterate publication.
- Conservation and finiteness are necessary but insufficient. Validate nonnegative physical
  inventories, joint donor limits, applicable capacities and constitutive domains at each
  accepted internal step and external hour. Check rapid changes against independently derived
  transfer/rate/supply/energy limits, boundary forcing and management events in native units.
  A phosphorus inventory of `-1e5` fails positivity even if another pool offsets it. A soil-heat
  value/change of `1e6` is not a universal failure threshold: establish units, volume/area,
  reference enthalpy, sensible/latent terms, implied temperature and available energy first.
  Signed fluxes, potentials and reference energies need their own domains, not mass positivity.
- Capture first/worst excursions and neighboring hours. A one-hour spike and next-hour reversal
  must each satisfy physical equations, admissibility and independent ledgers. Daily/yearly net
  closure, smoothing, rebasing or later repayment cannot excuse an invalid hour. Investigate
  unit/timestep errors, duplicate transfers, lag/reset bugs, cancellation and unstable updates;
  accept a large real event only with its causal physical explanation. Trace an unexplained
  excursion before qualification instead of inventing a universal magnitude/rate cutoff.
- These checks must execute in production ReleaseFast as well as safety builds. Use explicit
  error paths, not debug assertions or assumed floating-point traps. Keep strict floating-point
  semantics where detection depends on IEEE NaN/Inf behavior; audit compiler/backend options
  and inherited float modes. Prove detection with runtime-supplied fault injections under the
  pinned Zig toolchain; optimized-float assumptions must not invalidate guards.

Keep cheap boundary checks in normal execution; enable targeted operation traces on the smallest
reproducer. Do not scan every full array at every scalar probe or dump every iteration. Speed
comes from early detection and causal repair, never from bypassing a required check. A legacy
nonfinite/impossible output remains recorded as invalid oracle evidence; justify the modern
correction with independent physics and a registered deviation, without deleting bad rows.

## Resolve benign cases quickly; bound unsuccessful work

Check exact/no-op cases and all acceptance gates before expensive Jacobian work and after
each accepted trial, including the final allowed iteration. Finish immediately when the
equations, physical bounds and independent ledgers all pass; an advisory search score or a
scheduled retry must not veto a fully validated endpoint. Recompute the undamped equation
residual: a tiny line-search fraction or tiny update is not evidence of equilibrium.

At an empty pool, allow replenishment and forbid withdrawal beyond available supply. Use
constraint-aware Newton steps and reaction extents, not a positive epsilon inserted as matter.
Bound each nonlinear attempt, line search, nested recovery and the total work for the fixed
external hour. Count residual/Jacobian evaluations as well as iterations. A local iteration cap
alone cannot bound a recursively restarted solver. These are numerical-work bounds, not wall-time
deadlines; healthy long jobs retain the protocol's no-elapsed-limit protection.

Select the least costly remedy supported by the diagnosis: conserved formulation or corrected
coupling; scaling/Jacobian repair; feasible Newton and Anderson; branch treatment; bounded
internal substeps preserving the external hour. Do not blindly run every fallback. A temporary
legacy-faithful explicit subcycle path is S9 debt requiring registered attribution and retirement
or scientific equivalence, never a silent replacement for Newton/Anderson.

Stop stalled work early after the applicable bounded recovery, with a reusable diagnostic state.
Distinguish `solver nonconvergence`, `unresolved arithmetic precision`, `conservation defect`
and `inadmissible state` in the report; these are diagnoses, not new PASS statuses. Restore all
trial pools/fluxes/counters/clocks/outputs on failure. Never publish the best failed iterate.
Demonstrate a finite work bound and fewer wasted evaluations on the repaired edge case; this
is correctness recovery, not permission to start campaign speed optimization before F1–F5.

## Prove the repair before another campaign

Choose affected cases, not a new blanket suite for every edit: exact zero/no input; zero with
incoming supply; positive trace pools; both sides of each relevant floor; near cancellation;
both signs of an injected unmatched transfer; equal/opposite local defects hidden globally;
shared-consumer exhaustion; phase/active-bound switching; unit, area and population rescaling;
accumulated bias across many accepted steps; capped recovery and complete rollback/restart.
Where affected, inject NaN and both infinities through input, restart, arithmetic and solver
components, including a component hidden by a norm/min/max; overflow from finite operands;
invalid domains; a finite negative pool despite global closure; and a spike/reversal pair that
passes a two-hour net check but violates an hourly physical bound. Add a legitimate large
forcing/event case so magnitude alone cannot cause a false error. Verify immediate detection,
bounded private-probe recovery where valid, fatal nonzero exit otherwise, and no contaminated
accepted state/output/checkpoint or lost last-valid checkpoint in production as well as Debug.
Benign cases must finish promptly without false errors; defects above the frozen allowances
must fail. Preserve small positive inventories and verify equal/opposite transfers. Include
residual-evaluation counts and deterministic bounds justified by the fixture, not timing alone.

Run minimal regression → independent coupling/balance → relevant event → required suites
in Debug/ReleaseSafe and production ReleaseFast. Compare physics/output impact and independently
derive the decisive numbers for G7. Do not alter tolerances or expected outputs after seeing a
failure to make it pass. Record any intentional difference and invalidate dependent evidence.

Source anchors (recheck against the candidate): `core/numerics.zig:convergenceTolerance`,
`soil/solute/reaction_solve.zig:initializeSearchReferences`,
`soil/solute/reaction_physical_quality.zig:relativeChange`,
`validation/scoped_conservation.zig:evaluate`, `validation/mass_balance_audit.zig` and DEV-010.
These are implementation leads, not certification. Legacy anchors: `exec.f:35-92`,
`starts.f:93-94,269-270`, `grosub.f:10914-10916`, `solute.f:131,372-396`, `starte.f:100`.
[KINSOL scaling, constraints and stopping criteria](https://sundials.readthedocs.io/en/v7.5.0/kinsol/Mathematics_link.html)
distinguish a small residual from a stalled small step; scientific acceptance remains project-specific.
The [Zig 0.17 float-mode reference](https://ziglang.org/documentation/0.17.0/#setFloatMode)
describes optimized-mode assumptions about NaN/Inf; verify actual build settings and guard behavior.
