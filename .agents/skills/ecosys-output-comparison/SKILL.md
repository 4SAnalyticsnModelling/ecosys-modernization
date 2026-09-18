---
name: ecosys-output-comparison
description: "Compare every legacy and Zig production output file, row and column with verified units and time semantics. Use for parity reports, cumulative daily outputs, significant deviations and final production acceptance."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Compare the same quantity, not just similarly named columns

Use the verified baseline/input-equivalence report and complete output dictionary. Confirm both runs reached the required end time and have the expected file inventory, row count/key set, intervals and final state. Two equally truncated files can look identical; completion is a separate mandatory proof.

## Normalize without concealing defects
Preserve raw output files and hashes. Build explicit, tested adapters for the actual raw formats: filenames, fixed-width/list-directed fields, headers, exponents, column ordering and sentinels. Normalize units and coordinates only with documented transformations. Do not smooth, interpolate, clip, drop outliers, silently skip columns or reset cumulative values to improve agreement.

Align by meaningful case/time/grid/tile/layer/species keys, not file line number alone. Reject duplicate/missing/extra keys and unexpected columns. Preserve output order rules. Explain legitimate metadata additions individually. Compare daily cumulative legacy columns with cumulative Zig columns over exactly the same reset windows. Examine hourly, daily, seasonal/annual and whole-run views as available.

## Acceptance and diagnostics
Use per-column numerical rules in a versioned reviewed schema. A suitable rule for normalized values is `abs(candidate-reference) <= atol + rtol * max(abs(reference), scale_floor)`, with all scale terms in the column's units. This is a chosen project comparison rule, not a universal scientific tolerance. Discrete values and categorical fields compare exactly. Near-zero behavior requires a justified absolute tolerance/floor; arbitrary relative percentages are misleading there.

Report valid/missing counts, maximum absolute error and its key, normalized error, bias, MAE/RMSE, threshold exceedances, first exceedance, seasonal drift and cumulative endpoint differences. Add distribution/phase/peak diagnostics appropriate to the process. Good correlation alone cannot pass. A numeric mismatch remains visible even when a later feature dossier explains it.

The supplied `compare_outputs.py` is a normalized-CSV helper with strict header/key checking and all-column metrics. It is not the raw ecosys parser, completeness checker, seasonal analysis engine or a scientific acceptance authority. Expand the repository-specific analysis where needed and test it.

## Diagnose and close
For every significant unexplained difference invoke `ecosys-divergence-diagnosis`, starting with inputs, bindings, units, translation and scheduling. Only then invoke `ecosys-feature-attribution`. Store two reports where relevant: unchanged-physics/kernel equivalence and improved-production acceptance. No blanket feature waiver.

Done requires every discovered output file/column accounted for, complete runs, reviewed thresholds, no unresolved significant drift and linked conservation and feature evidence for the one final candidate.
