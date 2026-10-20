---
name: ecosys-output-comparison
description: "Compare all raw legacy/Zig production outputs with verified units and time support; use for parity and release."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Inventory files, columns, keys and required terminal time before comparing values. Populate
`audit/output-provenance.csv` with producer, units, aggregation, conversion and rule per field.
`outcompare.py` parses supported raw streams; `compare_outputs.py` accepts normalized CSV;
`zig_run_diff.py` checks candidate reproducibility. None alone proves full qualification.
Use full year/date/hour/grid/layer/species keys, reject duplicates/missing/extra/nonfinite data,
and verify cumulative reset semantics. No interpolation, smoothing, clipping or silent exclusions.
Report first divergence, worst key, bias/RMSE and coverage for every column. Keep unchanged
kernel rules separate from approved-feature envelopes. Diagnose unexplained drift before attribution.

Apply [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md) to nonfinite
or implausible legacy/modern outputs. Retain invalid oracle rows and affected coverage; do not
match, filter or average them into success. Examine first/worst hourly excursions and reversals,
their units, reference state, forcing and physical bounds. Net closure cannot excuse an invalid
hour; legitimate large events need causal evidence. Attribute Zig repairs with independent
physics and a registered deviation; parity to broken legacy output is not scientific validation.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
