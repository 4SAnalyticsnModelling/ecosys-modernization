# Intentional deviations from legacy ecosys

Every Zig behaviour that differs from legacy on purpose (decision D2, plan section 1) or by adjudicated
input change (D6). An entry is ACCEPTED only when SAGE has approved the attribution evidence and
the user has signed it. Unlisted differences are defects until shown otherwise.

| ID | Deviation | Legacy reference | Zig location | Reason | A/B attribution evidence | Affected outputs | SAGE | User | Status |
|---|---|---|---|---|---|---|---|---|---|
| DEV-001 | Newton-Raphson / Anderson soil-water solver | | | D2 | pending (P5, `ecosys-feature-attribution`) | | | | PROPOSED |
| DEV-002 | Dall'Amico freeze-thaw | | | D2 | pending | | | | PROPOSED |
| DEV-003 | Mualem-van Genuchten hydraulics | | | D2 | pending | | | | PROPOSED |
| DEV-004 | SOLUTE iteration budget 100->200, one deviation: deck runtime ceiling 100->200 plus Zig solute ceiling 60->100->200 (both in `9253d3b`; absorbs DEV-006) | none: Zig-only hard_max_iterations; legacy MRXN solute.f:111=60, starte.f:101=1000 | deck runtime f6 -> iteration_control.zig:139-153 (`:150` solute, `:151` initial solute) | D6 | pending P0.2; n100e/n100f first `f25wh1` divergence hour 9 (T-00027/T-00029); first changed state not yet identified | | REJECT as legacy-equivalent (T-00030); merged dossier required | merge of DEV-004+DEV-006 decided 2026-09-25 (scope only, not a signature) | UNDER_ADJUDICATION |
| DEV-005 | Deck `starte.f:189` edit (`5add7de`) | `starte.f:189` | deck | D6 | pending P0.2 | | | | UNDER_ADJUDICATION |
| DEV-006 | Zig solute iteration ceiling 60->200 (issue-015) | see DEV-004 | see DEV-004 | D6 | see DEV-004 | | see DEV-004 | merged into DEV-004 2026-09-25 | MERGED -> DEV-004 |
