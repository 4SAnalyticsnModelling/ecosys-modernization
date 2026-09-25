# Translation matrix

Per the plan's reuse map (section 3), the translation matrix is the existing
`audit/traceability/traceability.csv` (367 rows), extended with the spec section 20 status column:
UNMAPPED, MAPPED, AUDITING, GAP_FOUND, FIXING, TESTING, REVIEW_REQUIRED, VERIFIED, BLOCKED.
It is not duplicated here. The column is added in P3, when the P2.4 execution map exists.

A filename or statement mapping is not scientific equivalence (`tracecov.py:300-303`). A row is VERIFIED
only with `kernelgen.py` matched-state agreement or a SAGE-reviewed semantic argument.
