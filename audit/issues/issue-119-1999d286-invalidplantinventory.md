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
- HARVEST correlation (VERIFIED from stderr.log): the last log line before teardown is 85654
  "warning: TEMP_DIAGNOSTIC harvest root layer: plant=0 layer=1 litter_c=3.0413572522379505e-4
  gas_c_released=9.275198089236798e-6 removed_fraction=1e0 host_removed_c=3.04135725223795e-4" —
  the abort happens in the 1999-10-13 harvest hour. The 1998 harvest ran on the same day-of-year
  (scene1 hours=6840 marker, stderr.log:68263, litter_c=4.2104214716662405e-4) and was ACCEPTED
  (bit-parity vs cycle-7 covers it). Producer suspect = a harvest leg (roots layer leg logged;
  reproductive/branch-stalk/reserve legs precede) leaving a negative or NaN element in an aggregated
  plant pool (salt cation :147 or C/N/P :157) before the hourly landscape-balance reconstruct
  (stages/diagnostics.zig:147 -> ecosys_ng.zig:5906) validates it.
- Daily conservation ledgers accepted through day 285 (stderr.log:85635).
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

## RESOLVED (cycle 00009, 2026-10-25)

Root cause (VERIFIED via deterministic probe ladder attempt3->attempt5, receipts
audit/runs/ottawa/cycle9-probe-d286-20261024-attempt{3,4,5}-*):
- 1999 d286 kill morning: the DAILY GROSUB 12655-12890 plant-salt block (ecosys_ng.zig:3971 ->
  plant/salt/harvest_adapter.applyPlant) stages root salt into its workspace; the mortality C pass
  has already zeroed the workspace-visible root carbon, so total_carbon == root_litterfall_c and
  litter_fraction == 1e0 exactly (receipt: lf_c == sumC == 3.0413572522379505e-4).
- With litter == total, the per-root subtraction in salt/harvest.zig state_updateRootRemoval
  computes removal = total * fl(w / total), which double-rounds UP by exactly one ulp of w for
  w = 1.9066168787981847e-16 mol: total * fl(w/total) - w = +2^-105 = +2.465190328815662e-32
  (reproduced bit-exactly). Pool becomes -1 ulp; harvest_adapter.zig:152 wrote the staged value
  back unclamped; the hourly validator (correctly strict) aborted with InvalidPlantInventory.
- The 1998 same-date kill passed because the rounding did not overshoot there (different pools).

Fix (harvest.zig, this cycle): clamp the negative residue to zero and charge the litterfall output
the REALIZED removal, so the plant/litter salt ledger closes exactly; the non-negative path keeps
the identical arithmetic sequence (bit-safe). No validator, tolerance, or gate change.
Legacy parity: legacy ZEROP-to-zero cascade class (f77src hazards fixed in Zig per AGENTS.md).

Verification (audit/experiments/cycle9-verify-candidate-20261025/g1-g9-digest.md):
- From-scratch run accepts 1999 d286 and every hour to 1999 d360 h24 (total_hour 17400);
  zero InvalidPlantInventory occurrences; kill diagnostic byte-identical to the pre-fix abort line.
- 34 files / 115,811 rows bit-identical vs the cycle-8 verified deck (through 1999 d285).
- Suites both configs: tests-module 4407 passed / 1 skipped / 0 failed (incl. discriminating test);
  executable-root shows only the pre-existing issue-115 fixture crash baseline.

Next frontier: issue-120 (HourlyLayerConservationFailure, subnormal oxygen pool, 1999 d361 h1).
