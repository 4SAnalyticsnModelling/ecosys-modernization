---
name: ecosys-state-io-bindings
description: "Trace state ownership, process coupling, parser defaults and output semantics; use for stale/zero/wrong fields."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Follow input → parser/default/units → state owner → producer → exchange → consumer → writer.
Record shape/lower bounds, units, time level, initialization/reset and checkpoint persistence.
Audit COMMON/EQUIVALENCE/SAVE replacements, copies, pending fluxes and cumulative counters.
Use `bindcheck.py` as triage only; presence of a name proves neither shape nor live connection.
Populate `audit/traceability/bindings.csv` and `audit/output-provenance.csv` from checked source.
Capture matched boundary states to expose stale/duplicate writes. Test nonzero and absent
inputs, reset/year boundaries and complete restart. Invalidate every dependent output check.

Follow [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md) for nonfinite
or spiking fields. Reject invalid input/restart numbers before use; defaults apply only to
documented absence, never malformed/NaN values. Trace the earliest bad producer, units, lag,
reset or duplicate transfer. Validate finite/admissible state before atomic output/checkpoint
commitment, including ReleaseFast; failures must retain the last valid checkpoint and exit
explicitly. A next-hour correction cannot validate the preceding invalid state.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
