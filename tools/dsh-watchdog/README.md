**Continuous autonomy:** No elapsed-time timeout at any stage of autonomous work. Follow
`.agent/continuous-autonomy.md` and `.agent/protocol.md`; older time/session/tool budgets
and timeout examples are superseded. Poll limits yield control; preserve and resume work.

# DeepSeek Harness watchdog

Native code mode is now enabled beside ordinary tools for every catalog model in
`dsh-tui`, `dsh-tui-safe` and `headless`. It uses the installed harness's `run_code`
transport and managed TypeScript runtime, with the existing permissions, sandbox,
memory/output limits and explicit cancellation. `code-mode.mjs` supplies the native
`timeoutMs: null` setting so execution has no elapsed deadline. No extra model or
generation server is needed. Restart a running harness to load changed plugins.

Call `run_code` with `description` and `code` (an async function body). Inside,
call the actual `tools.name(args)` declarations supplied in the system prompt.
Batch independent reads with `await Promise.allSettled([...])`, inspect failures,
and return only useful results. Sequence mutations and dependent steps. A codemod
is a source transformation and can be performed through the existing edit/shell
tools; it is distinct from code mode's tool orchestration.

Global deployment for installed **dsh 0.2.0-rc.2** and its three current profiles:
**dsh-tui**, **dsh-tui-safe**, and **headless**. All four current local models are
configured: Qwen Flash Next Q8, Qwen3.8 27B BF16, GLM 5.3 Flash 6-bit, and GLM 5.3
Flash mixed 4/8-bit. Other harnesses are untouched.

**Installed globally: use your normal `dsh`, `dst`, or `dsh-tui` command.**
Launchers now start the external supervisor automatically. The model configuration
generator reapplies the policy on startup, including newly catalogued supported
local models. All installed profiles receive one engine, bounded outputs, and
injected context-hygiene rules through `ctx.systemPrompt.section`.

Global installed code lives under `~/.local/share/deepseek-harness/tool-env/watchdog`.
Each future workspace gets independent **`.dsh-watchdog/`** notes, state, sessions,
checkpoints, caches and diagnostics. Instructions name that workspace's absolute
notes directory. No per-project AGENTS.md edit is needed. Add `.dsh-watchdog/` to
your project's ignore rules if desired; checkpointing always excludes its own
state directory. Existing historical sessions are preserved in their original
locations; they are not silently migrated into new workspace stores.

To reinstall the reviewed source after an intentional change:

```sh
node tools/dsh-watchdog/install-global.mjs
```

This explicitly updates the installed dsh/dst wrappers, configuration generator,
and profile patches. Original files and deployment receipt are retained privately
inside this repository under `watchdog/global-backup/` and
`watchdog/global-install-receipt.json`. Upstream harness core is unchanged. Unknown
dsh versions stop ordinary supervised work until contracts are revalidated.

The earlier optional repository-isolated deployment remains available with
`setup.mjs` and `launch.py`; its notes directory is `watchdog/`, and its local TUI
copy redirects preferences into that directory. The global installation uses the
normal installed TUI and preferences. The global launcher owns the existing
session-managed model gateway; the isolated launcher requires a ready gateway.
Live 131,072-token capacity and per-model coding correctness remain unverified.

## Policy

Each routed model advertises W=131072 and O=32768, with B=8192,
thresholdRatio=75000/131072=0.57220458984375 and summary maxTokens=4096:
`floor(min(W*ratio, W-O-B)) = 75000`. A larger request output reservation is
rejected. One root Cordis `BasicCompactionEngine` subclass serves every preset;
other summary engines, manual compact commands and image compaction are disabled.
A single native-derived replay-safe result pruner runs before every step, without
a model call. Results over 2048 Unicode codepoints retain a 768-codepoint head,
384-codepoint tail and a full-output retrieval pointer. Original session entries,
error metadata and call pairing remain intact. Newly injected tool output spills
above 1200 estimated tokens and keeps its complete file. Retrieval must still be targeted.

The supported token meter measures **current routed envelope pressure**, never
lifetime usage. Its `baseline.kind` is recorded. **This installed meter uses a
heuristic until matching provider usage exists; 75,000 meter tokens cannot be
claimed to equal exactly 75,000 tokenizer tokens.** System prompt, tool schemas,
images and current surface participate in native measurement. Before every pre-step, deterministic output hygiene runs and flushes replacements
to session storage; it makes no summary request. A pre-step check then
handles existing pressure, and an `llm/stream` gate catches newly admitted input
before network dispatch. `WATCHDOG_BOUNDARY` uses the native request-error/retry
contract to compact and rebuild; it is separate from real provider overflow.

At the boundary, native persistence must flush successfully. Checkpoints include
original session files, tracked binary Git diff (including an unborn-repository path), untracked file contents,
verbatim notes and a receipt. Non-Git workspaces receive a source snapshot excluding dependency/cache directories; no Git repository is required. Contents and directories are fsynced before
compaction. Native balanced selection, bracket locking and shrink checks remain authoritative.
Partial commit failures block for reconciliation; automatic rollback is not assumed. Exactly one summary attempt is allowed; failed or
insufficient compaction blocks work. A recent 12,000-token tail is retained.
Only confirmed `CONTEXT_WINDOW_EXCEEDED` permits emergency compaction below 75K,
once per consecutive failure episode. Successful assistant output resets it.

Update `progress.md`, `decisions.md` and `issues.md` in the configured notes directory before major work or
tests. Notes (maximum 24KB) are copied **verbatim** into the candidate summary with
verified facts distinguished from unresolved hypotheses;
a summary is never trusted to preserve scientific decisions through paraphrase.
Notes changing during summarization, empty/truncated summaries, or `CONFLICT:`
decisions block the transaction. Original JSONL and checkpoints are never rotated
away. Supervisor diagnostics rotate through four 4MB files. The supervisor never
compacts or submits the original task a second time.

## Recovery

`<notes-directory>/state.json` is independent of the dsh process and includes the current
session, request tokens, measurement baseline, checkpoint, compaction counts,
errors and timings. Missing/corrupt state with existing sessions is an error,
never an invitation to initialize an empty session.

Clean restart selects the recorded current session automatically; an interrupted
running task receives a continuation through supported `agent/created` and
`agent.followup`, instructing it to reconcile interrupted actions before acting.
Unexpected child exit permits at most two persistent process restarts. Active-turn state, rather than a stale stream finish, determines whether to continue. Three failed gateway health checks also stop the child. The optional isolated launcher also accepts `--resume SESSION_ID`. Finished tasks are not woken.
The installed headless runner always submits its CLI task after loading. To prevent replaying that task, **automatic headless process restart/continuation is disabled**; its compaction and checkpoint rules remain active, and recovery is explicit through the native headless session controls. Eight identical consecutive tool operations or three identical failures block
work. No durable session progress for eight hours terminates the owned child
(configurable with `--stall-seconds`; long local prefill is allowed).

An interrupted `checkpointing`/`compacting` transaction or `blocked` state requires
reconciliation: inspect `<notes-directory>/checkpoints/ID/{receipt,completed}.json`, native
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


## Continuous hygiene and the video strategy

The requested IBM video captions were retrieved and reviewed; source notes and
implementation mapping are in `audit/reviews/dsh-rc1-production-20261017/video-strategies.md`.
Before each step the pruner scans the current tool-result surface. It rewrites
only over-budget text; subsequent passes leave already bounded results unchanged.
Full originals stay in JSONL, with a durable `hygiene-index.jsonl` mapping session
ID, tool-call ID, original sequence and replacement sequence for retrieval. Source
code/user messages and decisions are not blindly shortened, and tool calls are
never removed without their paired results. The existing 75K summary gate is
measured after cleanup; late cleanup triggers a request rebuild if necessary.

The watchdog records `hygienePrunes`, `hygieneCharsRemoved`, `requestTools`, and
`toolSchemaBytes`. Missing pruning, metering or persistence prevents request
admission. A partial prune or flush failure persists a blocked phase. This is
output budgeting, not a semantic determination that every omitted line is
unnecessary: models must retrieve omitted diagnostics before drawing conclusions.
Tool-set curation and evidence validation are explicit global instructions;
the implementation does not silently remove capabilities or pretend to prove
arbitrary claims. Current notes retire superseded assumptions into archives.
