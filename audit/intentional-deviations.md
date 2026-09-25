# Intentional deviations from legacy ecosys

Every Zig behaviour that differs from legacy on purpose (decision D2, plan section 1) or by adjudicated
input change (D6). An entry is ACCEPTED only when SAGE has approved the attribution evidence and
the user has signed it. Unlisted differences are defects until shown otherwise.

| ID | Deviation | Legacy reference | Zig location | Reason | A/B attribution evidence | Affected outputs | SAGE | User | Status |
|---|---|---|---|---|---|---|---|---|---|
| DEV-001 | Newton-Raphson / Anderson soil-water solver | | | D2 | pending (P5, `ecosys-feature-attribution`) | | | | PROPOSED |
| DEV-002 | Dall'Amico freeze-thaw | | | D2 | pending | | | | PROPOSED |
| DEV-003 | Mualem-van Genuchten hydraulics | | | D2 | pending | | | | PROPOSED |
| DEV-004 | Deck runtime ceiling 100->200 (`9253d3b`) | | deck | D6 | pending P0.2 | | | | UNDER_ADJUDICATION |
| DEV-005 | Deck `starte.f:189` edit (`5add7de`) | `starte.f:189` | deck | D6 | pending P0.2 | | | | UNDER_ADJUDICATION |
| DEV-006 | Zig solute iteration ceiling 60->200 (issue-015) | | | D6 | pending P0.2 | | | | UNDER_ADJUDICATION |
