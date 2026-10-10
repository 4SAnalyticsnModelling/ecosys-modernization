# Cycle {{CYCLE_ID}} — {{DATE}}

- **Actor**: single autonomous agent (harness/model: ______) — owns plan, work, decisions and final review
- **Verification**: gates G1–G9 + fresh-context read-only sub-agents (no judge, no ruling)
- **Frontier at start** (`.agent/frontier.json`): sim hour ______ / verified ______ / failure hour ______
- **Status**: PLANNING (→ WORKING → VERIFYING → DECIDED → PUSHED)

## 0. Plan
- **Target source** (frontier / plan / `.agent/backlog.md` / previous cycle §4):
- **Target** (one bounded, falsifiable question):
- **Hypotheses** (ranked, each with the check that kills it):
- **Legacy ranges to read** (`f77src/<file>.f:<lines>` via `f77query.py`):
- **Done condition** (the number or behaviour that ends this cycle):
- **Sub-agents planned** (none / verifier / diagnose / legacy-oracle / parity-sweep):

## 1. Work
- **Subsystem & problem**:
- **Legacy ground truth** (`f77src/<file>.f:<lines>` + what it actually does):
- **Zig change** (`ecosys-ng/src/<file>.zig:<lines>`):
- **Commands run** (all heavy ones through `run_logged.py`; logs on disk, not here; repo-local caches exported;
  `preflight.py --command` vetted anything with paths you did not choose):
- **Dead ends** (what was tried and rejected, and why — this saves the next session days):

## 2. Evidence & self-check
| Gate | Result | Evidence (receipt path / `file:line` / command) |
| --- | --- | --- |
| G1 build (Debug + ReleaseSafe, **Zig 0.17.x** — record `zig version`) |  |  |
| G2 regressions |  |  |
| G3 conservation (water, heat, C, N, P close) |  |  |
| G4 traceability + floor parity |  |  |
| G5 output parity vs legacy oracle |  |  |
| G6 no forbidden diff (scan + justification of every flag) |  |  |
| G7 independent verification (required for science/solver/DEV/architecture) |  |  |
| G8 pushed (`origin/main` == `HEAD`) |  |  |
| G9 contained workspace (caches, scratch, run output, logs all inside the repo) |  |  |

- **Metrics** (`cycle_runner.py metrics --set …`): frontier hour, iterations/h, substep cuts, S9 hours, max residual, throughput, wall s/day:
- **Ledgers updated** (`state.md`, `backlog.md`, `audit/unresolved-gaps.md`, `output-provenance.csv`, `science-invariants.md`, `intentional-deviations.md`):
- **Not run / failed / unknown** (say it plainly):

## 3. Independent verification (G7)
- **Why required here** (which change touches science / solver / bounds / acceptance / restart / output / DEV / architecture):
- **Brief used**: `.agent/briefs/verifier.md` — context given: diff + cited legacy ranges + receipts + gate list only
- **Verdicts** (pointer citations, not pasted reports):
- **Reproduced FAILs and their resolution** (fix / revert; a reproduced FAIL is never argued away):

## 4. Decisions & record
- **Decisions taken** (mechanism, evidence, numbers, parity impact, retirement plan; DEV-NNN registered the same cycle):
- **Playbook lesson** (one line appended to `.agent/playbooks/convergence-and-balance.md`, if this cycle taught one):
- **Revert record** (if the diff was reverted: what was learned, what the negative result rules out):

## 5. Commit & push (mandatory — the cycle is not closed until this is green)
```
git add -A && git commit -m "cycle {{CYCLE_ID}}: <what + why>"
./sync-main.sh push
git rev-parse HEAD origin/main     # the two shas must match
```
- **Commit / push result**:
- **Unpushed reason** (only for network/auth; `sync_status: PENDING` in `cycle.json`, retried next cycle start):

## 6. Next
- **Next target** (one bounded, falsifiable question, with the first command to run):
- **Blockers** (exact condition that clears each; mirrored into `.agent/backlog.md`):
