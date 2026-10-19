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
diagnostic. `make_failure_packet.py` carries rejected hypotheses by signature. Record each
experiment's falsifier/result. Capture producer/exchange/consumer terms and create a minimal
regression. After three unproductive experiments reduce the state/window or change hypothesis.
Close with legacy file:line cause, before/after numbers, coupling/conservation and separate review.
