# Adversarial Review Round 9: Audit of Issue-076 CRLF Source-Scan Fix

Date: 2026-09-21  
Reviewer: Pi (Gemini 3.8 Flash)  
Target: Adversarial audit of `core/source_scan.zig` and rewired assertions in 4 test files (`issue-076`).  
Evaluated against: `audit/issues/issue-076-crlf-checkout-breaks-hardcoded-lf-multiline-source-scan-tests-seven-failures.md` and related test triage passes.

---

### G1. Can `source_scan` mask a real defect?
**VERDICT: NO (UNABLE TO CONSTRUCT A FALSE PASS).**
- In `matchEnd(haystack, start, needle)`:
  ```zig
  if (candidate == '\r' and needle[needle_index] != '\r') {
      haystack_index += 1;
      continue;
  }
  if (candidate != needle[needle_index]) return null;
  ```
- It *only* skips `\r` characters that exist in the haystack immediately prior to matching the expected needle character.
- Because Zig syntax does not use `\r` semantically (only within CRLF line endings or raw string literals), stripping `\r` cannot bridge two unrelated identifiers or synthesize keywords that are not present.
- Every non-`\r` character in `needle` (spaces, indentation, keywords, punctuation) must match identically in byte sequence.
- Negative test at `solver_tests.zig:4203` now tests the true absence of the bad string rather than vacuous non-matching caused by `\r`.

### G2. Did any test's meaning change beyond line endings?
**VERDICT: FAITHFUL AND PRESERVED.**
- Audited git diffs across all 4 files:
  1. `plant_symbiotic_fixation.zig:612`: Needle `executeHourlyScience(\n        driver_context.hourly_science_context.*`, error `error.MissingHourlyScienceCall`, and `prepare < science` ordering check are identical.
  2. `outer_hour_transaction.zig:1533`: Scans all 10 binding descriptors; expectation `@as(usize, 1)` is preserved.
  3. `production_integration_test.zig:41-48`: `requiredIndex` and `requiredIndexIn` keep exact error `error.MissingOutputTransactionIntegration`.
  4. `solver_tests.zig:3626-4203`: All 9 needle strings match the original literals byte-for-byte; negative check at line 4203 correctly asserts `!contains`.

### G3. Other multi-line `\n` needles in `src/`?
**VERDICT: CLEAN.**
- Swept all `@embedFile` and `readFileAlloc` consumers across `src/` for `indexOf`, `count`, and `contains`.
- Found only one other `\n` needle: `validation/conservation_survey.zig:382`:
  `try std.testing.expect(std.mem.indexOf(u8, text, "never moved\n") == null);`
  This is a negative assertion (`== null`) on generated summary text, not on Zig source code, and already passes.
- All other tests scan single-line identifiers (`"noinline fn..."`, `"try prepare..."`). The 4 rewired files contain all multi-line source scans in the codebase.

### G4. Namespace hygiene of `core/source_scan.zig`
**VERDICT: ACCEPTABLE WITH DOCUMENTED CENSUS EXCLUSION.**
- `ecosys-ng/src/core/` already houses shared test/support utilities (e.g. `test_runner.zig`, `legacy_water_negligible_floor.zig`).
- Placing it in `core/` keeps it accessible to root tests without cyclic imports across stages.
- The `CENSUS-ORPHAN-FP-001` banner at `core/source_scan.zig:20-25` matches the existing convention in `src/index/*_test_index.zig`. An alternative would be `src/testing/source_scan.zig`, but moving it is purely stylistic and not technically required.
