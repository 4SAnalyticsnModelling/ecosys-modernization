# Qualification comparisons

Authority: `.agent/protocol.md`. Definitions and commands:
[qualification evidence](../ecosys-audit/qualification-evidence.md).

| Directory | Content |
|---|---|
| `rules/` | Per-variable rules established from evidence before qualification comparisons |
| `reference/`, `zig/` | Hash-bound pointers to complete oracle/candidate outputs |
| `comparisons/` | Every file/column/key compared with verified units and time support |
| `balances/` | Independent local/global water, heat, C, N, P and active-salt reports |
| `events/`, `reports/` | Event/seasonal/annual comparisons and final qualification evidence |

Output semantics come from `audit/output-provenance.csv`; state ownership comes from
`audit/traceability/bindings.csv`. Empty registers, DRAFT rules and missing comparison coverage
remain blockers. The autonomous model establishes justified rules and records separate verification;
no human or retired-role approval is required. Never widen rules to encompass a failed candidate.

Near-zero and signed-defect rules follow [numerical recovery](../.agent/playbooks/convergence-and-balance.md).
Specify units, scale recipe, carrier conversion, scientific allowances and separately derived
arithmetic uncertainty. Preserve both residual signs and cumulative/absolute local defects;
near-zero percentages alone are not a pass/fail rule. Test benign prompt success and injected
physical failure. Reconcile runtime and raw F2 criteria before qualification. Documentation
does not establish numeric tolerances; leave DRAFT rule tables unestablished until evidenced.
Finite/domain guards must survive production builds and reject invalid components before norms
or comparisons. Test explicit fatal rejection/clean rollback as well as valid bounded recovery.
Assess each interval's physical bounds: a negative pool or invalid spike is not cured by global
closure or next-hour reversal. Explain legitimate large events from units/forcing; preserve and
attribute broken legacy oracle data rather than adopting it as a target or deleting its rows.
