# ecosys Fortran-to-Zig audit skill pack

A shared, source-first audit workflow for **Claude Code, Pi and Codex CLI**, tailored to the `ecosys_modernization` workspace.

**Pack revision:** 1.0.0. This is the version of the skill pack, not a claim that the ecosys-ng model is production-ready.

## What this delivers

Sixteen portable `SKILL.md` skills, a shared scientific/engineering contract, evidence and review templates, an installation script, three audit helpers, a ready-to-paste startup prompt and synthetic tests for the tooling. No model source, build command, numerical tolerance or run result has been invented.

The workflow is:

**Freeze references → audit all source and bindings while running focused tests → validate process/solver/coupling behavior → pass production-entry checks → run the full ReleaseFast deck → compare every output → establish scientific attribution → benchmark and independently review the final candidate.**

"Bit-by-bit" is operationalized as complete statement/equation/state/interface provenance, rather than an unrealistic demand for identical floating-point bit patterns after changing the scientific or numerical method. Discrete mappings, dates and counters remain exact where appropriate. A feature name never excuses an unexplained discrepancy.

## Project layout

The installer expects these existing directories and does not edit their contents:

```
ecosys_modernization/
├── f77src/                       Preserved legacy source
├── f77example/                   Preserved legacy run deck/reference outputs
├── ecosys-ng/                    Zig implementation to audit
└── ecosys-ng-prod-examples/       Required Zig production deck
```

It adds the following project-local resources:

```
ecosys_modernization/
├── .agents/skills/               Canonical skills for Codex and current Pi
│   └── ecosys-*/SKILL.md         16 focused skills
├── .claude/skills/               Links to canonical skills, or reviewed copies
├── ecosys-audit/
│   ├── PROJECT_CONTRACT.md       Scientific and Zig engineering requirements
│   ├── EVIDENCE_GUIDE.md         Provenance, comparison and benchmark conventions
│   ├── START_PROMPT.md           Ready-to-paste project instruction
│   ├── SOURCES.md                Primary documentation and scientific references
│   ├── gate_requirements.json    Minimum mechanical gate check inventories
│   ├── skill_index.json
│   ├── templates/               Unassessed evidence/review/schema templates
│   └── scripts/
│       ├── snapshot.py
│       ├── compare_outputs.py
│       └── check_gate.py
├── AGENTS.md                     Existing text preserved; managed block appended
└── CLAUDE.md                     Existing text preserved; managed block appended
```

Live project evidence belongs under `audit/`, separate from the reusable `ecosys-audit/` resources. The pack does not create passing project evidence.

## Install

Use Python 3.10 or later. The installer and helpers use only the Python standard library. Extract the distribution to a separate folder, not over an existing skill installation. Close active editing/agent sessions before applying it.

### macOS / Linux

First preview the changes:

```bash
python3 "/path/to/ecosys-audit-skill-pack/install.py" \
  --root "/path/to/ecosys_modernization"
```

Then apply:

```bash
python3 "/path/to/ecosys-audit-skill-pack/install.py" \
  --root "/path/to/ecosys_modernization" --apply
```

The default POSIX installation uses relative per-skill links in `.claude/skills/` pointing to `.agents/skills/`. This keeps one authoritative copy of each skill.

### Windows PowerShell

With Python available through the `py` launcher, use copy mode; creating symbolic links is not required:

```powershell
py -3 "C:\path\to\ecosys-audit-skill-pack\install.py" `
  --root "C:\path\to\ecosys_modernization" --mode copy

py -3 "C:\path\to\ecosys-audit-skill-pack\install.py" `
  --root "C:\path\to\ecosys_modernization" --mode copy --apply
```

Use `python` instead of `py -3` where that is how Python is installed. Copy mode contains snapshots of the leaf skills: keep `.agents/skills/` authoritative and deliberately synchronize reviewed skill edits to the Claude copies. Shared policies under `ecosys-audit/` remain common to all harnesses. The installer detects differing existing files and refuses to overwrite them; it is not a blind update/synchronization command.

### Installation safeguards

The default is a dry run. Conflicts are checked before writes. Existing instructions retain their original bytes and receive a small managed append. Model source, reference outputs and deck files are untouched. No global settings, permission overrides, background tasks, hooks or agent extensions are installed. An unexpected filesystem/I/O failure can leave safe partial additions; inspect the message and rerun rather than deleting project content.

Current Pi can discover `.agents/skills/` directly in trusted projects. Do not also create `.pi/skills/` aliases on these versions, which can cause duplicate discovery. The optional installer flag `--pi-legacy-alias` is only for a verified older installation that needs them. Documentation provenance is in `ecosys-audit/SOURCES.md`.

## Start an agent

Start each harness from the **outer `ecosys_modernization` root**, not just `ecosys-ng/`, especially when the folders are separate Git repositories. Restart the harness after installation and confirm the skill appears in its selector.

Enter the following **inside the harness session**, not as a shell command:

| Harness | Explicit invocation |
|---|---|
| Claude Code | `/ecosys-release-orchestrator` |
| Codex CLI | `$ecosys-release-orchestrator` |
| Pi | `/skill:ecosys-release-orchestrator` |

Then paste `ecosys-audit/START_PROMPT.md`. An invocation-independent alternative is:

> Read `ecosys-audit/PROJECT_CONTRACT.md`, `ecosys-audit/EVIDENCE_GUIDE.md`, and `.agents/skills/ecosys-release-orchestrator/SKILL.md`. Follow that skill to begin or resume the project. Inspect actual source, current work and prior evidence before making changes.

These paths and invocation forms were checked against public primary documentation during pack preparation. Actual CLI discovery and execution still depend on the versions and trust/settings installed on your machine. No live Claude Code, Pi or Codex session was exercised here.

## The 16 skills

| Skill | Responsibility |
|---|---|
| `ecosys-release-orchestrator` | Coordinate scope, gates, issue dependencies, bounded experiments and integration. |
| `ecosys-repository-baseline` | Freeze source/inputs/references and discover actual toolchains and commands. |
| `ecosys-fortran-zig-traceability` | Reconcile every logical statement, equation, branch and call in both directions. |
| `ecosys-state-io-bindings` | Verify explicit state ownership, COMMON replacements, parser/consumer/writer paths and cumulative semantics. |
| `ecosys-process-science-parity` | Audit the actual physical and biogeochemical process equations and their coupling. |
| `ecosys-conservation-audit` | Independently verify local/global mass and energy budgets and accumulated drift. |
| `ecosys-nonlinear-solver-audit` | Verify Newton/Anderson formulation, convergence, bounded work, rollback and constitutive edge cases. |
| `ecosys-feature-attribution` | Validate each intentional change and demonstrate the cause of its output effects. |
| `ecosys-validation-tests` | Build discriminating kernel, process, integration, edge, failure and restart tests. |
| `ecosys-output-comparison` | Account for every file, row and column with reviewed units, time support and tolerances. |
| `ecosys-divergence-diagnosis` | Find the first wrong state/flux and create a minimal reproducer instead of repeating the full run. |
| `ecosys-zig-safety-design` | Review types, ownership, memory, failure paths, maintainability and optimized-build safety. |
| `ecosys-performance-engineering` | Profile and measure fair compile/runtime/memory improvements without changing accepted science. |
| `ecosys-build-reproducibility` | Verify pinned builds, exact binaries, staged runs, restart integrity and clean-environment reproduction. |
| `ecosys-multi-agent-coordination` | Partition work, isolate edits, manage resources and require separate substantive review. |
| `ecosys-release-verification` | Independently assess the complete final candidate against production criteria. |

The orchestrator selects the relevant specialist skills. Do not load all sixteen full skill bodies into every worker's context. Give each worker its assigned source units, the shared contract, relevant skill and evidence pointers.

## Important project safeguards

The contract carries the fixed hourly external timestep and established Newton/Anderson design forward. It prevents introducing vanilla Picard, silent timestep adaptation or unbounded retry cascades as expedient fixes. Dall'Amico freeze-thaw, Mualem-van Genuchten hydraulics and every other intentional difference receive separate evidence dossiers; their exact implemented variants must be discovered and validated.

All of the requested Zig philosophies are translated into review obligations, including explicit ownership, bounded memory, allocation-failure handling, reliable cleanup, compile-time constraints where practical and production-effective error/physical-state checking. Debug-only assertions are not treated as a guarantee for `ReleaseFast`; floating-point mode is reviewed separately from optimization mode. Exact API syntax comes from the pinned compiler, not an assumed latest release.

The diagnosis policy allows three distinct hypothesis-driven experiments before a fresh review/reframing and blocks repeated expensive failures without new information. This is not a three-attempt limit on completing the project: agents continue other unblocked work and resume a diagnosis when new evidence exists.

Multi-agent work is optional and capability-dependent. One coordinator owns integration and full runs. Separate worktrees and disjoint file ownership avoid competing edits. Actual Pi sub-agent orchestration may require an existing extension or external workflow; the pack does not install one or pretend parallel agents ran. Sequential independent roles remain usable when concurrency is unavailable.

## Helper commands

These are commands for the installed helpers, not assumed model build/run commands. The agent first discovers and validates the real model commands.

### Freeze a candidate/source/input snapshot

From the project root:

```bash
python3 ecosys-audit/scripts/snapshot.py --root . \
  --out audit/manifest/candidate-001-snapshot.json
```

It hashes all regular files in the four authoritative trees and records the excluded generated/cache directories. Use a new evidence path for each candidate. Do not run it while files are being changed. It refuses unresolved symlinks; do not modify preserved references to satisfy this limitation. See the evidence guide for linked/external datasets and reviewed extensions to the verifier.

### Compare normalized outputs

After building and testing raw-output adapters and a reviewed complete schema:

```bash
python3 ecosys-audit/scripts/compare_outputs.py \
  --reference audit/comparisons/legacy-normalized.csv \
  --candidate audit/comparisons/zig-normalized.csv \
  --schema audit/comparisons/approved-schema.json \
  --report audit/comparisons/candidate-001-comparison.json
```

The template schema intentionally has `NOT_ASSESSED` status and unset tolerances. Derive the actual keys, columns, units, semantics and acceptance values from the code and evidence. Numerical comparison uses:

```
abs(candidate - reference) <= atol + rtol * max(abs(reference), scale_floor)
```

The comparator rejects unknown/missing columns, misordered/misaligned or duplicate keys, unequal row counts, invalid numbers, NaN/Inf and unapproved schemas. It counts legitimate declared missing pairs but will not pass an all-missing numerical column. It reports per-column errors, bias, MAE/RMSE and first failures; inputs and schema must remain unchanged during comparison. Reports are not overwritten. Decimal statistics are serialized as strings to preserve range/precision.

**Limit:** it compares already normalized CSV files. It cannot discover unseen ecosys raw formats, prove expected full-run duration, detect that both files omitted the same required records, assess seasonal physics by itself, or decide whether tolerances are scientifically reasonable. Those obligations belong to the corresponding skills and release review.

### Check reviewed gate evidence

```bash
python3 ecosys-audit/scripts/check_gate.py --root . \
  --gate audit/gates/candidate-001-production-entry.json
```

Populate an appropriate template with actual source snapshot and artifact hashes, check statuses and substantive author/reviewer identities. The checker verifies minimum check inventory, artifact existence/hashes, source freshness and review labels. It does not execute model tests, authenticate identities, interpret the scientific contents of logs, prevent direct commands or certify the release. Its `integrity_status: PASS` is only a bookkeeping/integrity result.

## What is and is not validated here

The distribution's synthetic tests exercise installation, portable skill structure, comparison failure paths, snapshot freshness and gate bookkeeping. See `TEST_RESULTS.md` and `tests/test-results.txt` for the actual run. Run them again from the extracted distribution with:

```bash
python3 -m unittest discover -s tests -v
```

The tool tests ran on Linux with Python 3.13.5, including POSIX link mode and platform-neutral copy mode. Native Windows/macOS behavior and live harness integration have not been executed here.

Your actual Fortran/Zig source, compilation, production run, scientific equivalence and performance have **not** been tested in this chat. The pack gives your local agents the procedures and evidence requirements for doing that work. Final readiness requires a successful full prescribed `ReleaseFast` run, complete accepted comparisons, conservation/safety/reproducibility evidence and the agreed performance result for the same final candidate—not simply this pack's tests passing.
