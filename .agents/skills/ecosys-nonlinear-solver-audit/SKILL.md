---
name: ecosys-nonlinear-solver-audit
description: "Audit Newton-Raphson, Anderson fallback, bounds, residuals, rollback and freeze-thaw/Richards integration. Use for nonconvergence, oscillation, retry loops, slow hours or physical acceptance failures."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Bounded solves with physically accepted states

Read the existing solver implementation, callers and recorded design decisions before proposing changes. Preserve the established fixed one-hour external step, Newton primary and Anderson-accelerated fallback. Do not add vanilla Picard, silent external timestep changes or unlimited fallback/subdivision cascades.

## Formulation
Write the exact unknown vector, units, residual equations/scaling, boundary conditions, old/current/trial state definitions and update order. Confirm Jacobian entries or Jacobian-vector products correspond to those residuals, including derivatives through constitutive laws, phase changes and coupled fluxes. Check signs, layer ordering, zero pivots, conditioning and linear-solve error handling. Use directional finite-difference checks away from nondifferentiable boundaries with scale-aware perturbations; separately test branch transitions.

Inspect convergence norms, dimensional scales, relative/absolute criteria and maximum iterations. A tiny step caused by clipping, line-search failure or ill conditioning is not proof of residual convergence. Physical bounds and independent conservation must pass together with the solver criterion. Log the reason for acceptance or rejection.

## Damping, fallback and transactionality
Verify bounded line search/trust strategy as implemented. Detect stagnation, divergence, repeated clamping and two-cycle/oscillatory patterns early; stop a futile attempt and invoke only the approved bounded fallback. For Anderson, inspect history depth/storage, restart conditions, regularization/rank-deficient history, finite coefficients and candidate acceptance. Do not reuse poisoned histories across incompatible regimes.

Snapshot the complete accepted state before a trial. A rejection restores physical pools, pending flux exchanges, source integrals, event counters, cumulative output and clocks. No half-accepted process may persist. Bound total work for one external hour across all nested attempts, not just each inner loop. On exhaustion, terminate with a controlled diagnostic and preserve the last valid checkpoint when available.

## Physical feature checks
For Dall'Amico freeze-thaw, verify the exact adopted formulation, phase-equilibrium relation, latent energy accounting, continuity/branch handling and admissible liquid/ice partition. For Mualem-van Genuchten, verify parameter constraints/units, pressure-head conventions, retention/conductivity endpoints, derivative handling and saturation/residual limits. These are tests of the implemented variants, not permission to change formulas from memory. Cross-reference `ecosys-feature-attribution`.

## Evidence and done
Record per-hour iteration counts, fallback counts, residual histories, rejected trials and CPU cost distributions, especially worst hours. Run small adversarial states and known failing-hour replays before returning to the production deck. Closure requires bounded work, correct rollback, verified residual/Jacobian behavior and physically accepted results; raising iteration limits until a run finishes is not a fix.
