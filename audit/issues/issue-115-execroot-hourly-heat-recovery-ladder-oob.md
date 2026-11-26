# issue-115 — executable-root test 'fixed external hour recovery escalates...' panics (index OOB, schedules rung overflow)

Status: FIXED by D-32 (cycle 00013, 2026-11-26) — root cause CONFIRMED, fixture corrected; production untouched.

## Resolution (D-32, 2026-11-26)

Root cause = the TEST FIXTURE predated two production evolutions (both authority-proven):
1. The universal NFH=4 baseline floor (issue-024): the first ladder rung is 4, not 1
   (`boundedInitialRecoverySubstepCount` -> `requested = @max(requested, universal_nfh_baseline_substeps)`),
   so the old expectation `.{1,20,32,64}` never matched; the panic simply happened first.
2. The terminal best-bounded attempt (DEV-011/014/015): after rungs {4,20,32,64} exhaust,
   `recoverFixedExternalHourAdaptively` makes ONE final attempt at the ceiling rung (64) with
   the acceptance flags armed -> FIVE calls; the len-4 fixture wrote index 4 -> panic.
   Production shape is receipt-backed: authority logs carry 'SOLUTE recovery ladder exhausted
   (...); final attempt exact_substep_count=64 with best-bounded-iterate' and those hours publish
   (v19/v18 whole campaigns; fix131 lane PASS-BEYOND).
Fix = fixture only: `schedules: [5]u8`, expectation `.{4,20,32,64,64}`, `attempts=5`.
Discrimination: wrong expectation (drop terminal rung) -> RC=1 (NEUTER); correct -> RC=0;
production file byte-identical before/after (only test block changed).
Root coverage answer (open question above): `module_index.zig` does NOT compile stages-file
tests (D-30 lesson) - this test runs ONLY in the test-EXECUTABLE root; gate recording must use
that root (cycle-13 gates record it).

## Original record (kept for lineage)

PRE-EXISTING at base 9368a7b (reproduced with cycle-4 edits stashed); surfaced by `zig build test`
(executable test root), not by the gate suite `zig build test-module` (4401 tests green Debug+ReleaseSafe).

## Observation

`zig build test -Dtest-filter="fixed external hour recovery escalates"` (Debug, deterministic, base and HEAD):

    thread panic: index out of bounds: index 4, len 4
    src/stages/hourly_heat_water_solute.zig:10686 in run
        self.schedules[self.attempts] = substep_count;

Full-root receipts: audit/runs/cycle4-suite-tests-Debug-20261022014533 (119/120, 1 crashed);
ReleaseSafe full-root same crash: audit/runs/cycle4-suite-tests-ReleaseSafe-20261022015220 (verify hash in dir).

## Analysis leads (UNVERIFIED)

- The recovery ladder's attempt counter can exceed the 4-slot `schedules` array when the full chain
  escalates past its last rung — the test name says "stops on hard defects"; the stop path apparently
  records one attempt too many (off-by-one between rung exhaustion and `attempts` increment).
- Why the same test file's behaviour differs between test roots (module root green vs executable root
  crash) is itself unexplained: check whether `module_index.zig` actually exports stages.* tests, or
  whether root build options (imports/config defaults) change the ladder length at comptime. If the
  module root does NOT contain this test, the gate suite has never covered it — inventory gap
  (P3 traceability) rather than flakiness.

## First steps

1. `./scripts/project.sh code`/grep: confirm which root compiles hourly_heat_water_solute.zig tests.
2. Reproduce standalone, dump `attempts`/`schedules.len` at the 5th attempt; identify intended cap
   (test expectation "full chain and stops").
3. Fix bounds only after the intended ladder semantics vs legacy DEV-014 terminal-only behaviour is
   re-read (`hourly_heat_water_solute.zig` 11966/12168/12263 call chain).

Related: DEV-014 (terminal-only ladder), DEV-011 (final bounded attempt), cycle-3 gate precedent
(gate = tests-module suite).
