# Evidence conventions

Keep live project records under `audit/` at the outer project root. The installer creates no passing audit records and never changes model source. Create directories as needed; do not replace an existing audit system without reconciling it.

```
audit/
  manifest/          source/input/toolchain snapshots, command registry, scope
  traceability/      statements, equations, symbols, call edges, output columns
  features/          one dossier per approved scientific change
  issues/            one diagnosis log per reproducible defect
  tests/             commands, environment, exit codes, counts, logs
  comparisons/       raw hashes, parser tests, schemas, per-column results
  conservation/      local, interface and whole-domain budgets
  performance/       individual repeats, medians, spread, profiles
  runs/              staged decks, immutable run metadata, logs, final-time proof
  reviews/           independent review records
  gates/             gate records for one candidate source snapshot
  handoff.md         RETIRED 2026-09-25: historical pointer only
```

Current state lives in `.agent/state.md` and the frontier in `.agent/frontier.json` (4-agent
swarm, `.agent/README.md`). Swarm tasks, results, failure packets and per-task archive records
live under `.agent/`; large binary evidence under `evidence/` with committed manifests. The
former handoff/task/review protocol (`audit/handoff.md`, `audit/tasks/`, `audit/reviews/`
receipts) is retired (`archive/pre-swarm-workflow/`); its records stay as history. Task
approval never substitutes for scientific gate evidence. Save full command streams with
`scripts/run_logged.py`; excerpts are navigation only, not completeness or acceptance proof.

Every claim names a candidate/source digest, source locations, exact command, working directory, tool versions, input hashes, elapsed time, exit status, produced artifacts and reviewer where applicable. Do not paste full large source files or logs into handoffs; reference them. Evidence paths in gate records are relative to the outer project root, and each artifact has a SHA-256 digest. A source location needs path, symbol, line span and source hash because line numbers drift.

## Minimum traceability records

Use the CSV header templates or the repository's equivalent machine-readable schema. A routine-level row is an index, not complete statement coverage. Expand logical fixed-form statements, constants, branches, assignments and interfaces into stable IDs. Record included/shared definitions once with every call-site relationship. Audit both directions: every legacy behavior has a disposition and every production Zig behavior has a legacy or approved-feature origin.

Coverage denominators are discovered from the real source/build graph, not set by the agent to the number of files it happened to inspect. Record total inventoried, mapped, reviewed, tested, dormant, replaced, approved retired and unresolved separately. Comment-only source is not executable coverage. Do not count a keyword search or regex routine inventory as a semantic proof.

## What closes an issue

A short record contains impact/severity, first bad time/cell/process, reference and Zig source anchors, a falsifiable cause, minimal input/state, before/after results, focused regression test, affected evidence that was invalidated, independent review and final disposition. Compile-only fixes still need an account of numerical impact. Never change a test expectation and its implementation together without demonstrating why the old expectation was wrong.

## Output normalization

Discover every actual output file/column before writing an adapter. Preserve raw files and hashes. Define all row keys, units, signs, spatial support, time windows, instantaneous/interval/cumulative semantics, reset boundaries, sentinels and formatting precision. An adapter may make a documented unit/format conversion; it may not smooth, drop discrepant records, rebase cumulative series or change simulation results to improve agreement.

The bundled comparator accepts **already normalized, identically keyed CSV** only. It is not a parser for unseen ecosys files and cannot establish that two identically truncated files are complete. The agent must test the repository-specific raw adapters and separately prove expected run duration, keys and inventory completeness. File/column additions or omissions are failures unless individually documented and reviewed. Unknown columns, duplicate keys and nonfinite numbers fail the comparator. Explicit legitimate missing tokens are matched and counted; all-missing numeric columns fail.

Tolerance policy is determined before the acceptance comparison and records precision, units, scale, discretization rationale and independent review. Tighter kernel tests, more permissive improved-physics envelopes, accumulated drift limits and trend/seasonality tests are distinct. No silent post-hoc widening. Per-column diagnostic statistics never replace acceptance rules or balance checks.

## Benchmark record

Record hardware/OS, exact compilers and flags, binary/source/deck hashes, precision, solver/physics choices, output frequency, thread count, affinity/power setting where available, warmup policy, cache state, repeat count, each duration and peak memory. Separate clean build, cached rebuild, source-change rebuild, simulation wall time, CPU time and I/O. Benchmark without other agents compiling or running. Report median and spread of at least three measured repetitions after a stated warmup, or clearly report why fewer are available and leave the performance gate unpassed.

Use optimized Fortran and optimized Zig for fair production comparisons, with equal work and I/O. Compare one thread to one thread before reporting scaling; use equal allocated cores for parallel comparisons. Distinguish language/runtime effects from algorithm/precision changes. A prior project target was an Ottawa six-year run below 300 seconds: apply that absolute target only if this exact deck/hardware scope is established. Do not substitute another deck or imply this target has already been achieved.

## Gate checker limits

`check_gate.py` checks a fixed set of required records for the selected gate, nonempty distinct author/reviewer labels, artifact hashes, a complete current source snapshot and pass statuses. It does not execute scientific tests, inspect whether a log proves its claim, authenticate reviewer identities or prevent an agent running commands directly. Review raw evidence. Treat tampering, fabricated approvals and same-agent aliases as invalid. The broader contract governs checks beyond this mechanical minimum.

## Existing symlinks and external datasets

The small snapshot helper deliberately refuses unresolved symlinks; this is a helper limitation, not a claim that symlinks make a model invalid. Do not modify preserved reference trees to satisfy it. For an existing linked deck, first document link identities, targets and external data dependencies. Extend collection and verification together with reviewed tests to hash both links and their frozen targets, or use the project's equivalently rigorous existing verifier and record the helper limitation. Do not silently omit linked forcing or executables, and do not mark the supplied mechanical gate passed while it remains blocked.
