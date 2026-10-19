---
name: ecosys-conservation-audit
description: "Independently verify local/global mass and energy budgets; use for balance failures and physical acceptance."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Inventory actual pools, species and external fluxes. Assemble storage change minus integrated
net sources independently of solver residual code. Check units, signs, area/density/timestep,
reaction stoichiometry, internal cancellation, heat reference and phase latent/sensible terms.
Check kernel/layer/cell/domain and hour/day/year/full-run drift; preserve worst location and
scale. Use approved quantity-specific tolerances, never widen them to hide a failure.
Exercise closed systems, known source/sink, interface transfer and rejected-trial rollback;
isolated omitted/sign/double-transfer fixtures must fail. Record each accepted hour's ledger.
Reject nonfinite/unclosed states; publish no clipped or renormalized success.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
