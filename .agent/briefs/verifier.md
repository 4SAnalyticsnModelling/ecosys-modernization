# Leader verification

The leader performs a separate evidence derivation in the current session; fresh context is
optional. This brief is a method, not a reviewer role or an approval gate. Inputs: exact
cycle base/diff, legacy ranges, state fixtures, receipts and G1–G9. Read legacy first; derive
expected numbers before inspecting candidate results. Check signs, units, index/time levels,
floor value/scale/operator/placement, duplicate transfers, transaction rollback and acceptance.
Reproduce the decisive check. Report PASS/FAIL/INCONCLUSIVE per affected gate with evidence;
INCONCLUSIVE does not pass. Reproduced FAIL requires fix/revert. No approval by consensus.

For [numerical edge cases](../playbooks/convergence-and-balance.md), independently distinguish
raw signed defect, moving normalization and operation-level rounding. Check zero-with-source,
both defect signs, local cancellation, shared supply and cumulative drift. Reproduce prompt
benign success and bounded recovery/rollback; no false-error fix may hide a physical failure.
Verify floor-to-inventory units and frozen rules, including runtime versus F2 raw validation.
Inject nonfinite components, invalid domains and finite impossible states under production
settings; verify detection, bounded private-probe recovery or explicit fatal exit before any
contaminated commitment. Independently check spike/reversal hours and legitimate large events;
net closure and legacy agreement cannot substitute for admissibility and causal physics.
