# issue-119: InvalidPlantInventory at 1999 d286 (post-issue-118 frontier)

Status: REGISTERED at cycle 00008 close (fix scope = cycle 00009).

Evidence (audit/runs/ottawa/cycle8-verify-candidate-20261023/stderr.log, exit_code=1):
- 85636: info: day advanced: scene_weather_hours=6840 final_hour_elapsed_ms=633  (last completed hour;
  scene 2 = 1999, so 6840 = 1999-10-12 24:00; failure inside 1999-10-13, total_hour 15601..15624)
- 85637..85680: run-summary/telemetry dump (normal teardown), then
- 85681: error: InvalidPlantInventory  — first occurrence of this class in ANY archived run
  (grep across all audit/runs/ottawa/*/stderr.log; only cycle-8 log matches).

Throw site (static): ecosys-ng/src/validation/landscape_mass_inventory_plant.zig:147 (salt cation
non-finite/negative) or :157 (C/N/P element value non-finite/negative) inside the landscape plant
aggregate validator (addSalts/addCnp). The error carries no hourly context line (validator raised
during hour processing before the "hourly science failed" wrapper or outside it — cycle 00009 must
pin which leg and hour; the run summary printed first indicates teardown-on-error ordering).

Trajectory context:
- The run cleared issue-118 (1999 d193 h2) cleanly; the retained-state guard now yields 46 warning-level
  rejections (stderr 74798..74846, all inside the d193 window) and zero fatal channels — expected fixed
  behaviour, NOT part of this issue.
- Chronic ladder-managed solute events continue: "published best bounded iterate" 253 total (cycle-7
  through-frontier count 222 at this date); auto failure snapshots written 1999 day 253 h19 and day 275
  h14 (ladder-managed, non-fatal) in deck runottawa_output_files/logs/.
- Season context: d286 is post-senescence autumn (maize/soy ON); plant pools near end-of-season minima —
  plausible first-touch class for a negative/NaN pool leg (UNVERIFIED hypothesis; no diagnosis yet).

Reproduction: from-scratch run only (restart-fidelity caveat: deck-restored state diverges; cycle-7
finding). Deck evidence/runs/cycle8-verify-candidate-20261023/deck is CONSUMED. Build command and
receipt: audit/experiments/cycle8-verify-candidate-20261023/g1-g9-digest.md.

Frontier: last accepted hour = 1999 d285 h24 (scene_hour 6840; total_hour 15600) — advanced from
issue-118's h13369 by 2,231 hours (~93 days) of clean trajectory.
