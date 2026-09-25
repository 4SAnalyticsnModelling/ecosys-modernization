# ecosys-ng Ottawa No-Science-Gap Autonomous Qualification System

## Mission

Design and implement the repository infrastructure, autonomous Herdr workflow, state system, validation workflow, agent roles, tools, hooks, logging, checkpointing, Git safety, and token-control architecture required to bring `ecosys-ng` to a scientifically defensible Ottawa qualification milestone.

The immediate project objective is:

> Complete the entire Ottawa ecosys-ng production run and demonstrate that ecosys-ng is scientifically comparable to the legacy gfortran implementation, without requiring bit-for-bit numerical identity.

The target is not merely:

> "ecosys-ng completes Ottawa."

The target is:

> "ecosys-ng completes Ottawa, all scientifically material legacy behaviour used by the Ottawa case is accounted for, every material discrepancy against gfortran is understood or justified, checkpoint/restart is trustworthy, conservation behaviour is defensible, and the accumulated evidence is sufficient to defend ecosys-ng scientifically."

Do not broaden this milestone into other climates, soils, platforms, packaging, UI work, or general production polishing unless directly required to qualify Ottawa.

---

# 1. Core principles

## 1.1 Repository is memory

The LLM conversations are disposable.

Persistent project knowledge belongs in:

```text
Git
.agent/
audit/
validation/
logs/
existing skill pack
source code
checkpoint files
```

No agent should depend on remembering a previous conversation.

A fresh session must be able to reconstruct everything relevant from the repository.

## 1.2 Fresh session by default

Use:

> One bounded task = one fresh agent session.

Do not maintain multi-day or multi-week Claude/OpenCode conversations.

Every worker session should:

1. read minimal state;
2. perform one narrowly scoped task;
3. produce a concise result;
4. exit.

## 1.3 Silent operation by default

Agents should not narrate routine work.

Do not output long explanations of:

- searches;
- file reads;
- shell commands;
- builds;
- test execution;
- internal investigation steps;
- routine decisions.

Agent-visible output should normally contain only:

```text
Result
Evidence
Changed files
Tests
Scientific impact
Remaining uncertainty
Recommended next action
```

Full logs belong on disk.

Do not preserve chain-of-thought or debugging diaries.

## 1.4 No random repair loop

The system must explicitly prevent:

```text
edit
→ full test
→ full production run
→ fail
→ edit
→ full test
→ production run
→ fail
→ repeat indefinitely
```

Instead use:

```text
failure
→ evidence
→ falsifiable hypothesis
→ targeted repair
→ targeted test
→ local replay
→ extended replay
→ verified frontier advancement
```

## 1.5 Full Ottawa run is a milestone test

Do not use the complete Ottawa simulation as the normal debugging mechanism.

A full run should occur only after lower-cost validation gates have passed.

## 1.6 Every source modification requires a hypothesis

Before modifying production scientific code, record:

```text
Defect hypothesis
Evidence
Expected effect of fix
What would falsify the hypothesis
```

A repair that does not produce the predicted result should be rejected or reverted.

Do not layer speculative fixes.

## 1.7 Farther execution is not scientific progress by itself

Track separately:

```text
simulation frontier
scientifically verified frontier
```

Example:

```text
Simulation reached:           hour 42,100
Scientifically verified:      hour 31,200
```

Only the scientifically verified frontier counts as qualification progress.

---

# 2. Four-agent Herdr system

Use four visible Herdr panes.

```text
┌──────────────────────────────┬──────────────────────────────┐
│ SAGE                         │ FORGE                        │
│ Claude Code                  │ OpenCode 1                   │
│ Claude Opus                  │ Gemini Flash                 │
│                              │                              │
│ Deep science / numerical     │ Implementation / repair      │
│ reasoning                    │                              │
├──────────────────────────────┼──────────────────────────────┤
│ PATHFINDER                   │ SENTINEL                     │
│ OpenCode 2                   │ OpenCode 3                   │
│ MAI-Code Flash               │ MAI-Code Flash               │
│                              │                              │
│ Search / triage / evidence   │ Supervisor / routing         │
└──────────────────────────────┴──────────────────────────────┘
```

---

# 3. Agent responsibilities

## 3.1 SENTINEL

Model:

```text
OpenCode 3
MAI-Code Flash
```

Role:

> Autonomous supervisor and routing decision engine.

Sentinel does not debug ecosys directly.

Sentinel decides:

- what should happen next;
- which worker should receive the task;
- whether evidence is sufficient;
- whether a test should run;
- whether a checkpoint should be created;
- whether the issue should escalate to Sage;
- whether a task has stagnated;
- whether the verified frontier can advance;
- whether human review is required.

Sentinel should read only the minimum orchestration state.

Primary reads:

```text
.agent/state.md
.agent/frontier.json
.agent/results/
.agent/current_task.md
audit/unresolved-gaps.md
audit/validation-ledger.csv
```

Primary writes:

```text
.agent/dispatch.json
.agent/current_task.md
.agent/tasks/
```

Sentinel must NOT routinely:

- crawl the source repository;
- inspect large Fortran files;
- inspect large Zig files;
- modify production code;
- run long simulations;
- perform scientific reasoning that belongs to Sage;
- solve implementation tasks itself.

Sentinel should usually be a fresh session for each routing decision.

## 3.2 PATHFINDER

Model:

```text
OpenCode 2
MAI-Code Flash
```

Role:

> Low-cost investigation, search, evidence collection, and failure localization.

Typical work:

- `rg` searches;
- symbol mapping;
- locate relevant Zig routines;
- locate legacy Fortran counterparts;
- inspect small source ranges;
- inspect Git history;
- classify failures;
- extract relevant log sections;
- identify first meaningful divergence;
- prepare failure packets;
- identify candidate science gaps;
- gather exact evidence for Sage or Forge.

Pathfinder should normally be read-only with respect to production scientific source code.

Pathfinder should not attempt broad refactoring.

Pathfinder's goal is:

> Make expensive models consume less context.

## 3.3 FORGE

Model:

```text
OpenCode 1
Gemini Flash
```

Role:

> Primary implementation engineer.

Forge performs:

- bounded Zig fixes;
- implementation of confirmed missing logic;
- indexing corrections;
- initialization fixes;
- state persistence fixes;
- coupling fixes;
- output semantic corrections;
- checkpoint/restart implementation;
- targeted tests;
- small refactors required for correctness.

Forge should not independently redefine ecosystem science.

If implementation choices imply different scientific behaviour, stop and escalate to Sage.

Forge may edit production Zig code only when a written hypothesis exists.

## 3.4 SAGE

Model:

```text
Claude Code
Claude Opus
```

Role:

> Senior scientific and numerical investigator.

Use Sage only where the additional reasoning capability is justified.

Typical tasks:

- difficult Fortran↔Zig equivalence;
- scientific process interpretation;
- solver pathology;
- coupling/order-of-operation issues;
- state lifecycle analysis;
- conservation problems;
- repeated failed hypotheses;
- ambiguous numerical differences;
- scientific validation;
- review of consequential fixes;
- approval of intentional deviations.

Sage should receive compact evidence packets.

Sage should NOT routinely:

- grep the entire repository;
- summarize giant logs;
- repeatedly run builds;
- repeatedly execute Ottawa;
- perform low-value mechanical work.

---

# 4. Deterministic wrapper

Create a small wrapper script.

Recommended:

```text
tools/swarm-wrapper.py
```

The wrapper is NOT an AI.

It performs process management.

Responsibilities:

- start/stop Herdr agents;
- maintain pane identity;
- launch fresh sessions;
- read `dispatch.json`;
- deliver task files;
- detect completion;
- enforce session limits;
- enforce timeouts;
- recover stale sessions;
- archive results;
- execute deterministic scripts;
- invoke hooks;
- manage locks;
- prevent overlapping edits;
- maintain resumable workflow state.

The wrapper must not make scientific decisions.

The wrapper should be intentionally boring.

---

# 5. Main repository layout

Preserve existing project structure and adapt rather than duplicate.

```text
ecosys-modernization/
│
├── f77src/
│   └── legacy Fortran source — READ ONLY
│
├── f77example/
│   └── canonical legacy Ottawa run
│
├── ecosys-ng/
│   └── Zig implementation
│
├── ecosys-ng-prod-examples/
│   └── canonical Zig production cases
│
├── .agent/
│   ├── state.md
│   ├── frontier.json
│   ├── workflow.json
│   ├── dispatch.json
│   ├── current_task.md
│   │
│   ├── tasks/
│   ├── results/
│   ├── failures/
│   ├── checkpoints/
│   ├── locks/
│   └── archive/
│
├── audit/
│   ├── translation-matrix.csv
│   ├── validation-ledger.csv
│   ├── science-invariants.md
│   ├── intentional-deviations.md
│   ├── unresolved-gaps.md
│   ├── resolved-findings.md
│   └── output-provenance.csv
│
├── validation/
│   ├── reference/
│   ├── zig/
│   ├── comparisons/
│   ├── balances/
│   ├── events/
│   └── reports/
│
├── logs/
│   ├── build/
│   ├── tests/
│   ├── production/
│   ├── agents/
│   └── archive/
│
├── tools/
│   ├── swarm-wrapper.py
│   ├── build-zig.sh
│   ├── build-fortran.sh
│   ├── run-ottawa-zig.sh
│   ├── run-ottawa-fortran.sh
│   ├── run-from-checkpoint.sh
│   ├── compare-outputs.py
│   ├── extract-failure.py
│   ├── make-failure-packet.py
│   ├── check-balances.py
│   ├── update-frontier.py
│   ├── validate-restart.py
│   └── summarize-run.py
│
├── AGENTS.md
├── CLAUDE.md
└── existing project skill pack
```

Keep root-level clutter to a minimum.

---

# 6. Token minimization architecture

This is a mandatory design goal.

The autonomous workflow should explicitly minimize both input and output tokens.

## 6.1 Do not preload irrelevant memory

Every fresh agent session must receive ONLY the context relevant to the current task.

Do not automatically inject:

- old conversation history;
- unrelated project memories;
- unrelated architectural notes;
- unrelated science modules;
- all previous failures;
- all old agent results;
- entire log archives;
- all project skills;
- unrelated user/project context.

A task dealing with soil-water transport should not receive detailed memory about unrelated phosphorus, management, UI, packaging, or historical debugging.

Context selection must be task-scoped.

## 6.2 Do not load irrelevant skills

The existing project skill pack is valuable but should not all be loaded into every session.

Skills are reusable playbooks, not universal prompt material.

Load only skills relevant to the current task.

Example:

```text
Pathfinder investigating divergence:
    divergence-localization
    fortran-zig-navigation

Forge implementing state fix:
    implementation
    regression-testing

Sage reviewing solver:
    solver-diagnostics
    scientific-equivalence
```

Do not inject ten unrelated skills because they exist.

## 6.3 Do not load irrelevant tools

Each agent should receive the smallest practical tool set.

Default worker tools:

```text
read
search
edit when required
shell
```

Shell gives access to:

```text
zsh
rg
git
zig
gfortran
python
project scripts
```

Do not create dedicated MCP services for Zig or gfortran.

They are normal command-line executables.

---

# 7. MCP policy

Default:

> MCP OFF.

Normal ecosys work should not require MCP.

Do not automatically load:

```text
GitHub MCP
browser MCP
database MCP
documentation MCP
filesystem MCP
large generic MCP catalogs
```

unless a particular task requires one.

If an MCP is genuinely required:

1. launch a fresh dedicated session;
2. enable only that MCP;
3. complete the external task;
4. terminate the session;
5. disable the MCP.

Avoid exposing large MCP schemas to ordinary debugging agents.

---

# 8. Agent tool profiles

## Sentinel

Allowed:

```text
read selected .agent files
write task/dispatch files
small shell access if absolutely necessary
```

Prefer no production-code editing.

No MCP.

## Pathfinder

Allowed:

```text
read
search
shell
git
rg
small targeted source extraction
```

Production source read-only by default.

No MCP.

## Forge

Allowed:

```text
read
search
edit
shell
zig
git
targeted test scripts
```

No unrelated external tools.

## Sage

Allowed:

```text
read
search
limited shell
targeted scientific source inspection
Git diff/history
```

Avoid giant tool catalogs.

No MCP by default.

---

# 9. Tool-call economy

Every agent should operate under this rule:

> Before invoking a tool, determine whether the result can materially change the next decision.

Avoid low-value repetitive operations.

Use:

```text
search
→ targeted read
→ hypothesis
→ targeted test
```

instead of:

```text
read huge file
→ read another huge file
→ search
→ read huge logs
→ run everything
```

---

# 10. Session budgets

Suggested initial budgets:

## Sentinel

```text
5–8 meaningful tool calls
1 routing decision
then exit
```

## Pathfinder

```text
10–20 meaningful tool calls
one investigation
then exit
```

## Forge

```text
one implementation task
one primary fix
targeted validation
then exit
```

## Sage

```text
one high-value scientific question
bounded relevant source inspection
one conclusion/recommendation
then exit
```

Do not preserve a session merely because it remains technically usable.

---

# 11. Stagnation rules

An investigation must terminate and escalate if any of these occur:

```text
3 materially different hypotheses rejected
2 repair attempts from the same diagnosis fail
tool budget reached
no meaningful new evidence appears
agent begins revisiting already rejected ideas
agent starts broad repo exploration without justification
```

Then:

```text
write failure packet
record rejected hypotheses
terminate session
start fresh routing decision
escalate if appropriate
```

Never let an agent endlessly tweak.

---

# 12. State files

## `.agent/state.md`

Keep concise.

Target:

```text
~1,500 words or less whenever practical
```

Suggested structure:

```text
Current objective
Current candidate commit
Verified frontier
Current failure
Confirmed facts
Current diagnosis
Recent accepted change
Open blockers
Next expected operation
```

Do not append an endless history.

Replace obsolete information.

## `.agent/frontier.json`

Example:

```json
{
  "case": "Ottawa",
  "simulation_frontier": 18423,
  "verified_frontier": 18000,
  "current_failure_hour": 18424,
  "last_checkpoint_hour": 18000,
  "candidate_commit": "abc1234"
}
```

## `.agent/workflow.json`

Maintain durable process state.

Example:

```json
{
  "project": "ottawa-qualification",
  "phase": "LOCAL_REPLAY",
  "task_id": "T-00487",
  "worker": "FORGE",
  "status": "PENDING",
  "verified_frontier": 18000,
  "resume_safe": true
}
```

This allows recovery after:

- Herdr crash;
- terminal disconnect;
- agent crash;
- Windows restart;
- rate limit;
- simulation crash.

Provide an equivalent resume entry point such as:

```zsh
./tools/start-swarm.sh --resume
```

---

# 13. Task contract

Each task file should contain:

```text
TASK ID
ROLE
OBJECTIVE
INPUTS
ALLOWED FILES
RELEVANT SKILLS
KNOWN FACTS
HYPOTHESIS if applicable
SUCCESS CONDITION
STOP CONDITIONS
OUTPUT FILE
```

Example:

```text
TASK: T-00487

ROLE:
PATHFINDER

OBJECTIVE:
Identify the first state divergence after checkpoint hour 18900.

ALLOWED:
soil-water related Zig and corresponding Fortran routines.

DO NOT:
Modify source.
Run full Ottawa simulation.
Explore unrelated processes.

SUCCESS:
Identify first materially divergent variable and candidate routine.

OUTPUT:
.agent/results/T-00487.md
```

---

# 14. Result contract

Every worker output should contain only:

```text
TASK
STATUS
FINDING
EVIDENCE
FILES INSPECTED OR CHANGED
TESTS
SCIENTIFIC IMPACT
UNCERTAINTY
RECOMMENDED NEXT ACTION
```

Do not store conversational transcripts.

---

# 15. Hypothesis contract

Before Forge modifies scientific code:

```text
HYPOTHESIS

Observed defect:
...

Evidence:
...

Proposed mechanism:
...

Proposed change:
...

Prediction:
...

Falsification condition:
...
```

If the prediction fails:

```text
REJECT hypothesis
REVERT or isolate change
RECORD result
```

Do not pile another speculative edit on top.

---

# 16. Hooks

Hooks should automate predictable operations without LLM reasoning.

## 16.1 After Zig edit

Run:

```zsh
zig fmt <changed files>
```

Optionally run the narrowest applicable compile check.

## 16.2 After implementation

Automatically invoke targeted tests.

Forge should not need to remember this.

## 16.3 After targeted test success

Run the next appropriate validation level.

Do not immediately run the full Ottawa case.

## 16.4 After failure

Automatically:

```text
extract relevant failure
summarize
capture current commit
capture recent diff
identify last good checkpoint
produce failure packet
```

## 16.5 After worker exit

Automatically:

```text
archive result
capture summary
release file lock
restore pane
notify wrapper
launch fresh Sentinel session
```

## 16.6 Before Git checkpoint

Automatically run the qualification subset required for that checkpoint.

## 16.7 Git safety hook policy

Do NOT automatically commit and push after every completed task.

Use the safer sequence:

```text
worker finishes
    ↓
result archived
    ↓
git diff captured
    ↓
targeted tests
    ↓
local replay / required validation gate
    ↓
candidate change accepted?
    ├── NO → revert/isolate, no commit
    └── YES
          ↓
      meaningful local commit
          ↓
verified frontier or stable milestone reached?
    ├── NO → keep local
    └── YES → push
```

Never make `git push` an unconditional post-task or post-commit hook.

---

# 17. Logs

Logs are storage, not model context.

Recommended:

```text
logs/
  production/
    <run-id>/
      stdout.log
      stderr.log
      summary.json

  tests/
  build/
  agents/
```

Every long operation should produce a concise machine-readable summary.

Example:

```json
{
  "status": "FAIL",
  "last_completed_hour": 18939,
  "failure_hour": 18940,
  "subsystem": "soil_water",
  "failure_type": "convergence",
  "full_log": "logs/production/run-x/stdout.log"
}
```

Agents read `summary.json` first.

Full logs are accessed only when necessary.

---

# 18. Failure packet

Each material production failure should generate:

```text
.agent/failures/F-xxxxx/
│
├── summary.md
├── state-values.json
├── relevant-zig.txt
├── relevant-fortran.txt
├── recent-diff.patch
├── hypotheses.md
├── rejected-hypotheses.md
└── log-pointer.txt
```

The packet should identify:

```text
first failing timestep
last scientifically verified timestep
first materially divergent state
affected subsystem
exact error
relevant variables
candidate Zig routine
candidate Fortran counterpart
recent changes
previous attempts
checkpoint for reproduction
```

Sage should usually receive this packet rather than rediscover the problem.

---

# 19. Scientific audit before endless execution

Do not rely solely on run-until-crash debugging.

Perform a systematic translation/science audit.

## Gate G0 — Baseline

Establish:

```text
canonical Ottawa inputs
canonical gfortran reference
canonical Zig case
compiler versions
build commands
output inventory
current Git baseline
```

## Gate G1 — Translation/science coverage

Audit scientifically relevant legacy pathways.

Major domains include:

```text
initialization
weather/environment
soil water
soil heat
freeze/thaw
gas
plant
root
photosynthesis
respiration
carbon
nitrogen
phosphorus
microbial processes
nutrient transport
management
boundary exchange
solver
cumulative accounting
outputs
```

Use the existing detailed skill pack.

Do not rewrite mature skills unnecessarily.

## Gate G2 — Integration readiness

Verify:

```text
required state initialized
coupling wired correctly
production execution enters valid dynamics
output semantics mapped
checkpoint/restart basic validation passes
no known critical science gaps remain
```

Then begin frontier-based dynamic qualification.

---

# 20. Translation matrix

Maintain:

```text
audit/translation-matrix.csv
```

Fields should include:

```text
Fortran file
Fortran routine/block
Zig module
Zig function
scientific process
status
evidence
intentional difference
tests
review status
```

Statuses:

```text
UNMAPPED
MAPPED
AUDITING
GAP_FOUND
FIXING
TESTING
REVIEW_REQUIRED
VERIFIED
BLOCKED
```

A filename mapping does not equal scientific equivalence.

---

# 21. Definition of science gap

A science gap exists when a scientifically relevant legacy behaviour cannot be accounted for in Zig.

Examples:

```text
missing equation
missing branch
wrong branch condition
wrong parameter
wrong units
wrong initialization
lost persistent state
wrong update order
incorrect timestep semantics
missing coupling
incorrect indexing
COMMON-block state not preserved
sign error
incorrect cumulative accounting
incorrect physical bounds
output semantic mismatch
restart state omission
```

The Ottawa milestone requires:

> No unresolved scientifically material science gap on the Ottawa execution path.

---

# 22. Validation ladder

Never go directly from edit to full Ottawa.

Use:

```text
T0
format/static check

↓

T1
targeted unit test

↓

T2
module/subsystem test

↓

T3
short local integration

↓

T4
checkpoint/restart equivalence

↓

T5
targeted Ottawa replay around failure

↓

T6
extended Ottawa segment

↓

T7
long-run frontier advancement

↓

T8
full Ottawa qualification run
```

Source changes must move back down the ladder as appropriate.

---

# 23. Differential replay

When a failure occurs:

```text
last verified checkpoint
↓
restart near failure
↓
reproduce short interval
↓
find first material divergence
↓
reduce time window
↓
compare process state
↓
compare inputs
↓
compare equation-level behaviour if necessary
```

Do not begin by comparing every floating-point operation.

Work from system behaviour downward.

---

# 24. Checkpoint/restart

Checkpoint/restart is mandatory.

The user must be able to control restart behaviour through the run script.

Conceptually:

```zsh
./tools/run-ottawa-zig.sh
```

and:

```zsh
./tools/run-ottawa-zig.sh --restart <checkpoint>
```

A checkpoint must restore all scientifically material state.

Validate:

```text
continuous run
versus
run → checkpoint → restart → continue
```

for scientific equivalence.

Ensure checkpoint state includes where relevant:

```text
stocks
flux accumulators
counters
temporal indexes
lagged state
solver state
biological state
root state
transport pools
exchange state
cumulative output state
```

---

# 25. Output provenance

Maintain:

```text
audit/output-provenance.csv
```

For each validation variable record:

```text
output file
column
Fortran origin
Zig origin
units
time basis
instantaneous/rate/integrated/cumulative
aggregation
conversion
comparison rule
status
```

Do not assume similar column names represent identical quantities.

---

# 26. Scientific comparison framework

The goal is scientific comparability, not bitwise identity.

## Structural quantities

Where appropriate, expect exact agreement:

```text
dates
event ordering
management events
identifiers
counters
output structure
branch selection
```

## Continuous quantities

Use scientifically defensible variable-specific comparison rules.

Evaluate as appropriate:

```text
absolute error
relative error
bias
RMSE
correlation
timing
seasonality
event response
annual totals
cumulative totals
long-term trajectory
```

Do not use one universal tolerance.

Do not tune tolerances after seeing Zig output merely to create a pass.

---

# 27. Conservation sentinels

Automate scientifically important balance checks.

At minimum where applicable:

```text
water
carbon
nitrogen
phosphorus
energy
```

Track:

```text
instantaneous residual
time-integrated residual
cumulative residual
```

Do not fail merely because floating-point residuals are non-zero.

Do escalate if residuals indicate physically material imbalance.

---

# 28. Solver validation

A solver reaching convergence does not prove the science is correct.

For solver-related issues inspect:

```text
residual trajectory
Jacobian behaviour
iteration count
bound handling
state update ordering
fallback activation
conservation
physical admissibility
legacy solution behaviour
```

Do not solve problems by arbitrary:

```text
tolerance loosening
extra iterations
wider bounds
extra retry loops
silent clamping
```

without numerical/scientific justification.

---

# 29. Rejected hypothesis memory

Maintain:

```text
audit/resolved-findings.md
```

or structured records.

Record genuinely disproven explanations.

Example:

```text
Issue F-00231

Hypothesis:
Anderson depth causes hour 18423 failure.

Test:
Depth varied while all other conditions fixed.

Result:
First divergence unchanged.

Disposition:
Rejected.

Evidence:
...
```

Future agents should read only relevant rejected hypotheses.

Do not inject the entire history into every task.

---

# 30. Git as scientific evidence

Use Git deliberately.

Meaningful fixes should have commit messages recording:

```text
problem
root cause
scientific impact
fix
validation
```

Use Git to recover history instead of conversational memory.

Never destroy user work.

Do not force-push or rewrite history without explicit authorization.

## 30.1 Safer commit/push policy

Do not commit after:

- mere investigation;
- failed hypotheses;
- failed fixes;
- exploratory edits that have not passed the required gate.

Commit when:

- the bounded fix has passed the required targeted tests;
- local replay confirms the predicted effect;
- the change is worth preserving as a recoverable scientific checkpoint.

Push when:

- a verified frontier advances;
- a scientifically accepted fix reaches a stable milestone;
- an agreed checkpoint is reached;
- or an explicit synchronization policy says to push.

Recommended flow:

```text
Pathfinder triage
→ no commit

Forge experimental fix
→ targeted test FAIL
→ revert/isolate
→ no commit

Forge confirmed fix
→ targeted tests PASS
→ local replay PASS
→ meaningful local commit

verified frontier advances
→ push
```

Never use an unconditional `git push` hook.

---

# 31. Concurrency

Parallelize independent investigation.

Example:

```text
Pathfinder gathers evidence
while
Sage reviews an existing failure packet
```

Do NOT allow simultaneous overlapping edits.

Only one agent owns an implementation area at a time.

Use locks under:

```text
.agent/locks/
```

if necessary.

Worktrees may be used for intentionally independent experimental branches.

---

# 32. Routing logic

Typical new failure:

```text
NEW FAILURE
   ↓
PATHFINDER
evidence / localization
   ↓
clear mechanical defect?
   ├── YES → FORGE
   └── NO
        ↓
scientific or numerical ambiguity?
        ├── YES → SAGE
        └── insufficient evidence → PATHFINDER
```

After Forge:

```text
FORGE
   ↓
targeted tests
   ↓
FAIL
   ├── implementation mistake → FORGE fresh session
   └── diagnosis questionable → SAGE
   ↓
PASS
   ↓
local replay
   ↓
PASS
   ↓
extended replay
   ↓
advance verified frontier if evidence permits
```

---

# 33. Stagnation escalation

Maximum default:

```text
3 materially different rejected hypotheses
OR
2 failed implementations from the same diagnosis
```

Then automatically:

```text
stop
archive evidence
create fresh failure packet
terminate worker
send to Sentinel
likely escalate to Sage
```

No fourth random attempt.

---

# 34. Human review condition

Sentinel may issue:

```text
HUMAN_REVIEW_REQUIRED
```

when:

```text
scientific behaviour cannot be determined from legacy code
multiple scientifically plausible interpretations exist
requested change would alter accepted model science
reference Fortran appears internally inconsistent
validation tolerance requires domain judgment
workflow detects possible corruption of accepted state
```

Autonomy must not manufacture scientific certainty.

---

# 35. Full Ottawa qualification

When the verified frontier reaches the end:

Freeze the candidate commit.

Perform a clean qualification run.

Then:

1. build production Zig binary;
2. build/reference gfortran baseline;
3. run Ottawa from hour zero;
4. collect all validation outputs;
5. run automated comparison;
6. run balance diagnostics;
7. compare event timing;
8. compare important ecosystem states;
9. compare important fluxes;
10. compare annual totals;
11. compare cumulative totals;
12. explain every material deviation.

Any code change after freezing the candidate invalidates the final qualification run as appropriate.

---

# 36. Scientific acceptance report

Generate:

```text
validation/reports/ottawa-scientific-qualification.md
```

Include:

## Reproducibility

```text
Git commit
Zig version
gfortran version
build commands
input deck
runtime configuration
```

## Translation coverage

```text
mapped pathways
verified pathways
remaining gaps
intentional deviations
```

## Numerical behaviour

```text
solver configuration
convergence
fallback behaviour
abnormal events
```

## Conservation

```text
water
carbon
nitrogen
phosphorus
energy where available
```

## Output comparison

For each major variable:

```text
units
time semantics
legacy behaviour
Zig behaviour
difference
comparison rule
disposition
```

## Event behaviour

Examples:

```text
precipitation response
freeze/thaw
growing season transitions
stress events
management events
```

## Integrated behaviour

```text
seasonal
annual
multi-year
cumulative
```

## Restart validation

Show checkpoint/restart scientific equivalence.

## Intentional deviations

Explain every accepted divergence.

## Remaining limitations

List explicitly deferred work.

---

# 37. Acceptance criteria

Do not label the Ottawa milestone complete until:

## Execution

```text
full run completes
no NaNs
no uncontrolled abort
no unexplained solver failure
```

## Translation

```text
all Ottawa-used scientifically material pathways accounted for
no unresolved material science gap
```

## State

```text
initialization reconciled
persistent state reconciled
restart verified
```

## Coupling

```text
major subsystem coupling accounted for
```

## Numerical behaviour

```text
differences explained
solver behaviour defensible
```

## Conservation

```text
major balances physically defensible
```

## Outputs

```text
units reconciled
time semantics reconciled
provenance documented
```

## Scientific comparison

```text
important states comparable
important fluxes comparable
seasonality comparable
event responses comparable
annual totals defensible
long-term trends defensible
cumulative behaviour defensible
```

## Evidence

A technically competent independent scientist/developer should be able to follow the evidence and understand why the implementation was accepted.

---

# 38. Work sequence for Claude implementing this system

## Phase 1 — Inspect first

Do not immediately create files.

Inspect:

```text
existing repository
Git state
current folder structure
existing skill pack
current audit tools
current validation tools
existing scripts
existing agent/orchestration infrastructure
current Herdr setup
```

Identify what already exists.

Do not duplicate mature functionality.

## Phase 2 — Produce gap assessment

Create a concise implementation map:

```text
Already exists
Partially exists
Missing
Needs adaptation
Should be retired
```

Then implement only missing or deficient pieces.

## Phase 3 — Build control plane

Create/adapt:

```text
.agent/
workflow state
dispatch protocol
task/result contract
frontier tracking
failure packets
lock handling
```

## Phase 4 — Build wrapper

Implement:

```text
tools/swarm-wrapper.py
```

It must:

```text
start/restart workers
start fresh Sentinel
dispatch tasks
watch completion
run hooks
enforce limits
recover after crash
support --resume
```

## Phase 5 — Configure agents

Create clear role prompts/configuration for:

```text
SENTINEL
PATHFINDER
FORGE
SAGE
```

Prompts must explicitly enforce:

```text
minimal context
minimal tools
silent operation
one bounded task
no irrelevant memories
no irrelevant skills
no irrelevant MCP
concise result
exit after task
```

## Phase 6 — Integrate existing skill pack

Do NOT rebuild the skill pack from scratch.

Map existing skills to agents and task types.

Implement selective skill loading where possible.

## Phase 7 — Deterministic scripts

Create/adapt:

```text
build-zig.sh
build-fortran.sh
run-ottawa-zig.sh
run-ottawa-fortran.sh
run-from-checkpoint.sh
extract-failure.py
make-failure-packet.py
compare-outputs.py
check-balances.py
validate-restart.py
summarize-run.py
```

Scripts should output concise machine-readable summaries.

## Phase 8 — Hooks

Configure:

```text
post-edit format
post-edit compile check
post-implementation targeted tests
post-failure evidence extraction
post-agent result archival
pre-checkpoint validation
post-frontier state update
safe commit gate
stable-checkpoint push gate
```

## Phase 9 — Audit layer

Create/adapt:

```text
translation matrix
validation ledger
science invariants
output provenance
intentional deviations
unresolved gaps
resolved findings
```

Use existing project skills to populate/audit them.

## Phase 10 — Baseline qualification

Establish G0 baseline.

Do not begin autonomous production debugging until baseline reproducibility is confirmed.

## Phase 11 — Science-gap audit

Complete the systematic Ottawa execution-path audit.

Prioritize high-risk scientific pathways.

## Phase 12 — Frontier workflow

Once ready:

```text
verified checkpoint
↓
run
↓
failure/divergence
↓
Pathfinder
↓
Sage if required
↓
Forge
↓
validation ladder
↓
advance verified frontier
↓
meaningful commit
↓
push only at stable checkpoint
↓
fresh sessions
↓
repeat
```

## Phase 13 — Full frozen Ottawa qualification

After frontier completion:

```text
freeze candidate
full clean run
legacy comparison
scientific report
```

---

# 39. Context loading rules for every model

This is mandatory.

At the start of every session:

> Do not load broad personal memory, unrelated historical conversation, unrelated project memory, unrelated user information, or unrelated repository context.

Load only:

```text
current task
current state
specific relevant findings
specific relevant skill(s)
specific source files/ranges
specific relevant rejected hypotheses
```

Do not load:

```text
all old chats
all project memories
all logs
all audit files
all skills
all MCP tools
all previous worker results
all source directories
```

unless the task explicitly requires them.

Repository search should be demand-driven.

---

# 40. Final token-saving directive

All four agents must optimize for:

```text
minimum necessary context
minimum necessary tool schemas
minimum necessary source reads
minimum necessary model output
maximum use of deterministic scripts
maximum reuse of persisted evidence
```

The system should prefer:

```text
files + Git + compact state
```

over:

```text
conversation memory
```

Prefer:

```text
shell + project scripts
```

over:

```text
large MCP catalogs
```

Prefer:

```text
one targeted skill
```

over:

```text
full skill library
```

Prefer:

```text
short evidence packet
```

over:

```text
giant log/context dump
```

Prefer:

```text
fresh session
```

over:

```text
context compaction of a giant old session
```

---

# 41. Ultimate autonomous operating loop

```text
                    SENTINEL
                      MAI
                       │
               choose one action
                       │
       ┌───────────────┼────────────────┐
       │               │                │
       ▼               ▼                ▼
  PATHFINDER          FORGE            SAGE
      MAI             Gemini           Opus
 evidence/triage    implementation    deep science
       │               │                │
       └───────────────┼────────────────┘
                       ▼
              deterministic validation
                       │
        ┌──────────────┴──────────────┐
        │                             │
       PASS                          FAIL
        │                             │
 verified frontier              reject hypothesis
        │                             │
 meaningful commit          gather new evidence
        │                             │
 stable checkpoint?        escalate if needed
   ├── NO → continue
   └── YES → push
        │
 fresh Sentinel
```

The project may run for weeks.

The individual AI sessions should generally run for minutes or bounded tasks.

That distinction is fundamental.

---

# 42. Success condition for the autonomous system itself

The orchestration infrastructure is successful when it can:

```text
start
resume after interruption
create fresh sessions
route work correctly
avoid context accumulation
avoid redundant searches
avoid unnecessary full runs
avoid repeated speculative fixes
escalate difficult science
record evidence
advance verified frontier
checkpoint safely
commit only validated work
push only stable checkpoints
continue autonomously
stop safely when human judgment is required
```

without depending on a persistent LLM conversation.

---

# 43. Final instruction to Claude

Before changing the repository:

1. inspect the current repo;
2. inspect the existing project skill pack;
3. inspect existing orchestration/audit infrastructure;
4. compare what exists against this specification;
5. produce a concise gap assessment;
6. preserve mature working components;
7. implement only what is missing or deficient.

Do not redesign functioning infrastructure merely for stylistic reasons.

Do not load irrelevant memory, skills, MCP tools, logs, source files, or historical conversations while carrying out this work.

Keep the repository clean.

Keep agent context small.

Keep science evidence explicit.

Keep worker sessions disposable.

Keep Git history meaningful.

Do not auto-push speculative or merely completed work.

Keep the Ottawa scientific qualification as the governing objective.
