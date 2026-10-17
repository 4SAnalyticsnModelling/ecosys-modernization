**Continuous autonomy:** No elapsed-time timeout at any stage of autonomous work. Follow
`.agent/continuous-autonomy.md` and `.agent/protocol.md`; older time/session/tool budgets
and timeout examples are superseded. Poll limits yield control; preserve and resume work.

# Sub-agent briefs (the optional swarm)

The project is run by **one** agent. These briefs are how it fans out when wall-clock time or self-blindness is the
limiting factor. A sub-agent is a temporary pair of hands with fresh context — never a co-owner, never an authority,
never a second model to wait for. Protocol: `.agent/protocol.md` §5, §9.

| Brief | Use it for | Mandatory? |
| --- | --- | --- |
| `verifier.md` | gate **G7**: independent re-derivation of the gates from diff + legacy + receipts only | **yes** for any science, solver, bounds, acceptance, restart/output-semantics, architecture or DEV change, and before a hard solver rung (S4/S5/S8/S9) |
| `diagnose.md` | a stuck hour, a divergence that survived two hypotheses, or any loop-breaker trigger | no, but cheap and usually worth it |
| `legacy-oracle.md` | the number/branch the Fortran produces for a given state, with owners and floors | no |
| `parity-sweep.md` | keeping legacy↔Zig comparability measured while the parent fixes something else | no |

## How to spawn (any harness)
- **Claude Code**: the `Task` tool, one brief per subagent, several in one message for parallelism.
- **DeepSeek Harness (`dsh`)**: the `subagent` / `subagent_fork` tools (use a plain `subagent` for fresh context —
  that is the point).
- **Codex CLI / OpenCode / Pi / anything else**: open a fresh session or a worktree copy, paste the brief plus its
  inputs, and treat its reply as an untrusted report.
- **No sub-agent capability available?** Do the same work sequentially in a fresh session (or after a context reset)
  and never claim a swarm ran. The value is the *fresh context*, not the parallelism.

## What the parent must hand over
The brief file, the diff, the cited legacy ranges, the receipt paths, the failing-hour packet if any, and the gate
list. **Do not hand over your hypothesis or your conclusion** for a `verifier` — that is what makes it independent.
Keep each brief under ~6k tokens: pointer citations, not pasted logs or files.

## Non-negotiable limits
- Read-only: sub-agents never edit files, never `git add/commit/push/checkout/reset`, and never decide a gate for
  themselves — they report evidence.
- **No full or long simulation runs** from a sub-agent: one campaign per case at a time, owned by the parent.
  Respect RAM: cap concurrent compiles; a local inference server and the build compete for the same machine.
- Never commit, quote or merge a sub-agent's code block into `main` without running the gates on it yourself.
- Record verdicts in the cycle file §3 as pointer citations. A reproduced FAIL means fix or revert — consensus is
  never evidence, and neither is disagreement.
