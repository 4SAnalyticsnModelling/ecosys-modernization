---
name: ecosys-nonlinear-solver-audit
description: "Diagnose near-zero scaling, Newton/Anderson stalls and bounds; validate prompt conservative recovery without false errors."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Follow [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md): translation,
binding and floor defects first. Use a captured minimal state; distinguish raw equation error,
normalization, arithmetic uncertainty, physical bounds and independent balance failure.
State unknowns/units, fixed entry/source/family references, per-row absolute-plus-relative
allowances, old/trial/committed states and exact acceptance rules. Preserve small valid pools.
Check directional finite-difference Jacobians away from kinks and branch boundaries separately.
Inspect line search, Anderson rank/history/restarts, bounded total internal work and complete
rollback. Stagnation/small steps are not convergence. Preserve the fixed external hour.
Prove exact no-op and zero-with-incoming-source behavior. Recompute undamped residuals and
finish promptly once all required gates pass; no advisory search score may force useless work.
Measure residual/Jacobian evaluations across nested recovery, not just outer iterations.
Fix cancellation, scaling or branch/Jacobian defects on the fixture before replaying an hour.
No science pass follows merely from a residual below an unvalidated arithmetic estimate.
Validate adopted freeze-thaw/hydraulic variants, finite/domain bounds and independent ledgers.
Use failing-state/event fixtures; record residual/iteration/retry behavior and a separate derivation.
Never add unlimited subdivisions, vanilla Picard, post-solve clamps or best-bounded publication.
Validate individual finite residual/Jacobian/scale/merit components before reductions or
acceptance; NaN can evade a comparison. Reject invalid private probes without contaminating
history, then recover within budget or propagate a fatal contextual error. Prove these paths
under production settings; no invalid or unexplained physical spike may become committed state.
