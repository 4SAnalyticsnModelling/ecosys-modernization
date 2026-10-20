---
name: ecosys-divergence-diagnosis
description: "Find the earliest causal legacy/Zig divergence; use for failed hours, unexplained outputs and repeated experiments."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Start from the issue signature, source/deck/executable identity and first differing key.
Reproduce the parent failure before testing a fix. Check inputs, defaults, parsing, units,
calendar/cumulative support, bindings/update order, duplication, precision and floors before numerics.
Use existing checkpoints only after full-state restart equivalence; cross-revision replay is
diagnostic. `make_failure_packet.py` groups failures by signature; only matching binding/state/dependency
records with a falsifier remain active rejections. Others are historical leads. Record each
experiment's falsifier/result. Capture producer/exchange/consumer terms and create a minimal
regression. After three unproductive experiments reduce the state/window or change hypothesis.
Close with legacy file:line cause, before/after numbers, coupling/conservation and separate review.

For implicit-only stalls or near-zero/signed defects use
[numerical recovery](../../../.agent/playbooks/convergence-and-balance.md). Legacy completion
does not prove admissibility or convergence. Capture raw residual, denominator, rounding bound,
active branch and total evaluation counts; distinguish a moving scale from real supply failure.
Demonstrate prompt benign completion as well as physical rejection on the minimal fixture.
For NaN/Inf or finite spikes, capture the first producing operation and operands, plus adjacent
hours for a reversal. Audit domains/overflow, units/timestep, initialization, reset/lag and
duplicate transfers. Preserve invalid legacy output as evidence; fix analogous hazards in Zig
with independent physical checks and attributed differences, including dormant code scope.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
