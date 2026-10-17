## Continuous autonomous work — 2026-10-17 directive

Autonomous work has **no elapsed-time timeout** at any stage: planning, investigation,
agent/sub-agent turns, builds, tests, diagnostics, verification, simulations, commits or sync.
Continue until the assigned objective is verified or an actual error or human-only blocker
requires action; time elapsed, silence, token usage, tool-call counts and session age are
never reasons to terminate work. Do not wrap work in `timeout`, set finite execution
deadlines, or interrupt a healthy process because a budget expires.

Keep long commands detached with repo-local logs, receipts, process identity and checkpoints.
A tool wait/poll limit yields control only: reattach and continue observing the same process.
Context compaction or unavoidable harness interruption requires durable notes and automatic
pickup of unfinished work; it does not complete or cancel the task. Watchdogs preserve and
recover work. Health probes may time out individual observations and retry without killing
work; explicit shutdown cleanup may be bounded after a genuine stop decision. Scientific
iteration bounds, conservation gates, memory/concurrency limits and finite simulated test
windows remain in force. Diagnose repeated failures and change approach without halting the
mission. Never infer process death from heartbeat age alone; check process identity/liveness.

This directive supersedes older time/session/tool budgets and timeout examples throughout
the repository, including retired role cards, plans and archived workflows. Historical
receipts remain unchanged and do not authorize new timeouts. Authority: `.agent/protocol.md`.

# ecosys-ng Ottawa Completion Protocol — One Autonomous Agent

Version: 1.2 (2026-10-17). Supersedes every worker/judge ("adversarial") workflow document in this repository.
This file is the **single source of protocol truth**. `AGENTS.md`, `.agent/README.md`, `.agent/mission.json`,
the skills and both Ottawa plans all describe the same loop; if they ever disagree, this file wins.

**v1.1 adds two hard mandates:** (a) `ecosys-ng` is built, tested and measured with **Zig 0.17.x — never 0.16**
(§8, gate **G1**); (b) **all work stays inside this repository** — every read, write, build, test, run, cache,
checkpoint and log (§8a, gate **G9**). The Zig 0.17 migration of the source tree is *unstarted* and is the first
cycle's work: see `.agent/migrations/zig-0.17.md`.

---

## 1. Mission and finish line

**Goal**: a complete, verified **30-year Ottawa run** (262,920 hours) of `ecosys-ng` (Zig, `ecosys-ng/src/`) with
**zero science gap** against the legacy Fortran reference (`f77src/`, read-only) and **scientifically comparable
outputs** against the legacy Ottawa baseline.

**Finish line** (all true, with evidence, or the work is not done):

| ID | Condition | Evidence |
| --- | --- | --- |
| F1 | One strict campaign runs hour 0 → 262,920 to completion on a single recorded binding, built with **Zig 0.17.x** and produced entirely inside this repository | `audit/runs/<run>/` receipts + `.agent/frontier.json` (`verified_frontier = 262920`) |
| F2 | Every mass/energy/nutrient ledger closes at every accepted hour (water, heat, C, N, P) | conservation audit report per the `ecosys-conservation-audit` skill |
| F3 | Legacy↔Zig parity on every production output file, row and column, with units and time semantics verified | `ecosys-output-comparison` report |
| F4 | Source traceability: every Fortran logical statement mapped, no unexplained gap | `ecosys-fortran-zig-traceability` coverage report |
| F5 | No open DEV-NNN without an approved, evidence-backed decision record; debt DEVs retired or justified as scientifically equivalent | `audit/intentional-deviations.md` |
| F6 | Release verification pass (build reproducibility, restart integrity, performance) | `ecosys-release-verification` decision |
| F7 | Final cycle committed and pushed; `origin/main` == local `main` | `git status -sb`, `git log -1 --oneline origin/main` |

There is no partial-completion state and no artificial stopping gate. Work proceeds cycle after cycle until F1–F7.

## 2. The actor: one agent, any model, optional swarm

- **One agent owns everything**: plans, investigates, implements Zig, builds, tests, runs, diagnoses, decides,
  keeps the ledgers, and does the final scientific review of its own cycle against the gates in §4.
- **Any harness or model may pick this project up** — Claude Code, DeepSeek Harness (`dsh`), Codex CLI, OpenCode,
  Pi, a local model. The agent has **no required name**; `ECOSYS-ONE` is an optional label. Nothing in this
  protocol may depend on a specific model, pane label, or second opinion process.
- **A swarm of sub-agents is a tool, not a co-owner.** The agent may fan out read-only analysts, auditors and
  verifiers (§5, §9) to save wall-clock time and to get uncontaminated checks. Sub-agents never commit, never
  push, never edit files, and never hold authority the parent agent then delegates away. The parent agent is the
  single accountable author of every change.
- **No role split, no escalation queue, no ruling, no judge, no poke.** Historical files describing those
  (`.agent/adversarial/`, `.agent/roles/claude.md|deepseek.md`, `.agent/pokes/`) are archived history: read them
  for the science record, never for authority.

## 3. Cycle — the unit of work

A **cycle** (former name: "round") is one bounded, falsifiable step toward the frontier. Cycle files live in
`.agent/cycles/cycle_NNNNN.md` from `.agent/templates/cycle.md`. Ledger: `.agent/cycle.json`
(maintained by `ecosys-audit/scripts/cycle_runner.py`).

| § | Step | Output | Status |
| --- | --- | --- | --- |
| 0 | **Pick up / sync / plan** — read §10 pickup ritual; `./sync-main.sh pull`; choose the target from the frontier, the plan, or the open-gaps list; write one falsifiable target, hypotheses, legacy ranges, done condition | plan block | `PLANNING` |
| 1 | **Work** — read legacy ranges (`f77query.py`), implement Zig, build, run tests and bounded runs; all heavy commands through `run_logged.py`, every command run from this repo root, on **Zig 0.17.x** (§8), with repo-local caches (§8a) | diff + receipts | `WORKING` |
| 2 | **Evidence & self-check** — gate table G1–G6 with `file:line` and `receipt.json` citations; state plainly what was not run | gate table | `VERIFYING` |
| 3 | **Independent verification** — for any change that touches science, solver behaviour, architecture, a DEV, or a hard solver rung: at least one **fresh-context verifier sub-agent** re-derives the decisive gates from the diff + legacy lines + receipts only (§5) | `VERDICT: PASS/FAIL` per gate | `VERIFYING` |
| 4 | **Decide & record** — record decisions (DEV-NNN, architecture, legacy-inconsistency) with reasons and evidence; update `audit/` ledgers, `.agent/state.md`, `.agent/backlog.md` | decision log | `DECIDED` |
| 5 | **Commit & push (mandatory)** — commit the verified cycle and push to `origin/main`; verify `origin/main` == `HEAD` (§7) | commit sha + push proof | `PUSHED` |
| 6 | **Close & continue** — append metrics, name the next target, open the next cycle. No human prompt needed | next target | `PLANNING` (next) |

Rules:
- One bounded question per cycle. A renamed repeat of a closed question is a new, falsifiable target or nothing.
- A cycle that fails its own gates does **not** get committed as-is: fix it, or revert the diff
  (`git restore`/`git revert`), record what was learned and why it failed, then continue. A recorded negative
  result is progress; a broken `main` is not.
- Cycle reports stay ≤ 500 words, pointer-cited (`file:line`, short sha, `receipt.json` path).
- Cycles are numbered continuously; `cycle_runner.py open` does it.

## 4. Evidence gates (what replaces the judge)

Correctness is decided by **objective, reproducible checks**, not by an opinion. Every cycle records each gate as
PASS / FAIL / N-A with evidence.

| Gate | Check | How |
| --- | --- | --- |
| G1 | **Build**: touched code compiles clean in Debug + ReleaseSafe **with Zig 0.17.x** — a 0.16 build is not current evidence; production runs use ReleaseFast | `preflight.py` (pin) + `zig build` in `ecosys-ng/` with repo-local caches, logs on disk |
| G2 | **Regressions**: unit/layered tests pass; a new discriminating test accompanies each fix | `zig build test`, `uv run pytest ecosys-audit/tests -q` |
| G3 | **Conservation**: local + global water, heat, C, N, P ledgers close at every accepted hour; no unclosed ledger is published | conservation tooling / per-hour ledger diff |
| G4 | **Traceability**: every physics change cites legacy `f77src/<file>.f:<line>`; each touched guard matches the legacy floor in value, scale, operator, units and placement (§6) | diff ↔ legacy map in the cycle file |
| G5 | **Parity**: affected production outputs compared against the legacy oracle with units and time semantics | `ecosys-output-comparison` / comparison scripts |
| G6 | **No forbidden diff**: scan the diff for tolerance loosening, post-solve clamps, unregistered DEVs, silent retries, `unreachable`, ceiling raises | `cycle_runner.py gates` + `bindcheck.py` where relevant |
| G7 | **Independent re-derivation** (§5) | verifier sub-agent verdicts |
| G8 | **Sync**: cycle committed and pushed; `origin/main` == `HEAD` | `./sync-main.sh status`, `git rev-parse HEAD origin/main` |
| G9 | **Containment**: every input and output of this cycle's commands (sources, caches, temp files, checkpoints, run output, logs) stayed inside the repository root | `preflight.py --command` before running; receipt `cwd` + argv paths (§8a) |

A cycle is *committed* only when G1–G6, G9 and (where required) G7 are PASS and G8 completes. `cycle_runner.py close`
runs the automatable part (G1/G2/G6/G8) and refuses to close a cycle whose recorded gates are missing; `preflight.py`
covers the toolchain half of G1 and all of G9 — cite its output in the cycle file.

## 5. Independent verification instead of an adversarial judge

Self-review is weak exactly where this project fails: subtle Fortran→Zig semantics and solver acceptance. So the
agent **adversarially checks itself with fresh context, in parallel**, using sub-agents:

- **When required (G7)**: any change to process equations/parameters, solver formulation, bounds/floors,
  acceptance/rollback logic, restart or output semantics; any architecture decision; any DEV; any hard rung
  (S4, S5, S8, S9 in the playbook).
- **How**: spawn 1–3 sub-agents in one batch with the brief `.agent/briefs/verifier.md`. Give each only: the diff,
  the cited legacy ranges (via `f77query.py`), the receipts, the gate list, and the prohibition list. Ask for
  per-gate PASS/FAIL with `file:line`, plus the smallest reproducer for any FAIL. Do **not** tell it your
  conclusion or your hypothesis — that is the point of fresh context.
- **Resolution**: a FAIL is not an opinion to debate; re-run the gate yourself. If it reproduces, the change is
  wrong: fix or revert. If it does not reproduce, record the discrepancy and the evidence that settles it.
  Consensus is never evidence; a reproduced number is.
- **Also valuable**: `diagnose` (parallel hypotheses), `legacy-oracle` (matched-state Fortran expectation for a
  routine), `parity-sweep` (output comparison while you fix something else). See `.agent/briefs/`.
- Sub-agents run read-only, write nothing, and their verdicts are quoted, not pasted (pointer citations).

## 6. Decisions the agent makes alone (and how it earns them)

The retired workflow gave these to a second model. They now belong to the agent, and the discipline replaces the
judge:

1. **Intentional deviation (DEV-NNN)** — allowed only when: the legacy behaviour is reproduced as a written
   mechanism (quoted `file:line`), the Zig change is minimal, the ledgers close, parity impact is measured, and
   `audit/intentional-deviations.md` records the mechanism, the numbers, the affected outputs, and the retirement
   plan. Register the DEV in the same cycle as the change, or the change does not ship.
2. **"Legacy is inconsistent"** — you must first prove it: two legacy `file:line` locations, the state where they
   disagree, and a matched-state oracle run or hand computation. Then choose the reading that conserves mass and
   energy, and record it as a DEV.
3. **Architecture (solver design, module boundaries, state ownership)** — write a short design note in the cycle
   file first, have a verifier sub-agent attack it, then implement. Refactors that change numbers need parity
   evidence, not "tests pass".
4. **Tolerances, ceilings, clamps** — never to make a failure go away. A ceiling may only be justified from a
   legacy structure (e.g. legacy's fixed sub-cycle count), stated in the cycle file, and flagged in the diff scan.

**Convergence and balance failures**: follow `.agent/playbooks/convergence-and-balance.md`; it is now the agent's
own ladder, not a supervisor's. Bugs before numerics: **science, translation, binding, duplication, floor bounds**
— PASS/FAIL each with `file:line` on every routine touching the failing hour, then triage (diagnostic packet,
ReleaseSafe/Debug replay, finite-difference Jacobian, class A–E), then rungs S1→S9 in order. Legacy never iterates;
the legacy trajectory is the oracle, and an hour solved by S9 (legacy explicit sub-cycling) is counted as debt to
drive to zero.

**Floor-bound detail (the classic trap)**: floors are `0.0`; `ZERO`=1e-15; `ZERO2`=1e-6; area-scaled
`ZEROS`/`ZEROS2`=`ZERO*DH*DV` / `ZERO2*DH*DV`; plant-population-scaled `ZEROP`/`ZEROQ`/`ZEROP2` recomputed daily
from PP; routine-local `ZEROC` = 1e-32 in SOLUTE but 1e-48 in STARTE. At Ottawa the cell area is 1 m², so a
hard-coded `1e-15` matching `ZEROS` is a coincidence, not parity — map each guard on the failing path to its legacy
line. `AMAX1(ZERO,X)` is not `IF(X.GT.ZERO)`.

**Hard prohibitions (unchanged, no exception path exists)**: loosening tolerances or raising ceilings to pass;
post-solve clamps; publishing a non-converged state whose ledger does not close; new "publish best-bounded"
deviations (DEV-009/011/014/015 family is debt to retire); silent retries; faking or extrapolating evidence;
editing `f77src/`, `f77example/`, `ecosys-ng-prod-examples/`.

## 7. Git sync: every completed cycle lands on GitHub `main`

The user requires local and online to stay in sync so no work is ever lost. The helper is `./sync-main.sh`
(`status` | `pull` | `push`); plain git works too.

**Cycle start**: `./sync-main.sh pull` (rebase) so work begins on GitHub's `main`.

**Cycle end (§5 of the cycle) — mandatory, every cycle without exception:**

```bash
git add -A
git commit -m "cycle NNNNN: <one-line what + why>"   # evidence lives in .agent/cycles/
./sync-main.sh push                                  # rebase onto origin/main, then push
git rev-parse HEAD origin/main                       # both lines must be the same sha
```

- Never commit run artifacts that `.gitignore` excludes; staged junk is a gate failure.
- If the working tree contains unrelated user edits, commit only your paths (explicit `git add <paths>`), and say
  so in the cycle file.
- Push rejected (`fetch first`) → `./sync-main.sh push` again (it rebases). Non-trivial conflict →
  `git rebase --abort`, record the conflict in `.agent/backlog.md`, and resolve it as the first step of the next
  cycle. **Never** `push --force`, never rewrite pushed history.
- Push fails for network/auth → keep the commit, set `sync_status: PENDING` in `.agent/cycle.json`, note it in
  `state.md`, retry at the next cycle start, and do not stack more than one cycle of unpushed work.
- A cycle is not `PUSHED` (and therefore not closed) until `origin/main` matches `HEAD`.

## 8. Machine lanes and resources

- Production source: `ecosys-ng/src/`, `ecosys-ng/build.zig`. Evidence: `audit/`. Control plane: `.agent/`.
- Read-only: `f77src/`, `f77example/`, `ecosys-ng-prod-examples/`. Never edit a `.f` file; use
  `uv run ecosys-audit/scripts/f77query.py outline|show|grep` (units are up to 13,179 lines long).
- Fortran dialect facts: `-r8 -i4` (implicit reals are f64), arrays often 0-based and column-major, COMMON /
  EQUIVALENCE aliasing, SAVE/DATA persistence, arithmetic IF / GOTO flow, intrinsic precision.
- **Toolchain: Zig 0.17.x, everywhere, forever** (`.agent/toolchain.json`). `ecosys-ng` is compiled, tested
  and benchmarked only with Zig 0.17.x; `zig version` is printed into every build/test receipt. **Zig 0.16 is
  retired**: 0.16 receipts are dated history and can never close a current gate. `build.zig.zon` declares
  `.minimum_zig_version = "0.17.0"` and `audit/manifest/command_registry.json` pins 0.17.x. If a machine has
  only 0.16, install 0.17.x (prefer a repo-local `tools/zig/`, §8a) and record the blocker in
  `.agent/backlog.md` — building with 0.16 instead is not an option. The migration itself is one cycle of
  work: `.agent/migrations/zig-0.17.md`.
- The **legacy Fortran toolchain is separate and unchanged** (g77/gfortran-compatible, `-r8 -i4`, recorded in
  `audit/manifest/`); the Zig mandate applies to `ecosys-ng` only.
- Long full runs are **detached** (background job or `nohup`), with the log path recorded in `state.md`, so a
  session end never kills the campaign. Never start a second full run of the same case while one is live;
  sub-agents are forbidden from starting full runs — they analyze.
- **Runs are unbounded by default (2026-10-16 directive)**: a production run is started without `--timeout`
  and proceeds to natural completion — `COMPLETE` at the model's own terminal line, or `FAIL` at its first
  error — no matter how long that takes (days are expected). There is no wall-clock stop. Legacy
  `--timeout` arguments no longer impose execution limits; its `TIMED_OUT` receipt is never evidence and never a
  scientific result, and it can never close G5 or promote the frontier. The agent's job while a run is
  live is to keep working the rest of the campaign and monitor, not to stop or restart the run.
- Token frugality: heavy output to disk via `run_logged.py`, cite receipts; never paste logs or whole files into
  prompts, sub-agent briefs, or cycle files.

## 8a. Work containment: all work stays inside this repository (gate G9)

**Every piece of work happens inside this repository** — investigation, edits, builds, tests, simulation runs,
staging, downloads, extractions, caches, checkpoints, logs, scratch and evidence. The repository root is the
workspace and the sandbox: the agent must assume it has no writable place else, and must not use one anyway.
Nothing a later cycle would need to reproduce, re-check or cite may live outside the repo.

- **Run from inside the repo** (`repo root`, `ecosys-ng/`, a run directory). Before running any command whose
  paths you did not choose, vet it: `uv run ecosys-audit/scripts/preflight.py --command "<the command>"` FAILs if
  an argument resolves outside the root (`~`, `/tmp`, `/Volumes`, a sibling checkout, a parent `..`).
- **Pin every cache and temp directory inside the repo, per command** — each shell is fresh, so set them in the
  same command line (or in the wrapper you use), and `mkdir -p` first:

  ```bash
  mkdir -p .tmp .cache .uv-cache ecosys-ng/.zig-cache ecosys-ng/.zig-cache-global
  export TMPDIR="$PWD/.tmp" XDG_CACHE_HOME="$PWD/.cache" UV_CACHE_DIR="$PWD/.uv-cache" \
         ZIG_GLOBAL_CACHE_DIR="$PWD/ecosys-ng/.zig-cache-global"
  # zig build / zig test take: --cache-dir .zig-cache  (Zig 0.17 REJECTS --global-cache-dir on `zig build` —
  # measured 2026-10-12, audit/runs/zig017-pin017-debug-20261012. The global cache follows ZIG_GLOBAL_CACHE_DIR
  # above; `zig build` passes --global-cache-dir to the compiler itself. Verified: $HOME/.cache/zig untouched.)
  ```

  These directories are gitignored on purpose: they live **in** the repository and never enter Git.
- **Where each artifact goes**: scratch and one-off probes under `.tmp/<date-or-topic>/`; command logs and
  receipts under `audit/runs/…` via `run_logged.py` (it refuses paths outside `audit/runs`/`audit/reviews`);
  durable findings under `audit/issues/`, `audit/features/`, `evidence/manifest/`; simulation output, checkpoints
  and staged decks only in the run directory named by the deck/receipt. Never beside the sources, never in
  `f77src/`, `f77example/`, `ecosys-ng-prod-examples/`, never in `$HOME`.
- **No external destinations**: no `/tmp` or `$HOME` artifacts, no second checkout, no external or removable
  drive, no cloud storage, no paste/upload service for logs, decks or evidence, no `git worktree` outside the
  root, no "let me build over there instead". If a tool insists on an outside path, redirect it with a flag or an
  env var; if it cannot be redirected, record the exact tool and condition in `.agent/backlog.md` as a blocker and
  do not run it.
- **What may live outside, read-only**: the machine's installed toolchain and system libraries (zig, uv, python,
  a Fortran compiler) and `git fetch/pull/push` to `origin`. Reading a compiler is not work output; syncing `main`
  is the one required outbound channel. Prefer installing toolchains under `tools/` inside the repo when that is
  possible.
- **G9 evidence**: the cycle file lists where the cycle's commands wrote, and `preflight.py` output is cited. A
  build or test whose caches, temp files or logs landed outside the repository is a **FAIL even when it passed**.

## 9. Multi-month autonomy (this runs for months, unattended)

**Pickup ritual (any new session, any harness, ≤ 10 commands)**

```bash
./sync-main.sh pull                      # start from GitHub's main
uv run ecosys-audit/scripts/preflight.py # Zig 0.17.x pin, containment, sync, cycle status
sed -n 1,60p .agent/state.md             # current frontier, open issues, live run
cat .agent/cycle.json 2>/dev/null || echo 'no open cycle: cycle_runner.py open'
cat .agent/frontier.json                 # simulation frontier (authoritative hour)
git status -sb && git log --oneline -5   # tree state and last landings
```

`preflight.py` FAILs while the tree is not on the Zig 0.17 pin (the migration, `.agent/migrations/zig-0.17.md`,
is that cycle's work) and vets any command whose paths escape the repository (`--command "..."`).

Then: if `cycle.json` shows an open cycle, finish it; if it shows `PUSHED`, close and open the next; if a full run
is live, monitor/advance the frontier; if `main` is dirty, resolve that first (commit or revert, never leave it).

**Continuity rules**
- End every session by writing `state.md` (frontier, live run, open threads, next target) and pushing. Another
  agent — or a different model — must be able to continue with only the repo, the `audit/` ledgers and the
  `.agent/` ledgers. The conversation is disposable; the repository is the memory.
- **Loop breaker (self-applied)**: if the same command, edit or error repeats 3×, or you re-read the same files
  without a new finding, or edits oscillate: stop that approach, write down what you tried in the cycle file,
  spawn a fresh-context `diagnose` verifier with the loop description, and take the narrowest remaining step
  (a single `file:line`, a single failing hour, a single assertion). If the same target stalls twice in a row,
  split it into two cycles and record the split.
- **Context discipline**: long sessions drift. At high context use, commit + push, write `state.md`, and arrange automatic pickup in a
  fresh context without ending unfinished work. Keep the durable state in files, never in your head.
- **Backoff, not halt**: if genuinely blocked (missing baseline data, unavailable model server, hardware limit),
  record the blocker with the exact condition and the check that clears it in `.agent/backlog.md`, then work the
  next unblocked item. Only stop for real, human-only conditions (credentials, destructive operations, spending,
  or a decision the mission itself cannot imply) — and say so plainly in `state.md`.
- **Stale state recovery**: locks in `.agent/locks/` older than the live run → remove with a note; a `cycle.json`
  mid-status → reconcile with `git log` and the cycle file, record the reconciliation; a run whose process is gone
  → resume from its last checkpoint per the restart tooling.

**Metrics, every cycle** (append a row to `.agent/metrics.csv`): frontier hour, iterations/hour mean+max, substep
cuts, S9 fallback hours, max balance residual, hours/run-hour throughput, ReleaseFast wall time per simulated day,
DEV count, gate failures hit, sync status.

## 10. Live vs legacy files

| Live | Purpose |
| --- | --- |
| `AGENTS.md` (and `CLAUDE.md` pointer) | entry point for any agent |
| `.agent/protocol.md` | this protocol |
| `.agent/mission.json` | mission, gates, sync policy, budgets, lanes |
| `.agent/toolchain.json` | pinned toolchain (Zig 0.17.x) and the repo-local cache/scratch pins |
| `.agent/migrations/zig-0.17.md` | Zig 0.17 migration work order (unexecuted; first cycle) |
| `.agent/cycle.json` / `.agent/cycles/` | current cycle ledger / cycle records |
| `.agent/state.md` | human-readable current state (frontier, live run, next target) |
| `.agent/backlog.md` | ordered open threads, deferred work, blockers with clear conditions |
| `.agent/frontier.json` | authoritative simulation frontier |
| `.agent/playbooks/convergence-and-balance.md` | solver/balance ladder + Lessons (the agent's own) |
| `.agent/briefs/*.md` | sub-agent briefs (verifier, diagnose, legacy-oracle, parity-sweep) |
| `.agent/templates/cycle.md` | cycle record template |
| `.agent/metrics.csv` | per-cycle metrics |
| `audit/` | scientific evidence ledgers (gaps, provenance, invariants, deviations, reviews, runs) |

| Legacy (read-only history) | Was |
| --- | --- |
| `.agent/adversarial/` | worker/judge round records — the science record, no authority |
| `.agent/roster.json`, `.agent/workflow.json`, `.agent/dispatch.json`, `.agent/current_task.md` | retired swarm/judge ledgers |
| `.agent/roles/` | per-model role cards (was: one per persona) |
| `archive/pre-solo-workflow/` | retired launchers, runner, poke/round tooling |
| `ecosys-audit/scripts/swarm_wrapper.py` | optional Herdr peer-agent controller; not part of this protocol |
