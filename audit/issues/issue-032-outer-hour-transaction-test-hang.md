# Issue 032 -- `outer_hour_transaction` test hangs indefinitely under `zig build test`, consuming unbounded CPU

Status: OPEN (discovered incidentally during run-004's performance work; not triaged or fixed; test-infrastructure correctness issue, not yet characterized as a science defect)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979
Source: discovered by the agent performing `audit/runs/run-004-logging-overhead-fix-and-remeasurement-2026-09-18.md` while attempting to run the full test suite as part of that run's output-neutrality verification step.

Failure signature and first bad time/location/process:
Running `zig build test` (per `ecosys-ng/build.zig:32-40`'s module+executable test artifacts) in this environment triggers a test named `driver.outer_hour_transaction.test."production outer hour explicitly owns soil gas and pending surface ledger"` that does not terminate. A resulting `test.exe` process was observed still running and consuming CPU **indefinitely** -- 62,993 CPU-seconds accumulated before it was manually killed by the discovering agent. This is not a slow test; it is a genuine hang (no plausible legitimate test should run for over 17 CPU-hours).

**Confirmed to reproduce on unmodified source**: the discovering agent verified this via `git stash` (reverting their own in-progress performance fix) before rebuilding a clean baseline binary and re-attempting the test run -- the hang occurred identically on the pre-fix, unmodified checkout. This rules out run-004's own logging-gate change as the cause.

Legacy/Zig source anchors: test name suggests `ecosys-ng/src/driver/` (an `outer_hour_transaction` module or test file) -- not yet located/read in detail; this issue records the discovery, not a diagnosis.

Scientific/output impact: unknown/not yet assessed. This could be a genuine infinite loop or deadlock in production code reachable from this test (a real correctness concern, potentially relevant to the project's other open solver/transaction-related work, e.g. `issue-015`'s stiff-solver frontier or the nonlinear-solver-audit skill's "bounded work... on exhaustion, terminate with a controlled diagnostic" requirement), or it could be a test-harness-only artifact (e.g. a test incorrectly waiting on a condition that production code never triggers, or an environment-specific issue with this Windows/MSYS2 toolchain). Not yet distinguished.

**Practical impact already observed this session**: this hang forced `run-004`'s agent to avoid `zig build test` entirely and use narrower `zig test src/module_index.zig --test-filter "..."` invocations instead for its own verification needs. Any future session attempting a full `zig build test` run in this environment should expect this same hang and budget for it (kill the runaway process; do not wait indefinitely) until this issue is resolved.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: `zig build test` from `D:\ecosys-modernization\ecosys-ng`, Zig 0.16.0, Windows 11 (this machine). Not yet reduced to a smaller/isolated reproducer (e.g. a direct `zig test` invocation targeting just this one test file/module).
Input/state provenance: n/a -- this is a test-harness hang, not data-dependent as far as is known.
Hypothesis: none yet formed. Candidates to check first, per `ecosys-nonlinear-solver-audit`'s general discipline (bounded work, no unlimited fallback/subdivision cascades): (a) an actual infinite loop or unbounded retry in the "outer hour transaction" code path under test; (b) a deadlock between the transaction's own locking and a test-harness expectation; (c) an environment-specific issue (this hang may be specific to this Windows/MSYS2 setup and not reproduce on the CI/reference platform this project was originally developed against -- not checked).
Stop/resource budget: 0 of 3 diagnosis experiments spent; this issue is a fresh discovery record, not a diagnosis loop yet.

## Experiments
(none yet -- this issue documents the discovery only)

## Resolution
Cause and focused patch: not yet determined; no patch applied.
Before/after results: n/a
Regression added and actually executed: none yet.
Invalidated evidence and rerun dependencies: none -- this does not invalidate any prior evidence in this session (run-004's own verification correctly worked around it via targeted test filters instead of the full suite).
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN**. This should be triaged before this project relies on `zig build test` as a complete/trustworthy correctness gate for any future release decision -- an unbounded hang in the standard test invocation is exactly the kind of infrastructure gap that could silently mask a real failure (a CI timeout killing the whole suite would look like "tests didn't pass" for unrelated reasons, or worse, a sufficiently generous timeout could let it pass by accident). Recommended next action: locate the test (`grep -r "outer hour explicitly owns soil gas" ecosys-ng/src`), read the code path it exercises, and determine whether the hang is in test setup/teardown or in genuinely-reachable production logic.
