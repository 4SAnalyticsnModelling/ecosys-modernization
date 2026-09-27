# Unresolved gaps (SENTINEL worklist)

Short index of what blocks the next gate. One line per item: ID, gate, owner role, blocker, evidence path.
Replace lines as items close; history lives in `audit/issues/` and `.agent/archive/`.
Open-issue census: `uv run ecosys-audit/scripts/issue_status.py --summary` (after T-00005: 105 issue files;
50 open, 55 closed, 0 need normalization; keyword classification, not a verdict).

## G0 (current)
- G0-1 | DONE 2026-09-25 | P0.1 dirty work parked on local branch `wip/pre-plan-2026-09-25` (fe3c489)
- G0-2 | DECIDED 2026-09-26 T-00078 | P0.2 D6 list SIGNED-SAGE (D9): DEV-005 KEEP (legacy parity), DEV-004/006
  REVERT (confirmed T-00036), DEV-007 REVERT-decouple (done T-00046/49), DEV-008 ACCEPTED (T-00076). Only the
  deck-half revert of `9253d3b` (G0-2a) remains to implement | `audit/intentional-deviations.md` DEV-004..008
- G0-2a | FORGE (deck-half open) | Zig half reverted T-00037/T-00038; deck `runottawa` still f6=200, restore blob
  `ecf5e61a…` with SAGE diff-bound review. Earlier: T-00035 D6 decision on DEV-004: REJECTED-REVERT (revert deck f6 200->100 and
  `iteration_control.zig:150` 200->100 of `9253d3b`; hour-2,589 SOLUTE exhaustion becomes a defect to root-cause).
  The STARTE clamp is now listed as DEV-007 and decided in T-00045: decouple SOLUTE/STARTE ceilings from f6 (FORGE) | `.agent/results/T-00035.md`, `.agent/results/T-00045.md`
- G0-2b | PATHFINDER->SAGE | Legacy MRXN semantics not reproduced by any Zig ceiling: per-sub-cycle kinetic rates /MRXN
  (`solute.f:112-118,368-402`) vs Zig single closure with relaxation caps unbounded (`reaction_solve.zig:73-129`), and
  hourly rain/irrigation input equilibration using the STARTE ceiling (`hourly_process_driver.zig:634,670`) needs its
  legacy counterpart identified. Unlisted; not a D6 approval | `.agent/results/T-00044.md`, `.agent/results/T-00045.md`
  T-00078: moved OUT of the G0 gate to P3 (Ottawa-path science audit) together with the hour-2,589 SOLUTE exhaustion
  root-cause; D6 requires the revert for G0, the root-cause is P3 science work. Wet-hour input path superseded by DEV-008.
- G0-2c | DONE 2026-09-26 (DEV-008 ACCEPTED T-00075/T-00076) | DEV-008 fixed-pH STARTE dynamic-input revision (T-00060) exists as uncommitted working-tree
  diff (diff-hash 53175e5b...2618) but its FORGE result was lost; T-00063 decided: no re-implementation (T-00061/62
  superseded), SAGE reviews the diff directly with the quarantined claims copy | `.agent/results/T-00063.md`
- G0-3 | PARTIAL | P0.3 partial legacy set (hours 1-6,875) preserved in `evidence/legacy/` with manifest
  (T-00007/8); the full 30-yr outputs do not exist and come from the P0.4 rerun
- G0-4 | PATHFINDER | P0.4 full legacy rerun + -O2 timing x3 from the run-002 recipe (after G0-2 is signed) | plan P0.4
  T-00078: UNBLOCKED. G0-2 is signed, and no D6 item changes legacy inputs (legacy reads no runtime f6, `reads.f:126`
  per T-00045; legacy hardcodes `CN4X=0.1*CNH4` at `starte.f:189`), so the legacy rerun need not wait for G0-2a
  T-00140 DECISION (SAGE): external-archive search CLOSED (T-00134..T-00139 all BLOCKED; run-002 outputs were never
  hashed, plan §0 row "Legacy oracle binary", so no recovered copy could be evidence-bound). Sole path = fresh P0.4
  legacy ▲ (budgeted, plan §5 row P0). Owner FORGE, task-authorized for legacy gfortran runs only (no Zig ▲).
  Step 1 bounded: build + exe sha256 + staged deck hashes + 1-day warmup. Step 2: ▲ to full horizon. Reopen condition
  in `.agent/results/T-00140.md` | `.agent/results/T-00140.md`
- G0-5 | PATHFINDER | P0.5 `tracecov.py` stale-hash report (report only, do not refresh) | issue-081
  T-00085 DECISION: all P0.5 outputs go to `audit/analysis/` (PATHFINDER lane); `audit/traceability/` is
  read-only for G0. Deliverable: fresh tracecov report + per-row classification of every stale-zig-sha256 row
  (UNCHANGED-RANGE / CHANGED-RANGE / NO-MATCHING-BLOB) by locating the git blob whose sha256 the row cites.
  Hash refresh of the ledger is NOT a G0 exit item; it is a later re-review step | `.agent/results/T-00085.md`
- G0-5a | open, write-authorized ledger task (not a G0 exit item) | T-00108 DECISION: TRC-313..340 live
  anchors are valid (13 file sha256 match T-00106), BUT the REFRESH-LEDGER hash-only disposition is REJECTED for
  TRC-331..340: live code now holds the ZEROS2 floor fixes (issue-072/073) those rows call "unresolved, not
  fixed", so a hash refresh would re-certify false text. TRC-336's subject `updateFertilizerBandGeometry` was
  removed (ISSUE-103; anchor is a caller-less helper): re-scope or retire. TRC-313 disposition to be cross-checked
  against DEV-004/007. TRC-315/318/321/326: hash+lines refresh only | `.agent/results/T-00108.md`
- G0-5b | DECIDED 2026-09-26 T-00111 (SIGNED-SAGE), ledger write pending | Final dispositions for the TRC-313/331..340 cluster.
  TRC-313 -> `unresolved`: the `legacy-defect-corrected` claim is retracted. MRXN=60 is a fixed sub-cycle count, and
  that is not a defect. The Zig 100 is a fail-loud ceiling (DEV-007/T-00045). The semantic gap is G0-2b (P3).
  TRC-331..335/337..340 -> stay `unresolved` with corrected text. The live floors exist, but production binds
  them to `physical_tolerance.water_volume_m3` (default 1e-14 m3, `config.zig:17`; `biogeochemistry_batches.zig`
  :24,26,138,157,177,195,374,617,779). That is not ZEROS2 (1e-6*area m3, `starts.f:94,270`), even though the code
  comments claim it is. CCO2S/CNO2S legacy uses ZEROS (`hour1.f:3777`). TRC-339's `nitro.f:2955` is not a guarded
  division. TRC-336 -> `retired-with-explicit-scope-approval`: its subject was removed (ISSUE-103), and the
  caller-less helper `soil_chemistry_convergence.zig:102-134` should be deleted or re-homed | `.agent/results/T-00111.md`
- G0-5c | DECIDED 2026-09-26 T-00119 (SAGE): T-00118 matrix REJECTED as the final legacy binding. It binds
  TRC-337 (CCO2S) to `solute.f:610` ZEROS2, which contradicts G0-5b and `hour1.f:3777-3778` (ZEROS). It cites
  `nitro.f:2948-2958` for TRC-338 as a water-volume guard, but that range has no VOLW guard (`RN2BY>ZEROS`, `VMXC4S`).
  TRC-331..335 and 338 carry mineral N/P/NO2 carrier analogs that legacy computes under ZEROS
  (`hour1.f:3804-3836`; L=0: `hour1.f:4605`). `solute.f:610` is the ZEROS2 gate on the solute-equilibrium
  sub-cycle, not a concentration carrier. The ledger may be rewritten now only for TRC-313, 336, 339 and 340.
  TRC-331..335/337/338 need a row-by-row ZEROS-vs-ZEROS2 re-derivation first | `.agent/results/T-00119.md`
  CLOSED 2026-09-26 T-00130 (SAGE): the row-by-row re-derivation is done and final (T-00125 -> T-00126 REVISE ->
  T-00127 -> T-00129 APPROVE; T-00130 re-confirmed that all 10 anchor sha256 values are unchanged). All seven rows bind ZEROS
  (`hour1.f:3777-3791`/`3804-3836`, `starts.f:93,269`), and the T-00127 packet is final with reviewer `SAGE T-00129`.
  The disposition stays `unresolved`: production uses 1e-14 m3 where legacy uses 1e-15*DH*DV (G0-5b). The only remaining step is
  the FORGE write to traceability.csv, which is still pending: the T-00129 chain was not applied.
- G0-4r | FORGE (T-00158 DECIDED) | Swarm deadlock while P0.4 campaign runs: detached driver (lock PID 41728)
  rewrites tracked `audit/runs/p04-full-campaign/heartbeat.json` every 30 s; `swarm_wrapper.py:1005-1023` attributes it
  to the agent whose turn it is and restores it, so every SENTINEL/SAGE turn is quarantined (route-1790468130/-183).
  Fix in `swarm_wrapper.py` only: exclude the live machine-lock holder's heartbeat/driver.log from scope attribution.
  T-00164 (SAGE, 3rd recurrence, route-1790468601): unchanged decision; dispatch `.agent/tasks/T-00163.md` to FORGE as written.
  Do NOT touch the pinned driver or the running campaign | `.agent/results/T-00158.md`
  T-00161 (2026-09-26): still open. T-00158 was FAIL-collected on the same defect, so its CHAIN was dropped.
  T-00167 (SAGE, 4th recurrence, route-1790468772; T-00164 FAIL-collected as F-00012): the loop is structural
  (`swarm_wrapper.py:1018-1027` fails every non-FORGE turn while the driver writes). Decision unchanged: FORGE runs
  `.agent/tasks/T-00163.md`. If this CHAIN is dropped too, the campaign keeps running; the first turn that passes
  (at the latest after the lock is released) dispatches T-00163, and no detached campaign is relaunched before it lands.
  Route-1790468357/-415 were also quarantined, only for the heartbeat. Re-chained to FORGE with the same scope
  (T-00160 text). FORGE's lane includes `audit/runs/`, so a FORGE turn is not quarantined | `.agent/results/T-00161.md`
  T-00170 (SAGE, 5th recurrence, route-1790468953; T-00167 FAIL-collected as F-00013): duplicate of T-00167, not re-decided.
  FORGE runs `.agent/tasks/T-00163.md`. The controller must dispatch a SAGE CHAIN whose only scope problem is this heartbeat.
  T-00173 (SAGE, 6th recurrence, route-1790469137; STRATEGY CHANGED after stagnation): `swarm_wrapper.py:1143,1189`
  dispatches a CHAIN only from a DONE SAGE result, and a scope hit forces FAIL, so no SAGE/SENTINEL turn could pass
  while the driver lived (deadlock, not a delay). SAGE stopped the campaign at 2026-09-27T00:35Z (oracle PID 24744
  killed; driver 41728/launcher 41452 exited; heartbeat `FAILED`, elapsed 1446 s, run_1 of 3). That run_1 "failure"
  (exit 4294967295) is the deliberate kill, not model science. Next: SENTINEL dispatches T-00163 to FORGE. After it
  lands, FORGE relaunches P0.4 from scratch with the same pinned driver (E3F55330...) and exe (63DD7D5F...).
  T-00179 (SAGE, 7th recurrence, route-1790471467/-518 after the T-00176 relaunch): the T-00175 fix is correct on disk
  (checked by calling `campaign_exempt_paths()` from a new process: it returns heartbeat.json + driver.log, LIVE_LOCK),
  but the controller running the swarm (PIDs 36484/8084, `swarm_wrapper.py run --resume --max-steps 500`) was started at
  2026-09-26 10:05 local. `swarm_wrapper.py` last changed at 18:49 (T-00175), and the controller never reloads it
  (T-00175 result:29). The precondition "after controller restart" (T-00175:32) was skipped, and T-00176's "permanently
  resolving" claim tested a new process, not the controller. SAGE stopped the campaign again at 2026-09-27T01:14Z
  (oracle 44400 killed, driver 43324 exited, heartbeat `FAILED`, elapsed 425.91 s, run_1 of 3; deliberate kill, not science).
  Next: FORGE restarts the controller. P0.4 is relaunched only after the controller's process CreationDate is later
  than the mtime of `swarm_wrapper.py`.
  T-00184 (SAGE, 2026-09-26): the `RUN_FAILED` receipt T-00183 read (`p04_full_run_receipt.json` sha256 d9ed4644...,
  exit 2, 97.776 s, warmup 2026-09-26T23:52:43Z) is STALE. It matches HEAD (last commit ac6fc51, T-00154) and predates
  the live driver 41688 (started 2026-09-27T01:28:02Z) by about 1.6 h. The current campaign is alive: it holds the lock
  (the file cannot be read, EBUSY), the heartbeat reads `RUN_1` at 420 s, and run_1 outputs were written at 01:34:48Z.
  DECISION: continue the campaign and do not restart or supersede it. Only the receipt that driver 41688 writes counts.
  Still open: the cause of the early exit-2 run_1 failure (about 17:52 local) was never found. If the live run exits
  non-zero, PATHFINDER reads `run_1` logs before any relaunch.
  T-00191 (SAGE, 2026-09-27T01:50Z, re-asked via T-00188..T-00190): T-00184 REAFFIRMED, not re-decided. The receipt
  d9ed4644... is INVALID as the status of the live attempt. Driver 41688 (argv has the same `--out`) and oracle child
  41592 (started 01:28:20Z) were alive at 01:50:23Z. The heartbeat read `RUN_1` at 1321 s, and run_1 outputs were written
  at 01:49:32Z. The premise of T-00189, "after the process termination", is false. DECISION: no exit-path audit before
  the live run ends, and no kill, retry or relaunch. The only next evidence is the terminal receipt that 41688 writes
  over the same path. SENTINEL routes no further P0.4 receipt tasks while 41688 holds the lock. Correction to T-00184:
  run_1 was restaged at 01:28:17Z, so the logs of the exit-2 attempt are gone. Its only remaining evidence is receipt
  d9ed4644... and the first-attempt text in driver.log. The exit-2 cause stays open. It blocks P0.4 acceptance only if
  the live receipt is non-zero or its exe/deck hashes differ.
- G0-6 | DONE 2026-09-25 | P0.6 issue Status lines normalized (T-00005; SAGE-approved set T-00003)

## Carried from the pre-plan loop (feed P3/P4, do not chase serially)
- issue-108 cations: Ca/Na/K layer-2 residuals at hour 3,289 | `audit/issues/issue-108-*.md`
- issue-106 test 71 substep ladder; issue-107 test 109 run-log lock spin | test-root failures (P3 item f)
- issue-099 PO4 band activation; issue-093 litter-carbon composition; issue-097 reference-doc import
