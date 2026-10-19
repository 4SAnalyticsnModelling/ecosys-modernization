# Qualification evidence contracts

Authority: [protocol](../.agent/protocol.md). These are machine-checkable evidence contracts;
passing them does not replace separate scientific derivation or inspection of raw artifacts.
Commands below run through `./scripts/project.sh`. Historical receipts remain readable;
missing new fields require revalidation, never automatic conversion to PASS.

## Stages and verdicts

BASELINE → SOURCE → ENTRY → CAMPAIGN → RELEASE. Requirements live in
`ecosys-audit/gate_requirements.json`. `check_gate.py` accepts historical aliases
`source-audit` → SOURCE, `production-entry` → ENTRY, `release` → RELEASE.
Cycle results: PASS | FAIL | NA | INCONCLUSIVE. INCONCLUSIVE keeps the cycle open;
NA needs a scope reason and cannot replace a required scientific PASS.

## Dependencies and reuse

`dependencies.py --out .tmp/dependencies.json` captures actual source, reference inputs,
acceptance registers/rules, validators/tests, build configuration and compiler binary hashes.
Documentation-only commits outside these dependencies do not invalidate evidence.
Record effective build options, target and fixture hashes with `--context '<JSON object>'`.
Custom/staged inputs outside the default reference roots must be listed using `--scope`.
Narrow capture needs `--scope <path>` for every scientific dependency and `--justification`;
validators, acceptance rules and toolchain identity are always included. A manifest establishes
identity, not the completeness of a manually narrowed dependency set; G7 reviews that choice.
Cycle `set --dependencies <JSON>` accepts `{scope, justification, context}`; omit scope for
conservative capture. Recording a verdict captures dependencies; closure rechecks them.

## Prerequisites and inventories

`readiness.py --output-inventory <reviewed-F3-inventory.json>` checks complete field coverage,
the binding register and established rules. Empty registers remain blockers. Populate them
from source during the current investigation, then extend process by process. Do not fabricate
rows during tooling maintenance. All CSV `evidence` cells contain a JSON array of `{path,sha256}`.
Output rows use `status=VERIFIED`, complete producer/units/time/conversion fields and a
`comparison_rule` key into the rule table. Binding rows describe origins, shape/lower bounds,
units, time level, initialization, reset and checkpoint ownership; write explicit `none` where
appropriate, with evidence. Blank required cells do not establish completeness.

Rule tables use `status=ESTABLISHED`, an evidence-based `decision`, nonempty hashed `evidence`,
and per-variable `{abs,rel,rationale}` entries with finite nonnegative tolerances. Rules must
be established before qualification comparisons. DRAFT/exact defaults remain diagnostic only.
Replacement physics also needs predeclared envelopes and held-out benchmarks, beyond legacy
agreement and conservation. This maintenance establishes no scientific acceptance thresholds.

## Finish schema

`finish.json` uses `schema_version=2`; retain existing F1/F7 fields and checks. Each F2–F6
check adds `report: {path,sha256}`, also present in its `evidence`. Each report contains:

```text
schema_version: 1
criterion: F2 | F3 | F4 | F5 | F6
source_digest, binding_id: identical to the integrated candidate
status: PASS
unresolved: []
verification_method: separate-derivation | fresh-context-same-model
dependencies: complete dependencies.py object
evidence: nonempty [{path,sha256}, ...]
inventory: {path,sha256}
results: [{id, status: PASS, evidence: [{path,sha256}, ...], ...}, ...]
```

The referenced inventory has `schema_version=1`, the same `criterion`, `scope_complete=true`,
`verification_method`, nonempty hashed `evidence` supporting completeness, and nonempty `items`
with unique `id` values. Results must cover exactly those IDs, without duplicates. Build the
inventory independently from the candidate result set; source scope includes dormant units,
output scope comes from the complete legacy inventory. Hashes and coverage assertions alone
are not scientific proof. Inventory completeness and reported measurements require G7 review.

| Criterion | Inventory item fields | Required result fields/checks |
|---|---|---|
| F2 | `quantity,level,location,units,rule` | Water/heat/C/N/P at local and global levels, plus active species/salts; each location has `first_hour=1,last_hour=262920,hours_checked=262920,independent_assembly=true`; `missing_hours,duplicate_hours,nonfinite,breaches` all integer zero |
| F3 | `file,column,units,time_basis,rule,expected_rows,terminal_key` | `rows_compared=expected_rows`, matching `terminal_key`; `missing,extra,duplicates,nonfinite,outside_rule` all zero; dictionary and rules pass readiness |
| F4 | `source,source_sha256,direction,dormant` | Include `legacy-to-zig,zig-to-legacy,state-binding` directions and dormant scope; current source hash; `semantics_reviewed=true`, `derivation`, `test_or_dormant_reason`; disposition `equivalent`, `justified-deviation` or `dormant-reviewed` |
| F5 | ID from every DEV register row; `replacement_physics` boolean | Disposition `retired`, `equivalent` or `merged`; nonempty `mechanism,measured_impact,decision`; retained replacements require `predeclared_envelope=true,held_out_benchmarks=true` |
| F6 | Every ID in `qualification_reports.F6_CASES`, plus any additional required cases | Verified build receipts, assessed suites, full-state restart/reproducibility, production safety and equivalent-work measurements |

F6 build results use `build_receipt: {path,sha256}` with matching mode/source, exit zero and
unchanged source during build; the preserved product hash must still match. Suite results use
`suite_result: {path,sha256}` and must pass `suite_check.py assess`. Restart/reproducibility
results require positive `fields_checked`, `full_state=true`, and zero
`mismatches,missing_fields,nonfinite`. Corrupt/truncated restart additionally requires
`corrupt_rejected,truncated_rejected,atomic_rejection=true`. ReleaseFast safety requires
`bounds_checked,rollback_checked,allocation_failure_checked=true`. Performance requires at
least three `repeats`, `equivalent_work=true`, and a `measurements` array of that length with
finite positive `wall_seconds,cpu_seconds,peak_rss_bytes,accepted_hours` per run. Accepted-hour
counts must match across repeats; supporting artifacts establish output/check equivalence. G7 examines
the actual metrics and scientific equivalence, not only these structural prerequisites.

## Suite accounting

`ecosys-audit/suite_manifest.json` declares exact roots, modes, argv and parsers.
`suite_check.py run --case tooling --out audit/runs/<unique-id>` records JUnit counts.
Future science workers run `tests-module-Debug`, `tests-executable-Debug` and the corresponding
ReleaseSafe/ReleaseFast cases. New `zig build test-module` and `test-executable` steps expose
each existing root separately; `zig build test` still runs both. `--summary all` supplies raw
Zig counts; cached/missing/unparseable counts remain unassessed. Filtered tests are diagnostic
and cannot certify a full suite. Exact skip counts need a reason and hashed evidence in the
manifest's `skip_allowance`. Zero tests, process failures, missing modes and unexplained skips
cannot pass. `cycle_runner.py gates --build` runs all three builds and six Zig suite cases;
`--tests` runs tooling. Generic `exec` receipts never imply test acceptance.

## Recovery and hypotheses

Pickup reports `alive`, `dead` or `unknown`, with artifact candidates and reconciliation steps.
Missing identity is unknown; process death establishes no scientific result. No RUNNING
receipt permits automatic retry. Qualified frontier, historical run progress and diagnostic
target retain separate provenance; pickup changes no ledger or receipt.

Failure packets schema 2 retain rejection records with binding, captured-state artifact,
dependency manifest, falsifier and evidence. Use `--state-values` and `--falsifier` when adding
`--rejected`. Only records whose identities and evidence still match populate the active
`rejected_hypotheses` list. Legacy/incomplete records remain historical leads, and changed
inputs, source, rules, validators or fixture reopen the hypothesis for consideration.

## Maintenance checks

`doc_consistency.py` checks the active document list, links, stage vocabulary, obsolete approval
language and skill alias drift. Historical review records are excluded. After skill edits use
`skill_sync.py --apply`. Validate changed behavior with synthetic fixtures and the active tooling
suite; workflow maintenance does not launch the Ottawa worker or advance qualification.
