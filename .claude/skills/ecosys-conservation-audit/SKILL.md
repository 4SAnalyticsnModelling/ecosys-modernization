---
name: ecosys-conservation-audit
description: "Verify local/global/cumulative conservation and both signs of near-zero balance defects; distinguish rounding, missing transfers and negative pools."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One leader decides and verifies;
optional safe sub-agents follow the protocol. No adversarial reviewers or reviewer approval gates.

Use [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md) for signed
outstanding balances, negative pools and near-zero failures. Define `R=(new-old)-sources+sinks`;
positive surplus and negative deficit receive symmetric evidence-based checks. A signed residual
does not imply a negative pool. Never rebase, invent balancing fluxes/reserves or clip state.

Inventory actual pools, species and external fluxes. Assemble storage change minus integrated
net sources independently of solver residual code. Check units, signs, area/density/timestep,
reaction stoichiometry, internal cancellation, heat reference and phase latent/sensible terms.
Check kernel/layer/cell/domain and hour/day/year/full-run drift; preserve worst location and
scale. Use approved quantity-specific tolerances, never widen them to hide a failure.
Separate interval-activity scaling and operation-derived rounding from scientific allowances;
verify concentration/amount/area conversions and runtime/F2 rule agreement. Preserve raw signed
defects, absolute local defects and corrections across substeps/restarts; cumulative drift must
pass its own frozen budget. Fix shared debit/credit and consumer competition conservatively.
Exercise closed systems, known source/sink, interface transfer and rejected-trial rollback;
isolated omitted/sign/double-transfer fixtures must fail. Record each accepted hour's ledger.
Reject nonfinite/unclosed states; publish no clipped or renormalized success.
Benign zero/trace and proved rounding cases must complete promptly through all established
gates; insufficient arithmetic resolution requires reformulation, not an inflated allowance.
Finiteness and closure cannot legalize a negative pool or impossible transfer/heat state.
Check local supply/capacity/energy domains each accepted internal step and hour; a spike and
next-hour reversal cannot cancel the earlier failure. Explain large values through units,
reference enthalpy and forcing; no arbitrary numeric caps. Reject nonfinite components before
summing or comparing, and verify fatal rejection leaves no contaminated output/checkpoint.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
