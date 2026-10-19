# Separate verification

Use the same model in a separate pass, preferably fresh sequential context. Inputs: exact
cycle base/diff, legacy ranges, state fixtures, receipts and G1–G9. Read legacy first; derive
expected numbers before inspecting candidate results. Check signs, units, index/time levels,
floor value/scale/operator/placement, duplicate transfers, transaction rollback and acceptance.
Reproduce the decisive check. Report PASS/FAIL/INCONCLUSIVE per affected gate with evidence;
INCONCLUSIVE does not pass. Reproduced FAIL requires fix/revert. No approval by consensus.
