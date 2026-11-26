# Cycle 00012 gate digest (v19 authority) — COMPLETE 2026-11-26

- base_commit: dc6c8ab (cycle-11 close); content commits 34f2f49 (D-31 fix + test +
  snapshot codec v3), 60d3b63 (issue doc), 5856ee4 (v130 forensics evidence),
  ec59c0a (forbidden-token reword, comment-only), 878b736 (fix131 lane evidence),
  2b1b563 (scratch-lane from-scratch old-guard trip receipt), 8a1fe33 (v19 authority).
- candidate binary: evidence/runs/cycle12-verify-v19-20261122/deck/ecosys_ng
  - sha256 e522a1f67d52cbd8ca398f86622d9b50164654fb91c376492afc4d21517f9be3
    (deck == build ship130_p19/a, bit-identical, verified at relocation 2026-11-26;
    deck inputs diff -rq IDENTICAL to prod-examples Cool Temperate Maize-Soybean ON)
  - __text section 0x7544ac sha 58e2c7a769ecf4308e75, double-build stable
    (ship130_p19/a vs /b; re-verified after comment-only ec59c0a as ship130_p19c);
    zero probe strings in tree or binary; toolchain zig 0.17.0 aarch64-macos
    -O ReleaseSafe.
- source identity: tree at content commits above; D-31 ship diff = guard predicate
  (zoneHoldsLegacySolution: zone water = fraction*carrier_volw vs legacy
  ZEROS2=1e-6*DH*DV floor; solute.f:533/539 + starts.f:94/:270 parity; NO legacy
  molarity bound exists in f77src) + ReactionParameters plumbing (defaults keep all
  builders strict) + failure_snapshot codec v3 + discriminating test (neuter-
  discriminated: neuter fails EXACTLY the new test).
- behaviour receipt (lane): fix131 lane (resume @29184, same __text) ran 5026 h past
  the historical trip hour 29422 to 2001 d335 (wh 34448): ZERO
  SoluteConcentrationExceedsWaterMolarity, ZERO conservation violations, ZERO
  hourly-science failures; planned SIGTERM stop; evidence
  audit/runs/ottawa/cycle12-fix131-20261122 (878b736).
- old-guard from-scratch trip confirmation: scratch probe lane (pre-D-31 engine, hour
  0 start) TERMINATED at exactly wh 29422 SoluteConcentrationExceedsWaterMolarity,
  sci=0 cons=0 through death (audit/runs/ottawa/cycle11-v130b-scratch-20261119,
  2b1b563) = independent reproduction of issue-130 on the pre-fix guard.
- boot parity: v19 first-40-day lines bit-identical to v18 (elapsed_ms stripped) =
  D-31 inert before the sliver regime (BOOT_PARITY.txt in v19 run dir). Stronger:
  'recovery ladder exhausted' baseline count through wh 3888 IDENTICAL v18 vs v19
  (333 = 333) AND through wh 6000 (2042 = 2042); v18 whole-run baseline 4242
  (pre-existing class, not D-31-induced).
- suites: debug RC=0, ReleaseSafe RC=0, test-module RC=0 (4425 tests),
  test-executable = exactly 1 crash = known issue-115 OOB baseline shape
  (unchanged; fix115 = separate backlog item).
- authority campaign (audit/runs/ottawa/cycle12-verify-v19-20261122, engine sha
  e522a1f6...): FROM SCRATCH, all four milestones passed with ZERO failures —
  day 713 = total_hour 17115 (D-30 hour, v17's exact terminal) clean; day 789 =
  18939 (cycle-11 target, issue-121 hour) clean; day 1226 = total_hour 29422+
  (issue-130 trip hour 2001 d130 h22, terminal of v129c/v18/scratch/v130a) PASSED =
  FIRST-EVER authority pass through issue-130; continued to 2001 d363 (day 1463,
  planned SIGTERM stop 2026-11-26, receipt exit_code -15 intentional; elapsed 390,447 s).
  FINAL COUNTERS solute=0 sci=0 cons=0 FATAL=0; every one of 1463 days conservation-
  accepted; ladder/daily warnings all within documented non-fatal baseline families
  (issue docs + issues.md doctrine entries; watcher incidents p1/p2 = baseline families
  2026-10 bounded supply-cap + soil-heat recovery probes, both proven present in v18 whole-run).
- no gate/tolerance/physics loosening: guard decision set identical for every zone
  legacy actually reads (zone water > ZEROS2); zones at/below the legacy floor are
  invisible to legacy chemistry (CNO1=0.0) and now likewise to the port-only
  molarity guard; NO molarity bound value, NO tolerance, NO physics constant moved.
- next frontier (cycle 13 candidates): issue-115 test-EXECUTABLE OOB fixture
  (hourly_heat_water_solute.zig schedules OOB at fixed external hour recovery,
  baseline shape); sub-ZEROS2 zone-read kinetics parity audit (sliver concentrations
  feed solver kinetics where legacy evaluates 0 - P130C showed ~0 rates, chronic
  science-parity watch); TEMP_DIAGNOSTIC removal; N/P long-run watch; the 2026-10 bounded-cap follow-ups.
