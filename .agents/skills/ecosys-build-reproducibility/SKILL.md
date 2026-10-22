---
name: ecosys-build-reproducibility
description: "Verify exact Zig/legacy builds, packaging and restart reproducibility; use for build drift and release checks."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One leader decides and verifies;
optional safe sub-agents follow the protocol. No adversarial reviewers or reviewer approval gates.

Use Zig 0.17.x; inspect actual build/CLI flags. `project.sh exec` pins caches and records version.
Build Debug/ReleaseSafe and production ReleaseFast with `--cache-dir .zig-cache` in ecosys-ng.
Record compiler binary/version, target/options/dependencies and hash the actual installed exe.
Measure clean builds in dedicated repo-local caches; never erase a shared/live cache.
Do not run a stale binary after failed build. Compare behavior and separately investigate
executable-byte nondeterminism. Full-state restart covers clocks, management, lagged fluxes,
cumulative/output and solver state; reject incompatible/truncated checkpoints atomically.
Prepare reproducible manifest/commands; publish only the verified cycle to origin/main.

For [numerical safety](../../../.agent/playbooks/convergence-and-balance.md), record actual
floating-point modes/backend flags and prove finite/domain guards using runtime fault inputs
in the production executable. Debug assertions or a safety-build pass alone are insufficient.
Corrupt/nonfinite restart rejection must be atomic and preserve the last valid checkpoint.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
