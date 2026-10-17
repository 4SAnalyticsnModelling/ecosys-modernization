Dsh-only context watchdog architecture

Deployment uses installed dsh 0.2.0-rc.2, Cordis and BasicCompactionEngine.
A repo-local DSH_HOME profile copies the current TUI composition and replaces
the root compaction service; presets inherit that singleton and disable competing engines, pruners and manual triggers.
W=131072, O<=32768, B=8192 and ratio=75000/131072 give threshold=75000.
The subclass preserves native region selection, transaction brackets and shrink
validation. It fails closed instead of swallowing summary/persistence failures.
Pre-step handles existing pressure; llm/stream catches newly admitted context
and yields WATCHDOG_BOUNDARY through the supported error protocol, so the loop
compacts then rebuilds the request. No second process performs compaction.
Checkpoint notes are copied verbatim into the candidate summary before native
commit. Native JSONL is flushed and copied; Git diff and before/after receipts
are retained. Interrupted compactions require reconciliation, never state reset.
The external supervisor owns one UI child and monitors durable state and progress.
It preserves recovery data; it never resends a task or starts the legacy launcher
that writes outside this repository. Installed model gateway is currently offline.

Review criteria: no compaction below 75000 except confirmed provider overflow;
exactly one successful native reduction per crossing; full durable checkpoint;
no silent loss on restart or failed summary; actual installed API compatibility;
contained artifacts; no changes to ecosys scientific code or the open cycle.
