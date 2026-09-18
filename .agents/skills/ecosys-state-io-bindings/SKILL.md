---
name: ecosys-state-io-bindings
description: "Trace model state, COMMON replacements, process coupling, parsers, units and output writers end to end. Use for binding gaps, stale values, incorrect defaults, suspicious zeros, missing outputs and cumulative-field mismatches."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Verify the path from input to reported output

For every parameter, forcing value, persistent pool, flux, diagnostic and output column, record its legacy identity, Zig owner/type/shape, units, sign convention, initialization, producer, consumers, time level and reset/accumulation rule. Read actual call sites and writers. Similar names are not binding evidence.

## State and interfaces
Audit every COMMON replacement and context struct for omitted fields, incorrect sharing, accidental copies, persistent-versus-local lifetime and default-zero substitutions. Distinguish tile/grid/layer/species/plant/canopy indices. Check boundary/ghost mappings, flattened strides, contiguous versus strided inputs and ownership across worker threads. Verify each changed value reaches the correct consumer at the correct phase and is not overwritten by an outdated snapshot.

Trace a representative value and boundary case through input parser -> configuration -> initialization -> process -> exchange -> integrator -> diagnostic -> output writer. Use tagged sentinel values only in controlled tests to expose swaps. Check coupling inputs are populated before use; no stub, `TODO`, catch-to-zero, never-called routine or ignored error may silently disable science.

## Input behavior
Verify units, date parsing, leap years, missing forcing, EOF/truncation handling, fixed-width/list-directed behavior, Fortran D exponents and dimension checks as present. Missing data are not automatically zero. Confirm fallback defaults match the reference or are explicit reviewed changes. Distinguish case-sensitive paths and platform newline behavior from scientific differences.

## Time and output semantics
For every actual output column define row keys, coordinates, units, sign, spatial basis, time support, output precision and no-data convention. Determine whether a daily field is an instantaneous sample, mean, daily integral or cumulative total. Match the legacy reset boundary: daily, seasonal, annual or since simulation start. Do not convert cumulative legacy output into daily increments to make plots look close. Verify rates integrate with the correct timestep and area/mass normalization exactly once.

Inspect all suspicious columns, not just evapotranspiration. Trace persistent zeros, repeated values, sign reversals, spikes, missing seasons and abrupt cumulative resets back to their producers. Check metadata and hidden counters too. Validate writer error propagation, flushing, file completeness and safe finalization.

## Artifacts and done
Produce symbol/binding ledger and complete output dictionary with raw-format adapter tests, selected end-to-end trace fixtures and regression cases. Each output must have a proven live producer and correct aggregation path. No unexplained missing, zeroed, misindexed or stale binding remains in scope.
