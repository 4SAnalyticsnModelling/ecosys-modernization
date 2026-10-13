---
name: ecosys-autonomous-orchestration
description: "Run the ecosys-ng audit as one autonomous agent that owns the whole loop in cycles (plan -> work -> evidence/self-check -> independent verification -> decide & record -> commit & push -> next cycle) decided by objective gates G1-G9 on the pinned Zig 0.17.x toolchain with every byte of work contained inside the repository, optionally fanning out a swarm of read-only sub-agents (verifier, diagnose, legacy-oracle, parity-sweep) without conflicting edits or duplicate full runs. Use for cycle planning, independent verification, parallel diagnosis, parity sweeps and cross-harness pickups."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and record a bounded next action in the cycle ledger.

# One agent, the whole loop, verified by gates

## The actor
One autonomous agent owns the entire project: it plans, investigates legacy Fortran, implements Zig, builds, tests, runs, diagnoses, decides, keeps the ledgers and reviews its own work against objective gates. Any harness or model may pick the project up; no agent name is required. The protocol of record is `.agent/protocol.md`; mission and gate config is `.agent/mission.json`; the current cycle ledger is `.agent/cycle.json` and the human-readable state is `.agent/state.md`. Authority is never delegated away: sub-agents are a tool, not co-owners. The agent is the single accountable author of every change, and no second model's agreement is required before acting.

## The cycle
Work proceeds cycle after cycle until the finish line (F1-F7 in `.agent/protocol.md`) is met: **plan -> work -> evidence & self-check -> independent verification -> decide & record -> commit & push -> next cycle**. One bounded, falsifiable target per cycle; a renamed repeat of a closed question is a new falsifiable target or nothing. Keep cycle records short and pointer-cited (`file:line`, short sha, `receipt.json` path). A cycle that fails its own gates is fixed or reverted (`git restore`/`git revert`) with the negative result recorded; a recorded negative result is progress, a broken `main` is not. Continue without waiting for approval at any step; stop only for a genuine blocker and record it in `.agent/backlog.md` with the exact condition that clears it.

## Gates decide, not opinions
Record PASS/FAIL/N-A with evidence each cycle: **G1** build clean (Debug + ReleaseSafe) **with Zig 0.17.x — a 0.16 build is not current evidence**; **G2** regressions (`zig build test`, pytest) with a discriminating test per fix; **G3** water/heat/C/N/P conservation ledgers close at every accepted hour; **G4** legacy traceability (`f77src/<file>.f:<line>`, floor parity in value, scale, operator, units, placement); **G5** output parity against the legacy oracle with units and time semantics; **G6** no forbidden diff (no tolerance loosening, post-solve clamps, unregistered DEV-NNN, ceiling raises, silent retries); **G7** independent re-derivation by a fresh-context verifier sub-agent; **G8** the cycle is committed and pushed; **G9** every input and output of the cycle (caches, temp files, checkpoints, run output, logs) stayed inside the repository root (`.tmp/`, `.cache/`, `.uv-cache/`, `ecosys-ng/.zig-cache-global/`, `audit/runs/`) — nothing a later cycle needs may live outside A reproduced verifier FAIL is fixed or reverted, never argued: re-run the gate yourself, and if it reproduces the change is wrong. Consensus is never evidence; a reproduced number is.

## Toolchain and workspace containment (both mandatory)
`ecosys-ng` builds, tests and measures with **Zig 0.17.x** (`.agent/toolchain.json`; `ecosys-ng/build.zig.zon minimum_zig_version = "0.17.0"`; migration work order `.agent/migrations/zig-0.17.md`). Record `zig version` in build/test receipts and check the pin with `uv run ecosys-audit/scripts/preflight.py` at cycle start. Every command runs with repo-local caches (`TMPDIR=$PWD/.tmp`, `XDG_CACHE_HOME=$PWD/.cache`, `UV_CACHE_DIR=$PWD/.uv-cache`, `ZIG_GLOBAL_CACHE_DIR=$PWD/ecosys-ng/.zig-cache-global`, `zig build|test --cache-dir .zig-cache` — Zig 0.17 rejects `--global-cache-dir` on `zig build` (measured 2026-10-12), so the global cache moves by the env var only) and writes evidence into `audit/runs/` through `run_logged.py`: no `/tmp`, no `$HOME`, no second checkout, no external drive, no cloud (`preflight.py --command "<cmd>"` vets an unfamiliar one).

## Mandatory commit and push
`./sync-main.sh pull` at cycle start. Every completed cycle: `git commit`, then `./sync-main.sh push`, then verify `git rev-parse HEAD origin/main` shows the same sha. A cycle is not closed until `main` is on GitHub (G8). Never force-push, never rewrite history, never commit ignored run artifacts, never leave `main` broken.

## Swarm of sub-agents on demand
A swarm is optional and never an approval queue. Spawn fresh-context **read-only** sub-agents from the bounded briefs in `.agent/briefs/`: `verifier` (independent re-derivation for G7), `diagnose` (parallel hypotheses), `legacy-oracle` (matched-state Fortran expectation for a routine), `parity-sweep` (output comparison while you work on something else). G7 verification is required for any change touching science, solver behaviour, architecture, a DEV or a hard solver rung.

- **Bounded briefs.** Each brief names scope IDs, the exact inputs (diff, cited legacy ranges via `f77query.py`, receipts), the required output format, a resource budget and a done condition. For a verifier give only the diff, the cited legacy ranges, the receipts and the gate list - never your conclusion or hypothesis; fresh context is the point.
- **No conflicting writes.** Sub-agents never edit, commit, push or start full runs; read-only review may run in parallel (typically 1-3 per batch). Quote verdicts by pointer, do not paste them. No concurrent ledger edits: `.agent/state.md` and `.agent/cycle.json` have exactly one author - you.
- **No duplicate full runs.** Expensive compiles and full-deck runs are agent-owned and normally serialized; a parity sweep may observe existing runs, never launch a second identical one.
- **Honest reporting.** Report PASS, FAIL, STAGNATED or BLOCKED as measured. Never convert `BLOCKED` to `PASS` to maintain momentum, and do not count the same agent under a new name as independent approval.

## Shared evidence and integration order
Write evidence under `audit/` with paths and hashes; pass pointers plus short findings, not pasted reports or terminal transcripts - artifact-first. Use `run_logged.py` for any verbose command so full logs stay on disk. Integrate one coherent change set at a time, check for shared state/interface conflicts, rerun the affected tests, and update the candidate manifest; merge order matters for numerical/state changes. A sub-agent's scoped success is not integrated success: final production, output and performance evidence must concern the same integrated candidate.

## Token and resource frugality
Read the target plus one brief and the `f77query`/`rg` hits you need - never whole `.f` or Zig files or logs. Record actual available RAM and cap concurrent sub-agents, builds and runs accordingly; compiles and simulation runs compete for the same cores and memory. After three distinct unsuccessful experiments on one issue, get a fresh diagnosis (a `diagnose` sub-agent) and reduce the problem instead of repeating an expensive failure with the same signature.

## Done
A cycle is done when its gates are recorded with evidence, required G7 verification passed, the decisions and ledgers are updated, and the commit is pushed with `origin/main` == `HEAD`. The project is done only at F1-F7 of `.agent/protocol.md`. No overlapping untracked edits, orphan runs or unverified "all checks passed" claims remain.
