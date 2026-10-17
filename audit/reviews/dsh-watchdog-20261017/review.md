# Dsh watchdog setup and evidence — 2026-10-17

Implemented at `tools/dsh-watchdog/`; installed private composition at
`watchdog/home/profiles/dsh-tui/`. Source/runtime versions: dsh 0.2.0-rc.2,
dsh-tui 0.15.0. Four current local models receive W=131072, O=32768,
B=8192, threshold=75000, summary cap=4096, retain=12000, one attempt.
Original installed dsh launch path is unchanged. Use the supplied supervisor.

Validation: **13/13 installed-native tests + 4/4 supervisor tests PASS**.
Exact formula is checked for every output reservation 1..32768. Native
transactions, supported stream/error retry, checkpoint persistence checks,
durable notes, overflow, conflict, missing meter, repeated tools and recovery
continuation are exercised. Deterministic summarization and persistence fixtures
are used, not live model completions. See `result.json`, local `tests.log` and
`supervisor-tests.log`; preflight passed with repo-local cache pins.

Fresh-context read-only verifier `/root/verify_dsh` independently inspected the
installed contracts and implementation. Initial reproduced failures (scope
multiplicity, unstable loop signature, incomplete checkpoint durability, stale
restart state, child overwriting root resume pointer) were fixed and tested.
Final verdict: **PASS for reviewed code and installed API contracts**; live
131K capacity, full process/power-loss recovery and model scientific correctness
remain unverified. The local gateway refused connection, so no throughput or
model-task correctness result is claimed.

Gates: G1 N/A (no Zig change); G2 PASS focused tests; G3–G5 N/A (no model
science/output change); G6 PASS (no scientific tolerance/DEV/source changes);
G7 PASS scoped independent code/API review; G9 PASS writes contained here,
installed runtime/config read-only for explicitly requested inspection.
G8: commit and push this setup separately from the user's open cycle 00003.
The pre-existing `.agent/cycle.json`, `.agent/state.md` and cycle_00003 record
remain untouched and are excluded from this commit.

All generated state/session/checkpoint files are gitignored under `watchdog/`;
full logs and original sessions stay on disk. Tracked setup, tests, templates
and evidence are sufficient to reconstruct configuration. Limitations and
safe reconciliation are documented in `tools/dsh-watchdog/README.md`.
