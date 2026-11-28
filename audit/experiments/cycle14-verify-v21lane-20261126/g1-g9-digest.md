# Cycle 00014 gate digest (issue-131 frontier extension, D-33) — COMPLETE 2026-11-27

- base_commit: b62280f (cycle-13 close). Content commits: 9c7f728 (cycle open),
  3cf4adb (false-start lessons), 9b47252 (issue-131 register), 19d0803 (v20c frontier
  receipt 35065..35282 + boundary 35283), 4a2cc36/a2326f3 (P131/P131B forensic probes +
  trip receipt), 8f5a871 (D-33 status), 8ea6a73 (D-33 v1 producer parity + tests),
  d68d684 (v2 pack-ledger booking), 0e11350 (v3 XHFLWW-parity totals), 43f7099 (lane3
  frontier receipt), 928130d (issue-131 ACCEPTED + issue-132 REGISTERED).
- candidate binary: evidence/runs/cycle14-verify-v21lane-20261126/ecosys_ng
  - sha256 116b438377dadf0231dbaee7e844bc9226e759737203f0959ccc03d3552fea10
    (double-build .tmp/cycle141/ship131/{a,b} bit-identical; lane ran this exact file)
  - __text sha 76233418bbd74420e516... (production change vs cycle-12 identity
    58e2c7a769ecf4308e75, as intended: D-33 changes production physics parity)
  - recipe: zig build-exe -O ReleaseSafe --dep ecosys_ng -Mroot=src/ecosys_ng.zig
    -Mecosys_ng=src/module_index.zig; source_commit 0e11350.
- suites at candidate tree: module+executable x Debug rc=0 (audit/experiments/
  cycle14-verify-v21lane-20261126/suite-{module,executable}.log); ReleaseSafe lanes see
  close receipts (MODRS/EXERS rc=0, /tmp/c14_d33c_*rs.log copied alongside).
- discrimination: NEUTER (floor predicate -> next_capacity>0) fails EXACTLY the
  issue-131 sliver test; restored -> green (receipt /tmp/c14_neuter.log, banked in
  decisions.md D-33).
- science campaign (verification lane, audit/runs/ottawa/cycle14-verify-v21lane-20261126,
  engine 116b438377dadf02...): frozen v19 deck, resume=true from checkpoint 35064;
  PASSED first-ever boundary 35283 (issue-131 trip hour) CLEAN; 2002 days 9..99 = abs
  hours 35065..37439 with absolute counters ZERO (hourly science failures, conservation
  violations, FATAL, SoluteConcentration trips); daily conservation accepted throughout
  (water ~3e-13, heat ~2e-11 class); trajectory-faithful re-entry (snapshot-name subset
  through shared region, FRONTIER_RECEIPT_v21lane3.txt).
- new boundary (next cycle scope, NOT a regression): hour 37445 HourlyLayerConservation
  Failure hydrogen layer_scope=9 residual 2.6438128362738157e-17 g vs effective_limit
  2.5935499041613834e-17 after cell=6 bounded-recovery publication -> issue-132
  (registered 928130d, UNVERIFIED hypotheses H1/H2/H3 in the doc). Engine fail-closed
  EXITED 1 = correct gate behavior, no state published past the defect.
- failure-path forensics retained: cycle14-v20resume-20261126 (v19 engine boundary),
  cycle14-v21lane-ledgerfail-20261126 (D-33 v1 trip), cycle14-v21lane2-cellledger-20261126
  (v2 trip) - each with receipt + gz/plain stderr as listed; every retry was root-caused
  BEFORE relaunch (no unchanged relaunch).
- G1 source/tests green; G2 discriminating tests (issue-131 sliver + above-floor);
  G3 legacy receipts watsub.f:2441-2446, :1227/:1475, starts.f:654/:550 (read-only tree);
  G4 parity audit = D-33 producer-parity record (decisions.md) + v3 three-ledger algebra;
  G5 verification campaign above; G6 gates evidence below; G7 no gate/tolerance/physics
  loosened (v2/v3 ADD bookings; fatals kept above floor; NO bound moved); G9 doctrine
  watcher clean (baseline families only; alarms zero across lane).
- frontier.json UNTOUCHED (P0). Deck retained at .tmp/cycle121/v19-deck (checkpoint
  37224 + journals + day100-hour5 snapshot bin) for cycle-15 resume forensics.
