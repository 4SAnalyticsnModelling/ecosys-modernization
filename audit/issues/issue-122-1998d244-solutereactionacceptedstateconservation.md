# issue-122: SoluteReactionAcceptedStateConservationFailure at 1998 d244 h16 (total_hour 5848) - fatal accepted-state tier on the cycle-11 v7 trajectory

Status: OPEN (registered cycle 00011 from the v7 from-scratch verify run; fix designed same cycle, verification shared with issue-121 per D-18).

## Evidence

- Run: audit/runs/ottawa/cycle11-smoke-v7-20261026 (binary 39033e28c8803f1eef87431138d57b64467972d90a32a84b03e9926a8d2d1d96,
  v7 = issue-121 validator-mirror organic sum completion). EXITED 1 at
  `error: hourly science failed: ... scene_hour=5848 total_hour=5848 year=1998 day_of_year=244 month=9 day=1 hour=16
  error=SoluteReactionAcceptedStateConservationFailure`; last accepted hour 5847.
- Immediately preceding: 40 `SOLUTE retained-state inventory failure: inventory=nitrogen_mol_per_m3` rejections
  (residuals +4.96e-10..+2.22e-9 vs limit 2.21e-11; retain tier correctly refused, non-fatal per issue-118),
  then 1 `SOLUTE accepted-state charge failure: before=6.88236781746563e2 after=6.882367816659954e2
  residual=-8.056758815655485e-8 gross_scale=7.340204267502521e2 limit=3.3532203720535187e-10` -> FATAL.
- Not in the cycle-10 unfixed trajectory (789 days, same window, zero AcceptedState fatals; the v7 trajectory
  diverged at 1998 d1 by design - chaotic re-exploration, 3x SOLUTE non-convergence rate in this regime).
- Fast lane: failure snapshot `ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day244-hour16.bin`
  (auto-written, kept in evidence/runs/cycle11-issue122-repro deck logs) replays offline in seconds via
  ad-hoc `ecosys_ng_replay_solute` (receipts .tmp/cycle121/replay122-{a,b,c,d}.{out,err}).
  Resume-from-checkpoint lane (restart.manifest@5760, f25y98 resume=YES) reproduces the fatal in ~10 min:
  audit/runs/ottawa/cycle11-issue122-repro2-20261026 (EXITED at same hour, same warning census).

## Root cause (VERIFIED by TEMP122 probes, .tmp/cycle121/probes-121/122-attempt1.patch)

- TEMP122A stage tags pin the fatal to reaction_solve.zig requireAcceptedStateConservation CHARGE closure
  (accepted-hour tier, called after equilibrium closures 0/1 declare convergence), reached from the
  :1026/:1074 hard `try` sites. The terminal best-bounded publish tier never fired (no TEMP122T).
- Species census (TEMP122R/A splits): the leak is concentrated in the ammonium/ammonia/exchanger and
  nitrate packed-vector block (NH3-nonband swings 4.5e-5 -> 7.6e-4 on rejected search iterates);
  charge leak -8.06e-8 on the final "converged" iterate = 240x its 2048-ulp limit, nitrogen +2.17e-9.
- Mechanism class = issue-118: vector-space Anderson/Picard mixes are legitimate non-conservative search
  points; here the closure declared success on a state that still violates the elemental/charge censuses.
  issue-118 fixed only the retain tier; the accepted-hour tier kept a HARD abort, and the hourly recovery
  ladder (soil_chemistry_convergence.zig / hourly_heat_water_solute.zig:12244-12251) accepts only
  Stagnated/DidNotConverge classes -> this class aborts the run.

## Fix (leader, bounded, issue-118 precedent)

reaction_solve.zig: at the two production accepted-hour tiers, a
SoluteReactionAcceptedStateConservationFailure from requireAcceptedStateConservation is reclassified as
error.SoluteReactionSolverDidNotConverge after the errdefer rolls the state back to the validated entry
(never published). The hour then enters the EXISTING chronic recovery ladder (finer substeps,
best-bounded-iterate / stiff-image publication), whose every publication re-checks the identical
conservation gates. No gate, tolerance, or publish check is weakened: a leaking state is still never
published; only the fatal-vs-recoverable routing changes, matching the documented issue-118
resolution signature (post-fix replay of the issue-118 snapshot also terminates as chronic
DidNotConverge).

Falsifier (achieved offline): replay of the day244 snapshot with the fix terminates as
SoluteReactionSolverDidNotConverge instead of the fatal (.tmp/cycle121/replay122-d.err).
Remaining: discriminating unit test, engine resume-smoke past 5848, then the shared from-scratch
verification (must also carry issue-121 through 2000 d60 h3).
