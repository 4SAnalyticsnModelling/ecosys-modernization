# ecosys-modernization

Fortran ECOSYS → Zig ecosys-ng. Goal: a scientifically verified 30-year Ottawa campaign
(262920 hours), complete source/output traceability, conservation and a reproducible release whose ReleaseFast runtime beats optimized Fortran.

Start with `AGENTS.md`. Authority: `.agent/protocol.md`. Work order:
`ecosys-ng_ottawa_qualification_execution_plan.md`. One autonomous model makes all decisions;
separate verification uses measured evidence. No human approval or elapsed execution deadline.

```sh
./scripts/project.sh pickup
./scripts/project.sh supervise --config .agent/worker.json
```

The supervisor is opt-in: configure and qualify the live runtime first; see `tools/autonomy/README.md`.
It reconciles crashes, replans repeated failures and waits for changed prerequisites when stalled. This repository's workflow
maintenance does not launch the science worker. Scientific artifacts remain under `audit/`
and repository-local `evidence/`; compact receipts/manifests are committed, with large payloads
retained locally under their recorded retention policy. Caches stay out of Git. Protected references:
`f77src/`, `f77example/`, `ecosys-ng-prod-examples/`. Zig pin: `.agent/toolchain.json`.
