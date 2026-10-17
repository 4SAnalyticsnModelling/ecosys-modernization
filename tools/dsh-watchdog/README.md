# DeepSeek Harness watchdog

Repository-contained deployment for installed **dsh 0.2.0-rc.2 / dsh-tui 0.15.0**.
All four current local models have policies: Qwen Flash Next Q8, Qwen3.8 27B BF16,
GLM 5.3 Flash 6-bit, and GLM 5.3 Flash mixed 4/8-bit. Other harnesses are untouched.

From the repository root:

```sh
node tools/dsh-watchdog/setup.mjs
python3 tools/dsh-watchdog/launch.py --check
python3 tools/dsh-watchdog/launch.py
```

Use this launcher for watchdog sessions. The ordinary installed `dsh` command
retains its prior configuration. Setup reuses installed packages read-only and
copies the current TUI composition under `watchdog/home`; generated profiles,
logs, sessions and notes are private, gitignored, and remain inside this repo.
A private TUI package copy redirects its hardcoded preference path to `watchdog/tui-data`; the installed package is unchanged. Re-run setup after model-catalog changes. Unknown dsh versions fail closed.
The existing local gateway at **127.0.0.1:8090** must be running; the supervisor
checks its catalog before launching. It does not invoke the old gateway manager,
which writes outside the repository. At setup the gateway was offline, so live
131,072-token capacity and model-task performance remain **unverified**.

## Policy

Each routed model advertises W=131072 and O=32768, with B=8192,
thresholdRatio=75000/131072=0.57220458984375 and summary maxTokens=4096:
`floor(min(W*ratio, W-O-B)) = 75000`. A larger request output reservation is
rejected. One root Cordis `BasicCompactionEngine` subclass serves every preset;
other engines, manual compact commands, historical-result pruners and image
compaction are disabled. Native spill policy limits newly injected outputs to
2000 tokens and retains complete spill files. Retrieval must still be targeted.

The supported token meter measures **current routed envelope pressure**, never
lifetime usage. Its `baseline.kind` is recorded. **This installed meter uses a
heuristic until matching provider usage exists; 75,000 meter tokens cannot be
claimed to equal exactly 75,000 tokenizer tokens.** System prompt, tool schemas,
images and current surface participate in native measurement. A pre-step check
handles existing pressure, and an `llm/stream` gate catches newly admitted input
before network dispatch. `WATCHDOG_BOUNDARY` uses the native request-error/retry
contract to compact and rebuild; it is separate from real provider overflow.

At the boundary, native persistence must flush successfully. Checkpoints include
original session files, tracked binary Git diff, untracked file contents,
verbatim notes and a receipt. Contents and directories are fsynced before
compaction. Native balanced selection, bracket locking, shrink checks and rollback
remain authoritative. Exactly one summary attempt is allowed; failed or
insufficient compaction blocks work. A recent 12,000-token tail is retained.
Only confirmed `CONTEXT_WINDOW_EXCEEDED` permits emergency compaction below 75K,
once per consecutive failure episode. Successful assistant output resets it.

Update `watchdog/progress.md`, `decisions.md` and `issues.md` before major work or
tests. Notes (maximum 24KB) are copied **verbatim** into the candidate summary;
a summary is never trusted to preserve scientific decisions through paraphrase.
Notes changing during summarization, empty/truncated summaries, or `CONFLICT:`
decisions block the transaction. Original JSONL and checkpoints are never rotated
away. Supervisor diagnostics rotate through four 4MB files. The supervisor never
compacts or submits the original task a second time.

## Recovery

`watchdog/state.json` is independent of the dsh process and includes the current
session, request tokens, measurement baseline, checkpoint, compaction counts,
errors and timings. Missing/corrupt state with existing sessions is an error,
never an invitation to initialize an empty session.

Clean restart selects the recorded current session automatically; an interrupted
running task receives a continuation through supported `agent/created` and
`agent.followup`, instructing it to reconcile interrupted actions before acting.
Unexpected child exit permits at most two persistent process restarts. Active-turn state, rather than a stale stream finish, determines whether to continue. Three failed gateway health checks also stop the child. Explicit
selection is available with `--resume SESSION_ID`. Finished tasks are not woken.
Eight identical consecutive tool operations or three identical failures block
work. No durable session progress for eight hours terminates the owned child
(configurable with `--stall-seconds`; long local prefill is allowed).

An interrupted `checkpointing`/`compacting` transaction or `blocked` state requires
reconciliation: inspect `watchdog/checkpoints/ID/{receipt,completed}.json`, native
session compaction brackets, the retained notes and worktree. Restore or verify
the native session using its supported persistence loader, verify the summary
and notes, then explicitly repair the affected session's phase in state.json.
Never delete state, invent a completed receipt, or blindly replay tools. Ambiguous
transactions intentionally stop rather than risking lost work or two summaries.

## Verification and benchmark

```sh
mkdir -p .tmp .cache
TMPDIR="$PWD/.tmp" XDG_CACHE_HOME="$PWD/.cache" node --test tools/dsh-watchdog/tests/*.test.mjs
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/dsh-watchdog/tests -p 'test_*.py'
```

Tests use **installed Cordis, LLM stream/error hooks, token meter, session store
and native compaction transactions** with deterministic summarization; persistence
fixtures are simulated. They cover 74K→75K, one reduction, late admission and
request rebuild, failed summary, missing meter, durable state reload, conflicting
notes, overflow, repeated tools and continuation. They do not claim an actual
model completion, power-loss injection or full TUI process recovery test.

Recorded results and limitations: `audit/reviews/dsh-watchdog-20261017/`.
For real tasks compare correctness (required tests and scientific decisions),
repeated tool signatures, compaction count, before/after envelope tokens, recorded
firstDeltaMs (includes network/prefill; not pure prefill latency), requestMs,
and resumptions. A live per-model benchmark remains pending; no measured speed
or completion score is inferred from mocked tests.

Contracts inspected: installed package JS/types, and upstream
[compaction policy](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/compaction-basic/README.md)
and [compaction service](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/compaction.md).
