# Production deployment and continuous context hygiene — 2026-10-17

Qwen Flash Next Q8 is promoted to **native oMLX0.7.1rc1 / MLX0.32.4** through
the installed session-owned router. Interpreter and startup are pinned; rc1
uses separate state and cache. The production router successfully started and
loaded the model, then stopped its owned backend, with **zero generation
requests** (`production-smoke.json`, `production-server.log`). The single16K
speed benchmark from the preceding task was not repeated. The other three
models' effective profiles remain unchanged. Orphan recovery recognizes the new
entry and requires recorded process start identity before killing a group.

The global dsh default now runs native-derived deterministic tool/file-output
hygiene before each step: spill above1200 estimated tokens, trim text above2048
codepoints to a768-codepoint head and384-codepoint tail plus retrieval notice.
Full originals, error metadata, tool pairing and replay survive; a durable index
provides session/call/sequence locators. Already bounded output is not rewritten.
Prune or persistence failures block subsequent work. The75K summarization gate
is measured after cleanup and remains unchanged; the original confirmed-overflow
emergency exception remains explicit.

The requested IBM video's English auto-captions were retrieved and reviewed.
Global rules now address validation, persistent detail with targeted retrieval,
minimal relevant tool sets, and explicit correction/supersession of false notes.
See `video-strategies.md`; no raw copyrighted transcript is committed.

**31 checks PASS**:23 installed-native/composition tests,5 supervisor tests,
3 production-route tests. All three installed profiles have exactly one hygiene
service and one summary engine with the expected budgets. Initial loader-name
mismatch was fixed by inserting a separate hygiene service rather than replacing
a named native entry. Fresh read-only verifier `/root/production_review` issued
**PASS** for deployment architecture and evidence after fixes.

No prolonged unattended run, live crash-injection or131K stress test was run.
Headless recovery remains explicit. No Zig/Fortran/science changes were made;
the user's open cycle_00003 files remain untouched. Global installed writes are
authorized by the user's production/global deployment requests; development,
backups and evidence remain in this repository. G1/G3–G5 N/A; focused G2/G6/G7
PASS. Commit/push is recorded by matching HEAD and origin/main.
