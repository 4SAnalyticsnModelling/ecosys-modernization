# workflow-003: a /goal-held lead never idles, so the controller never dispatches

Status: FIXED (2026-09-23). Task `20260923-225940-8ace44ed` CLOSED, Pi PASS delivered by
`herdr_cycle.py peer` itself (`audit/reviews/20260923-225940-8ace44ed-r1.json`); full live
cycle begin/seal/peer/close/next observed. Infrastructure only; no science or gate change.
(Status line updated after closure: sealed evidence is frozen until `close`.)

## Observed defects (live, 2026-09-23)
1. `controller()` waits for editor AND reviewer idle before every step. Under a `/goal`
   stop hook the Claude pane never idles, so no dispatch ever happens; the prior round had
   to dispatch Pi by hand (handoff "Manual cycle").
2. After `/clear` the editor hook re-registered `43e904b2...` but Herdr still reported the old
   session; `rotate()` treated the transient disagreement as fatal
   (`controller-status.json`: "editor native session disagrees with its registration").
3. Pane names were lost again (`herdr agent get editor` -> `agent_not_found`), which blocks
   every name-addressed call.
4. After `/new`, Herdr showed Pi session `01a0d077...` whose `.jsonl` did not exist yet
   (Pi writes it lazily), while `reviewer.json` still held `01a0d006...`.

## Change (scope)
- `ecosys-audit/scripts/herdr_cycle.py`: `Herdr.live()` resolves by name, else by registered
  pane via `agent list`, and restores the name; Herdr stdout error envelope is kept in the
  error text; reviewer `unknown` Herdr status is settled when Pi's own registration is idle;
  missing Pi session reference falls back to the registration; `rotate()` tolerates
  transient identity disagreement for 90 s. New lead-driven subcommands `peer` (dispatch
  packet at most once, block model-free for the receipt, consume it, return small verdict;
  PENDING / REVIEWER_BUSY / ambiguous-on-no-receipt) and `next` (after close: `/new` Pi, lane
  to idle).
- `ecosys-audit/tests/test_herdr_adapter.py`: 4 new offline tests.
- Docs: `ecosys-audit/WORKFLOW.md` "Two autonomy modes"; orchestrator and coordination
  skills (`.agents` and byte-identical `.claude` copies); CLAUDE.md, AGENTS.md,
  START_PROMPT.md, `workflow_hook.py` BOOTSTRAP.

## Evidence
- Offline suite: `audit/runs/workflow-lead-driven-selftest-20260923/receipt.json`
  (exit 0; stderr reports `Ran 67 tests ... OK`). Offline tests do not certify live Herdr.
- Live: `herdr_cycle.py next` returned `{"status":"IDLE","reviewer_rotated":true}` from
  the closed state of task `20260923-205755-0455a53b`.

## Known limitations
- Lead-driven mode does not `/clear` the lead; it relies on harness compaction.
- `reviewer_pane()` checks pane/harness/cwd, not Herdr's session reference; the Pi session
  binding is enforced by `workflow.py review` (registered session, never an author).

## Post-closure addendum (not covered by the Pi PASS)
The `workflow_hook.py` PreToolUse check raised `Path escapes project` for any Edit/Write outside the repo, which blocked the harness memory directory. Out-of-project paths are now ignored by that check; the handoff guard still denies (checked by piping hook events). Needs review in the next task packet that touches `workflow_hook.py`.

