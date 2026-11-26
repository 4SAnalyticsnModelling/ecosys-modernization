# issue-131 — frontier extension: complete the 5-scene Ottawa plan (2002) via verified resume

Status: EXECUTING (cycle 14, opened 2026-11-26)
Owner: leader. Depends on: cycle-12 authority (v19, through hour 35124 = 2002-01-02 12:00).

## Scope
The runottawa run plan is 5 one-year scenes (1998..2002; f25y98..f25y02 exist as forcing
options; f25y03/f25y22 are present in the forcing directory but the plan line is 1,1,5).
v19 authority stopped by planned SIGTERM at hour 35124 — inside scene 5 (2002), 60 h after
the last checkpoint boundary 35064. This cycle extends the verified trajectory to the
plan's natural end (scene-5 completion, expected hour 43824 = 2002-12-31 24:00) using the
v19-identity engine (sha256 e522a1f6…, __text 58e2c7a769ecf4308e75) with NO code change,
then characterizes the terminal state: exit status, counters, ladder-warning profile, and
whether any new failure boundary appears in 2002 (first territory no prior campaign
reached beyond hour 35124).

## Acceptance
- Absolute counters ZERO to completion: hourly science failures, conservation violations,
  FATAL, SoluteConcentration guard trips.
- Trajectory-faithful re-entry proven: failure-snapshot names through the shared region are
  a strict subset of v19's set (already shown at day 2; full-region check at 35124).
- Natural completion: engine EXITED 0 on its own (no SIGTERM), run plan scenes 1..5 all
  published; day-line count 1826 = 365+365+366+365+365.
- Watcher doctrine exclusions remain proven-baseline families only; anything new alarms.
- Evidence: audit/runs/ottawa/cycle14-verify-v20resume-20261126 (stderr gzipped before any
  gate scan), parity receipt in run dir, g-digest kit under
  audit/experiments/cycle14-… per close doctrine.

## Resume mechanics (recorded so the recipe is reproducible)
- Deck = copy of v19 campaign deck at the manifest-embedded root path; keep restart.manifest,
  tile bins, .ecosys-output-bank-35064.bin, .ecosys-output-cursor.bin AND the 60 rolling
  journal bins; flip entry-scene (f25y98) options line 6 resume NO→YES. False-start evidence
  retained: cycle14-v20falsestart-20261126 (flag NO → engine versioned root _v2 and restarted
  1998), cycle14-v20b-untracked-20261126 (journal bins deleted while CSVs carried
  post-checkpoint rows → UntrackedExistingOutputFile; fail-closed correct).
- Engine re-solves from checkpoint 35064 (journals are not replayed as logs); 60-h overlap
  reproduces v19's published hours (bit-parity sampled via identical failure-snapshot names
  and ladder-count windows).
