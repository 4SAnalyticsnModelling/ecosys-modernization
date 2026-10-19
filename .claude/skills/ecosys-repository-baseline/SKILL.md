---
name: ecosys-repository-baseline
description: "Establish source/input/toolchain identity and a usable legacy oracle; use before parity or when provenance is stale."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Use pickup and `preflight.py`; inspect real commands before registering them. Protect all
reference trees. Pin Zig 0.17.x; legacy precision is f64/-i4 with exact compiler flags recorded.
`snapshot.py` inventories references; `evidence_binding.py` identifies source/deck/build settings.
Check the legacy manifest for actual final time and complete files: the preserved partial
archive is not a full baseline. Stage with `prepare_legacy_build.py` and `stage_legacy_deck.py`
only after inspecting their argv; compile/run through the logged wrapper with current host flags.
Record instrumented-copy patches separately. Never infer readiness from hashes or compiler exit.
