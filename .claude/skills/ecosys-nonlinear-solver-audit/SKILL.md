---
name: ecosys-nonlinear-solver-audit
description: "Audit Newton/Anderson residuals, bounds and transactional acceptance; use for stiff, oscillatory or rejected hours."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Follow `.agent/playbooks/convergence-and-balance.md`: translation/binding/floor defects first.
State unknowns/units, residual scaling, old/trial/committed states and exact acceptance rules.
Check directional finite-difference Jacobians away from kinks and branch boundaries separately.
Inspect line search, Anderson rank/history/restarts, bounded total internal work and complete
rollback. Stagnation/small steps are not convergence. Preserve the fixed external hour.
Validate adopted freeze-thaw/hydraulic variants, finite/domain bounds and independent ledgers.
Use failing-state/event fixtures; record residual/iteration/retry behavior and a separate derivation.
Never add unlimited subdivisions, vanilla Picard, post-solve clamps or best-bounded publication.
