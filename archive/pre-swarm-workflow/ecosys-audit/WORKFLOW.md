# Bounded autonomous Claude/Pi workflow (stages 2-4)

This operational policy implements the user's cost-saving authorization. It does not change
science, tolerances, gates, publication permissions, model selection, or reasoning effort.
The contract and evidence guide remain authoritative. Tools here validate bookkeeping,
not scientific truth or independent reviewer identity; shell access is not a sandbox.

## Automatic adoption and ownership

Project Claude hooks and the Pi extension load on the next trusted project session.
No global settings or Herdr-managed integration files are replaced. The root AGENTS.md /
CLAUDE.md route audit continuation here; do not apply autonomous scheduling to questions,
plan-only requests, or unrelated tasks.

On an autonomous audit continuation **inside Herdr**, the lead runs:

```
uv run ecosys-audit/scripts/herdr_cycle.py ensure
```

This idempotently starts one detached local controller, or reports ALREADY_RUNNING.
It waits for the named `editor` and `reviewer` to become idle, never interrupts a turn,
and uses the current session's inherited Herdr environment. Once started, yield so it can
send the next bounded assignment. Do not dispatch peer prompts yourself while it owns
the lane. No human is needed to clear context, forward reviews, or select routine work.
The controller asks the lead to select the next unblocked task from the current checkpoint.

The Herdr 0.9.1 readiness field is `result.agent.agent_status`, not `state`. The controller
validates the named pane, harness, project cwd and native session reference against startup
registration. It records READY/WAITING observations in `audit/workflow/runtime/controller-status.json`
and flushes state transitions to `controller.log`; steady waits update the heartbeat at most
once per 30 seconds without printing every poll. Missing/unsupported response fields fail
explicitly, and an `unknown` classification gets a bounded 15-second grace rather than an
hour of silent polling. A controller process already running old Python code must be restarted
from inside Herdr to load a controller-code fix; `ensure` alone does not replace its lock owner.

### Two autonomy modes (pick one; never both)

The controller dispatches only when **both** panes are idle. A lead that is held in-turn (a
`/goal` stop hook, or any continuous session) never idles, so the controller would wait forever.
In that case use **lead-driven mode**. The lead runs the whole cycle in its own turns and never
hand-types Herdr prompts:

```
workflow.py begin -> work -> checkpoint -> seal
herdr_cycle.py peer            # sends packet to Pi once; blocks model-free <=540 s
                               # PENDING -> run peer again (never re-sends); REVIEWED -> verdict
FAIL (revision 1): fix, reseal, peer once more.   PASS / 2nd FAIL / BLOCKED: finalize
workflow.py checkpoint -> close
herdr_cycle.py next            # /new for Pi when idle; lane back to idle
```

Sealed evidence (including an issue file's top Status: line) stays byte-frozen until `close`
succeeds; put the verdict in the handoff first and update the issue's Status line after close.
The PowerShell/Bash tool timeout must exceed `--wait` + 60 s. `peer` returns REVIEWER_BUSY
without sending when Pi is mid-turn, and fails closed at a permission dialog. It records
`ambiguous` if Pi yields with no receipt, which calls for inspection, not a re-send. Pi's
identity is bound by `workflow.py review`, not by Herdr's session reference. That reference lags
after `/new` because Pi writes its session file lazily. The lead is not `/clear`-ed in this mode.
It relies on harness compaction plus the 6,500-byte checkpoint, so keep turns terse. Both modes
resolve a lost pane name through the registered pane ID and restore the name.

The existing `scripts/orchestrate-adversarial.sh` enters this same controller. Do not run a
second orchestration loop. Both agents must have started/resumed with the project integrations
loaded before named-session rotation is possible. Startup records bind roles to pane and
native conversation IDs. The controller refuses unknown identities or permission dialogs.
Outside Herdr use the same artifact protocol, but do not claim automatic CLI rotation ran.

Claude owns implementation, the task state and current handoff. Pi independently inspects
source/raw evidence and writes only `audit/reviews/` (plus mechanical runtime registration).
Pi cannot promote its result to a release gate. No automatic commits, pushes, tags, bulk
cleanup, privilege changes, extra teammates, or approval-dialog answers.

## One task, one question

Run all helpers with `uv run` from the outer root. `workflow.py status` is bounded JSON:
current phase, task/revision, handoff hash. It never prints historical handoffs or raw logs.

1. Read `audit/handoff.md` (current state only), relevant issue, applicable specialist skills
   and the shared policies if absent from this context. Read history only to answer a
   specific unresolved question. Do not load the 280 KB archive at startup.
2. Select a single falsifiable question or coherent patch, its dependency boundary,
   focused acceptance checks and stop condition. Preserve existing dirty/untracked work.
3. Write a small spec such as `audit/workflow/spec-next.json`:

```json
{
  "issue": "issue-NNN",
  "question": "One concrete question, not make the entire release ready",
  "scope": ["ecosys-ng/src/path/to/affected.zig"],
  "done_condition": "Named focused checks and independent review",
  "stop_condition": "Three distinct failed experiments; no repeat of unchanged failure"
}
```

```
uv run ecosys-audit/scripts/workflow.py begin --from audit/workflow/spec-next.json
```

The helper supplies task ID, author session, base fingerprint and revision. Scope entries
are individual files, not directories. Include relevant definitions/callers/configuration.
Full source coverage remains a project-wide obligation, not a requirement to reread the
whole project per task. Same issue/question/candidate cannot be scheduled twice.

4. Do the task, preserving the smallest affected tests and dependent-interface checks.
   Record scientific evidence in the existing issue/test/dossier conventions. New unrelated
   findings go into the queue; they do not silently enlarge the current package.
5. Update the current checkpoint, then write a small editor result:

```json
{
  "status": "READY_FOR_REVIEW",
  "summary": "What changed or was established, with no release claim",
  "evidence": ["audit/issues/issue-NNN-example.md", "audit/runs/example/receipt.json"],
  "open_processes": [],
  "next_action": "One bounded next action"
}
```

Use `BLOCKED` instead of READY_FOR_REVIEW if the requested evidence is unavailable. Preserve
actual failed tests and incomplete coverage; no invented PASS. Finish/reap task-owned
processes before sealing; do not declare an empty list while a build/run is still active.

```
uv run ecosys-audit/scripts/workflow.py seal --from audit/workflow/result-next.json
```

The helper hashes evidence and creates immutable task/candidate/packet files. It checks
tracked and unignored files under the four authoritative trees plus the declared scope.
Ignored/generated files are excluded: this is an operational invalidation guard, **not** a
replacement for the complete source/input/toolchain snapshot required by the gates. Raw
external inputs and symlink dependencies still need the existing baseline provenance.
Do not edit sealed source/evidence until the reviewer has returned.

## Independent review and bounded correction

The controller sends Pi a packet path and digest, never the editor's terminal history.
Pi reads the relevant original code and raw evidence independently. PASS means only the
specified package passed review. Unrelated project gaps cannot be used as endless reasons
to reject an otherwise sound bounded package; dependent omissions must still fail it.

Before its first receipt, Pi preserves unresolved work from the old conversation in
`audit/reviews/carry-forward.md` (explicitly state none if there is no prior work), including
pending assignments and owned-process state. Include that file in review evidence so the
first automatic reset cannot silently discard prior reviewer obligations. The lead carries
these forward into the issue queue/checkpoint. Pi writes its source-anchored record under
`audit/reviews/` and submits:

```json
{
  "packet_sha256": "COPY FROM ASSIGNMENT",
  "verdict": "FAIL",
  "summary": "Bounded independent conclusion",
  "findings": ["F1: path:symbol:line-span; evidence; concrete defect and required check"],
  "evidence": ["audit/reviews/this-task-independent-evidence.md", "audit/reviews/carry-forward.md"],
  "open_processes": []
}
```

```
uv run ecosys-audit/scripts/workflow.py review --from audit/reviews/result-next.json --session-id <PI_SESSION_ID>
```

PASS requires an empty unresolved-findings list; use BLOCKED for missing verification.
The helper binds the result to task/revision/packet/candidate and checks freshness. It does
not authenticate identities or evaluate science. The controller reads the immutable result,
not an approval string. It detects source/deck/scope changes during review and refuses approval.
Pi's direct write/edit tools are lane-guarded; shell commands are NOT sandboxed. Unassigned
shell mutation violates the protocol and can invalidate review even if it evades the tool guard.

One initial review plus one changed-evidence re-review is the normal maximum. On the second
FAIL, retain FAIL, finalize the failed package, and choose a different falsifiable question or
unrelated unblocked task. Do not relabel the same question to evade the limit. Repeated unchanged
candidate AND evidence cannot be resealed for another review.

After the final review, Claude gets a short finalization assignment. Update only current
status/queue, include the task ID and review path in the handoff, then:

```
uv run ecosys-audit/scripts/workflow.py close
```

The closure records the verdict, current handoff/review hashes and candidate. It always leaves
release status NOT_ASSESSED. Source changes during finalization invalidate closure.

## Checkpoint and automatic context rotation

`audit/handoff.md` is current state, maximum **6,500 UTF-8 bytes** (a byte ceiling, not a token
measurement). Use the headings Candidate, Gates, Active work, Next action, Recovery.
Include candidate identity, real gate status, active/pending issues, last useful experiment,
rejected hypotheses, owners, dirty work and task-owned process status. Link details.

Write the proposed replacement to `audit/workflow/checkpoint-next.md`, get the old hash with
`workflow.py status`, then:

```
uv run ecosys-audit/scripts/workflow.py checkpoint --from audit/workflow/checkpoint-next.md --expected-sha256 <old-hash>
```

Every replacement preserves the previous bytes in `audit/history/handoff-<sha256>.md` before
atomically replacing the live checkpoint. Cooperating publishers use ignored sidecar locks;
publication does not require filesystem hard-link support. Concurrent change detection rejects stale writers.
Do not append round histories to the live handoff. Keep historical evidence and line anchors
in their archived files; do not delete old summaries merely to save tokens.

At a durable closure and only when both agents are idle, the controller sends `/clear` to
Claude and `/new` to Pi. It waits for each startup integration to acknowledge a **different
native session ID** before submitting the next assignment. No repeated compaction/model
summary calls are needed for this boundary. The same sessions remain open through an immediate
correction/re-review. The previous CLI transcripts remain on disk.

A timeout is NOT a stopped agent and never authorizes resubmitting the same prompt. Dispatch
intent is persisted before sending. After ambiguous delivery the controller waits and consumes
late artifacts if possible, otherwise records BLOCKED without sending another task or clearing
context. On recovery, inspect `audit/workflow/runtime/controller-status.json` and the existing
task artifacts; reconcile the existing work, not a duplicate. If the editor recovered into
a new native session while editing/finalizing, reconcile old owned processes and dirty work,
then call `workflow.py adopt --reason <bounded-recovery-record>`. This preserves immutable
author-transfer evidence; every prior author remains ineligible to independently review the
task. Never adopt somebody else's still-active work. Genuine permission, environment,
or exhausted-work blockers pause the dependent lane instead of spending tokens on a polling LLM.
Reset intents and acknowledgements are persisted, so a controller restart recognizes a reset
that already completed rather than blindly clearing the new conversation again.

If no safe new work exists during planning, use `workflow.py park --reason <bounded explanation>`
and stop. Resumption must be driven by new evidence or a new explicit audit request, not a timer
that repeatedly asks the model whether it is still blocked. When an agent has new evidence,
it writes a short evidence record, runs `workflow.py unpark --evidence <project-relative-file>`,
then `herdr_cycle.py ensure`; no human forwarding/clearing command is needed. Routine operation needs no manual
forwarding or clearing; this does not promise to bypass genuine permission/environment blockers.

## Keep raw output off the model's normal input path

Use the command wrapper for builds, tests and verbose diagnostic commands:

```
uv run ecosys-audit/scripts/run_logged.py --cwd ecosys-ng --out audit/runs/<unique-task-command> --timeout 300 -- zig test src/example.zig
```

The command above illustrates syntax, not an approved model test target. Use the command
registry's actual argv. Pi puts assigned test logs under `audit/reviews/<unique-dir>` instead.
The wrapper uses argv without a shell, saves complete stdout/stderr plus argv/cwd/exit/time/hash
metadata, returns bounded first/last/diagnostic excerpts and propagates nonzero exit status.
Test counts are NOT_ASSESSED until the real runner output is verified. Selective excerpts do
not prove acceptance. Preserve and inspect raw evidence when needed.

Keep the enclosing tool call alive with timeout at least wrapper timeout + 60 seconds. Do not
use Start-Process and return early: this host has previously killed children with the tool's
Windows Job. A timeout kills only the wrapper's owned process tree and records TIMED_OUT;
it never kills unrelated builds. Rejected launches and incomplete runs are not test passes.

Pi also stores oversized shell-tool results outside model context and returns an explicitly
labelled excerpt/path/hash. Such captures may already be truncated by the built-in tool;
only the wrapper captures complete raw streams. Source reads are not silently shortened.

Normal terminal limits: progress 0-2 sentences; editor result <=200 words; reviewer result
<=300 words; finalization <=150 words. Write detailed scientific evidence once, then refer
to it by path/hash. Writing to disk still costs generated tokens; avoid repeating the report.

## Validation boundary

Offline self-tests exercise archival, stale-write rejection, task/review binding, duplicate
suppression, bounded cycles, rotation acknowledgements, hook/extension behavior and raw-log
preservation. They do not run paid models or certify live Herdr compatibility. Unexpected
Herdr JSON/state or unloaded startup integrations fail closed. No cost reduction percentage
or scientific release gate is implied by passing these infrastructure tests.
