# Qualification evidence contracts

Authority: [protocol](../.agent/protocol.md). These are machine-checkable evidence contracts;
passing them does not replace separate scientific derivation or inspection of raw artifacts.
Commands below run through `./scripts/project.sh`. Historical receipts remain readable;
missing new fields require revalidation, never automatic conversion to PASS.

One leader performs and records evidence re-derivation; no adversarial reviewer or second
actor is required. Independent conservation/benchmarks mean independent mathematical terms,
data or experiments, not reviewer independence. `author` records the accountable worker;
`verification_method=separate-derivation` is valid in its current session. Fresh context is
optional. RELEASE uses `leader-release-verification`, completed by that same leader.
Normalized CSV schemas record the leader's frozen tolerance decision in `decision_owner`;
historical `approved_by` is accepted as a field alias, not an external approval requirement.
Historical role labels never waive scientific checks or create a wait-for-review prerequisite.

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
and per-variable `{abs,rel,rationale,metrics}` entries with finite nonnegative tolerances. Rules must
be established before qualification comparisons. DRAFT/exact defaults remain diagnostic only.
Replacement physics also needs predeclared envelopes and held-out benchmarks, beyond legacy
agreement and conservation. This maintenance establishes no scientific acceptance thresholds.

## Near-zero, signed-defect and finite-state rules

The [numerical recovery playbook](../.agent/playbooks/convergence-and-balance.md) governs
scientific interpretation. For an affected rule, retain a compact hashed derivation with its
residual definition/sign, native units, exact reference-scale recipe, carrier volume/mass/area
conversion, absolute/relative allowance, arithmetic uncertainty and cumulative budget. Separate
process activation/floors, numerical search and final physical acceptance. No concentration ZERO
literal automatically establishes a mass or area-normalized allowance. Existing DEV labels
require current attribution; changing search scales must not silently change acceptance.

Retain both residual signs, absolute local defects, worst locations and any numerical corrections
through substeps, scene transitions and restart. Bounded roundoff is not an unmodeled source or
sink. Independent local/global/cumulative ledgers and pool bounds must pass; legacy rebase or
completion cannot discharge an outstanding defect. Include prompt benign zero/trace completion,
incoming supply to an empty pool, cancellation, shared-consumer limits, injected defects of both
signs, capped recovery and rollback in the affected evidence. Count evaluations as well as iterations.

Require explicit finite/domain checks before reductions/comparisons and state/output/checkpoint
commitment in production. Evidence includes runtime-injected NaN/both infinities, finite-input
overflow and invalid domains; bounded rejection/recovery of private solver probes or fatal
nonzero simulation exit; and unchanged last-valid state/checkpoint on failure. Guards must not
depend on debug assertions or compiler assumptions that exclude the tested nonfinite values.
Also test finite impossible pools and spike/reversal pairs against each interval's local
supply/capacity/energy/constitutive bounds, even when global or two-hour ledgers close. Establish
units, enthalpy reference and forcing before judging a large heat value; include a valid large
event to discriminate from an arbitrary cap. Next-hour repayment never validates a bad hour.
Preserve invalid legacy rows and coverage, and attribute Zig repairs with independent physics
and registered deviations. Required comparisons remain assessed; invalid oracle data is not a
license for silent exclusions or invented passing comparisons.

These are scientific review requirements, not newly implemented JSON fields or validators.
Put extra diagnostics in referenced artifacts; do not invent schema support or claim docs enforce
runtime behavior. The F2 raw schema below currently uses old/new storage in its relative scale;
runtime process checks can use interval activity. Compare the actual rules and require both to
pass; reconcile inconsistent sensitivity in a separately tested science/validator change before
qualification. Never drop the stricter check or silently adjust either rule to fit the candidate.

### Invalid legacy reference

The current F3 implementation (`raw_evidence.py:outputs`, `qualification_reports.py:validate`)
requires finite values from both streams and passing direct comparison rules for every row.
It has no invalid-reference disposition. A DEV or independent scientific result alone therefore
cannot make an affected F3 report pass. Do not keep rerunning the same rejected comparison.

If a defect is reproduced in the actual reference, preserve its original raw data, prove its
cause and bound the affected fields/times, including downstream effects. First fix an adapter,
unit or binding error if that is the cause. For a genuine reference-model defect, the next
prerequisite is a separately tested, versioned evidence-contract/validator extension for explicit
reference-defect resolution. It must retain every original key/value and defect provenance,
require independent physical validation of the finite/admissible Zig trajectory against
predeclared criteria, and preserve ordinary comparison rules wherever the reference remains
valid. Test rejection of fabricated defects, missing coverage, unproven resolution and any
invalid Zig result. Establish the scientific criteria before qualification evaluation; no
NaN-to-number conversion, dropped rows, tolerance widening or fabricated direct comparison.

This is a worker task specification, not implemented schema support or a waiver. Keep F3
unqualified until that prerequisite and its scientific evidence pass. Continue verified local
repairs and unblocked prerequisites meanwhile; complete coverage is required for release, not
a reason to defer every focused defect repair. No change to protected legacy sources is allowed.

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
with unique `id` values. Results must cover exactly those IDs, without duplicates. Regenerate the
inventory independently from the candidate result set; source scope includes dormant units,
output scope comes from the complete legacy inventory. Hashes and coverage assertions alone
are not scientific proof. F4 regenerates its source denominator and F2/F3 reread raw data; adapter completeness and
scientific interpretation still require the leader's G7 evidence re-derivation.

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
counts must match across repeats; the additional paired benchmark below enforces the full-run
speed requirement after scientific acceptance. G7 examines
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

`doc_consistency.py` discovers tracked and newly added project documents, checks active reviewer
prerequisites, requires retirement notices on historical dossiers, and checks machine-readable
leader/reviewer policy. It also checks links, stage vocabulary, obsolete approval
language and skill alias drift. Historical review records are excluded. After skill edits use
`skill_sync.py --apply`. Validate changed behavior with synthetic fixtures and the active tooling
suite; workflow maintenance does not launch the Ottawa worker or advance qualification.
This checker does not detect semantic contradictions or prove termination. Separately review
rule precedence, search-versus-commit scope, simulator-versus-worker failure, current validator
capabilities and an actionable next step for every blocked prerequisite.

## Scientific acceptance before performance

F1–F5 must pass before runtime optimization. F6 validates their current hash-bound reports
again through `benchmark.scientific_acceptance`, including a complete strict campaign summary.
Every speed change must preserve/re-establish science, translation, binding and full-output
acceptance for the final source/binding. An incomplete or inaccurate fast run has no release value.
Timing before F1–F5 is limited to diagnosing a blocked correctness run, not optimizing runtime.

## Regenerated scope and raw verification

`source_inventory.py --out <new-path>` emits an UNREVIEWED F4 denominator from fixed-form
logical statements, dormant-code blocks, every COMMON member declaration and every nonblank
Zig source/build line. It also covers out-of-build legacy sources and C helpers. Its `items`
are the exact F4 inventory items before separate review; retain IDs, hashes and line ranges.
Final validation regenerates the set and refuses omissions even if both inventory and results
omit the same item. This conservative textual denominator is not semantic equivalence proof;
review aliasing, control flow, dormant branches, producer/consumer bindings and equations.
Review coherent functions/ranges once and generate their per-ID result rows mechanically,
sharing the derivation/test evidence; do not hand-author hundreds of thousands of duplicate rows.

F2/F3 reports add `raw_evidence: {path,sha256}`. That JSON contains `source_digest,binding_id`,
`policy` (hashed established rule table), `policy_commit` (ancestor commit storing exactly those
rule bytes) and nonempty `evaluation_receipts` (hashed successful run receipts). The policy
commit must precede every evaluation start. Freeze definitions before looking at qualification
results; never adjust envelopes to turn an observed failure into a pass. Retain the old failure.
Timestamps and Git ancestry establish recorded ordering, not scientific justification.

F2 results also contain a hashed `ledger` JSONL stream. Each row has
`hour,quantity,level,location,units,old,new,sources,sinks`. Sources/sinks are independently
assembled integrated amounts for the accepted hour in declared units, not rates or solver
residuals. The validator recomputes `(new-old)-sum(sources)+sum(sinks)`, checks storage continuity,
finite values, exact hours 1–262920 and the frozen `abs+rel*scale` rule, where scale is the maximum
of old/new storage magnitude and total absolute transfer. Explicitly inventory every active
local location/species and global quantity from the decoded state/deck; internal transfers
cancel globally. G7 verifies this spatial/species denominator and independent term assembly.

F3 raw evidence additionally has `adapter`, `legacy_directory`, `zig_directory`, and `pairs`.
The adapter is a hashed Python file under `ecosys-audit/adapters/` implementing
`rows(path,role)` for `role=legacy|zig`. Each pair contains `file` (dictionary name), `legacy`
and `zig` artifact references. Output-only directories are enumerated independently: every
file must appear exactly once; no unexpected files are dropped. The adapter exposes every
native data column under verified canonical names/units and yields ordered objects:
`key` (complete coordinate tuple as JSON list), numeric elapsed `time`, `values` (column map),
and `periods` (`seasonal,annual,cumulative` IDs). Keys include all calendar/repeat/grid/layer
coordinates; no smoothing, clipping, interpolation, dropped columns or cumulative resets.
Do not sort away malformed raw ordering. Audit conversions, calendar keys, native headers
and native-to-canonical column coverage with discriminating adapter fixtures before use.
The provided canonical JSONL reader supports audited exports and synthetic tests; it is not
a completed Ottawa native-format adapter. Preserve hashed export inputs, adapter code and
conversion receipts as evidence; native adapter completion remains a future scientific task.

Raw F3 validation derives actual columns, counts and terminal keys from both streams and
matches the reviewed inventory exactly. `terminal_key` is the complete JSON key list.
Policies define all five `metrics`: `instantaneous,event_timing,seasonal,annual,cumulative`.
Each has `status=REQUIRED`, justified finite `abs,rel,rationale`; noninstantaneous metrics may
instead use `status=NA,rationale` only when scientifically inapplicable. Seasonal/annual/cumulative
reducers are `sum|mean|min|max`; choose them from the quantity's units/time support, never by
which one passes. Event timing groups by year and uses `peak_time` (first maximum) or
`first_above` with a predeclared `threshold`, in the stream's time units. More complex event
science requires an audited additional reducer before acceptance, not an NA workaround.
Instantaneous checks use both the variable rule and metric rule. Aggregates use bounded-memory
compensated sums. Missing events on one trajectory, extra/duplicate keys, nonfinite values,
unmapped columns and breached rules fail even when report counters claim zero.

## Full-run faster-than-Fortran gate

F6's `equivalent-work-performance` result adds `benchmark: {path,sha256}`. The benchmark has
`schema_version=1`, `scientific_acceptance` (hashed object with current `source_digest,binding_id`,
`campaign_summary` and F2–F5 `reports` refs), `conditions`, and at least three `pairs`.
Each pair references `zig` and `legacy` run-descriptor JSON artifacts. Each descriptor contains
the same `conditions`, and hashed `receipt,summary,build_receipt,executable` references.
Conditions are `hardware,allocated_cores,effective_inputs_sha256,output_contract_sha256,precision`;
precision is `f64-i32`. `hardware` includes the measured `platform,machine` strings plus
resource details. Use `run_ottawa.py --benchmark-conditions <file>` or `exec
--benchmark-conditions <file> -- <argv>` to bind the frozen conditions artifact into each raw
receipt; measured platform/machine must match. Direct successful `gfortran ... -o <product>`
builds through `exec` preserve their product automatically under the build receipt directory. Hash the effective inputs and complete required output contract.

Receipts establish successful execution, executable identity, start time and elapsed wall time.
Runs must be distinct and sequential, with the same build per language across repeats. Both
summaries prove normal exit, complete required outputs and hours 0–262920. Zig additionally
has the final strict binding, zero conservation breaches/unexplained fallbacks and a preserved
Zig 0.17.x ReleaseFast build. Legacy build evidence records actual optimized compiler argv
(`-O2` or `-O3`), saved executable and precision verification. The current gfortran
contract requires `-fdefault-real-8 -fdefault-double-8`, default i32 and no unsafe arithmetic flags; `-O0`, `-Ofast` and `-ffast-math`
are disallowed. If a build driver invokes compilers indirectly, preserve its actual compiler
receipts and product rather than inventing a direct compiler invocation.
The checker derives timings from receipts: median Zig / median legacy must be strictly < 1,
and max Zig < min legacy to establish separation beyond observed spread. Report CPU/memory,
individual timings, build costs and feature differences too. Do not weaken checks or outputs,
compare different durations, or claim a partial-run speedup as final acceptance.

## Publication and loop recovery

`close` reuses an already committed verified closure after interrupted push; `push` requires
that closure, and a new cycle cannot bypass it. Every reachable compact JSON evidence reference
must already be committed unchanged or be in `owned_paths`. Add all cycle-owned code, tests,
scientific decisions and compact evidence explicitly. Ignored payloads require a cycle-owned
`retention_manifest` JSON with `policy=retain-through-F7-and-reproducibility` and an `artifacts`
array of their path/hash references; each payload must still exist. Retention is not a backup:
the live backup/restore rehearsal must demonstrate recovery of cited local evidence. Never
stage unrelated existing work to satisfy closure. `set --retention-manifest <path>` records
that manifest before recording gates.

See [autonomous launcher](../tools/autonomy/README.md) for live readiness and the durable
RESUME → REPLAN → WAITING_FOR_CHANGE state machine. Healthy live work is never terminated
because it is silent. An external wait is not a successful cycle or project completion.

`run_ottawa.py` also claims a durable experiment key before launching, derived from binding,
mode, executable, effective deck, threads and checkpoint bytes. A renamed run cannot repeat an
unfinished/failed attempt. Confirmed scientific failures require a changed causal experiment.
Heuristic error parsing remains RECONCILE, not a proved scientific diagnosis. For a verified
infrastructure failure only, `--recovery-evidence <JSON>` requires the exact `experiment_key`,
`prior_run_id`, `classification=INFRASTRUCTURE`, diagnosis, hashed evidence, a new stable
`resource_identity`, and `prior_process_terminated=true`. If a heuristic science error was
reported, add `scientific_failure_ruled_out=true` and hashed `classification_evidence` proving
that adjudication. Never relabel a scientific failure to enable retry. Each resource recovery
can be consumed once; successful executions may repeat for qualified benchmarks. Include the
cycle's `audit/experiments/<key>.json` and its referenced decisions/summaries in publication.
Historical runs without keys still require manual evidence-based reconciliation at pickup;
this guard does not retroactively classify or rewrite them.
