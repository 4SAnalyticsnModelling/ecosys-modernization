# Cycle 00011 gate digest (v18 authority)

- base_commit: 2db8c22 (cycle-10 close); content commits 9c1c646 (D-26/27/28) and 8af954d (D-30).
- candidate binary: evidence/runs/cycle11-verify-v18-20261117/deck/ecosys_ng
  - sha256 d429893e775978385ba32a6c082baf4a671c2c7d77ad0e1c2cdf34380d29c06d (deck == build ship130_p18, bit-identical)
  - __text section 0x753a7c sha 0f51d90b505319b45c3f, double-build stable (ship130_p18 vs ship130_p18b), zero probe strings
  - toolchain zig 0.17.0 aarch64-macos -O ReleaseSafe; pristine scenario deck (inputs bit-identical to v17 deck; engine swap only)
- source identity: tree at 8af954d; ship diff vs 9c1c646 = src/stages/hourly_heat_water_solute.zig only (+64/-3: D-30 producer-tolerance predicate fn + guard + issue-129 test).
- campaign: from scratch, run_logged, hours 0..29422, EXITED 1 at issue-130 terminal (see V18-AUTHORITY-RECEIPT.txt); cycle-11 target wh 18939 (issue-121) passed with zero failures; cons=0 acc=0 sci=0 through day 1225 up to the issue-130 hour.
- authority chain: v17 (p17, source 9c1c646) EXITED 1 at wh 17115 AcceptedTopsoilVaporPoreOverfill = issue-129 authority receipt (713 d, cons=0, 165 bounded publications).
- suites (both configs): identical baseline shape to v16/v17 - testmodule rc=0; debug/releasesafe 1 skip + the single known issue-115 baseline crash; issue-129 test present in test-executable graph, neuter-discriminated.
- no gate/tolerance/physics loosening: D-26/D-27/D-28 add producer provenance channels only (validator-read fields previously unwritten); D-30 sets the consumer guard tolerance to the EXACT producer predicate max(1e-12, 64*eps*max(1,caps)); genuine corruption past producer tolerance stays fatal.
- next frontier: issue-130 SoluteConcentrationExceedsWaterMolarity at wh 29422 (2001 d130 h22 scene 4), forensics banked in audit/issues + .tmp/cycle121/deck-29184-snapshot (lane v130a P130 series).
