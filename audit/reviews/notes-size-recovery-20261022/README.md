# Notes size recovery, 2026-10-22

The active Strata DSH session stopped at events 5094 and 5098 with
`Durable notes exceed 24KB; curate notes before continuing`. Its three note files
produced a 24,999-byte bundle. The pre-step admission check rejected all subsequent
turns, including the user's request to curate the notes, before the model could act.
HerdR itself remained running.

`tools/dsh-watchdog/core.mjs::notes` now archives every complete original note before
returning an explicitly partial view of at most 24,000 bytes. Archives are atomic,
fsynced, content-addressed JSON containing all three files verbatim. Whole-line tails
preserve UTF-8; decisions/issues remain complete when their combined sizes permit it.
The view requires retrieval and reconciliation of omitted decisions before action.
The guard never edits source notes. Conflicts in any original, archive mismatches,
missing files and persistence failures still reject admission.

Independent check of the bound: the budget subtracts every heading, notice and join
separator from 24,000; file allocations sum to at most the remainder; each whole-line
view fits its allocation. The archive filename hashes the complete original bundle,
so even a change entirely outside the visible tail changes the checkpoint hash.
Conflict checks inspect complete originals before choosing any excerpts. The old
installed guard reproduced the exact error against the live notes before deployment.

Validation: `native-admission-tests` records 31 passed, zero failed/skipped/cancelled,
including the real native pre-step allowing an oversized-note curation turn and the
existing checkpoint, summary-fallback, pairing and hygiene tests. `installed-tests`
records seven passed against the deployed global core, covering size recovery,
verbatim preservation, UTF-8, long lines, hidden changes/conflicts, corruption and
archive-write failure. `tests` retains the earlier 30-test run before adding the native
admission regression. All raw logs and execution receipts accompany this report.

Deployment changed only `notes()` in the installed core. Byte-for-byte comparison
verified the remainder of the installation stayed unchanged, preserving its existing
Strata routes and capacity reservations. `installed-core.before.mjs` is the backup;
`deployment.json` records before/after hashes, note hashes and retained archive paths.
Current progress was curated to retain the last cycle-7 handoff verbatim and an archive
reference; decisions/issues were unchanged. The resulting bundle was 8,548 bytes.
The complete original native session was also copied before restart.

`restart.json` records the failed-turn event and checked PID/start identity. Only the
idle failed-turn DSH host received SIGTERM, through its native shutdown path. Its
existing supervisor restarted it into session `4c83caf2-c5bc-4235-81c5-f346a4f7f22a`.
HerdR PID 6067 and Strata engine PID 47451 were preserved. No simulator was running.
The saved cycle-7 scientific work and its gates were not changed by this repair.
That first resumed owner subsequently exited during compaction. Native persistence inspection
proved the complete checkpoint event prefix was unchanged, followed only by its compaction/start:
5,103 checkpoint events plus that one event, with no summary publication or completion receipt.
`reconcile-interrupted.mjs` acquired native write ownership, preserved a second full backup,
and appended an explicit failed compaction/end and failed turn/end without deleting any event.
`interrupted-inspection.json` and `interrupted-reconciliation.json` retain the proof.

The fallback now distinguishes this proved unpublished interruption from token-cap exhaustion,
and can preserve the complete selected conversation in a native recovery checkpoint without
claiming a model summary was completed. The latest `interrupted-recovery-tests` run records
32 passed, zero failed/skipped/cancelled. Only the installed summarize method was changed,
preserving its route policies; `summary-recovery-deployment.json` records that comparison.

A fresh DSH session was already open in the same HerdR pane when the original boundary was
reconciled. Use that existing session as the sole leader, with the recovered handoff, rather
than launching a duplicate. Live continuation evidence is recorded separately in `resume.json`.

This is harness maintenance, not Ottawa qualification or resolution of issue-117.
Scientific builds and F1–F7 promotion are outside this change. Genuine persistence or
decision conflicts still require evidence-based repair; the size-only deadlock has a
bounded recovery path rather than disabling those checks.
