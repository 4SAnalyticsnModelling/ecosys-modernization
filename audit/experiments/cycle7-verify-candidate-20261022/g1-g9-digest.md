# Cycle 00007 gate evidence digest — issue-117 tillage host-root litter booked into the plant sink

Candidate: ReleaseSafe binary sha256 d963eaeda78b3e8fa4294d0eb6f4d33328c1ca0557c1bc7feda75962aea510f3
(deck copy == install artifact, single link; identity is source+toolchain pinned — commit 59e27cd,
zig 0.17.0; Mach-O LC_UUID makes relinks differ byte-wise, so equivalence is claimed at output level,
per the cycle-6 linker-nondeterminism disclosure).
Fix (booking/parity only): the tillage host-root leg now feeds the plant-side litter arrays
(bookTillageRootLitterInPlantSink, disturbance_management_dispatch.applyEvent layer loop), mirroring the
harvest/death root leg (plant_harvest_runtime_apply.zig:1767-1771) and legacy grosub.f:10292-10370, which
books the same live root removal into the CSNC/ZSNC/PSNC surface litter the budget counts. Secondary
legacy-parity edits: the seed-storage and standing-dead tillage legs re-read the LIVE pools at leg time
(grosub.f 10541-10551 / 10250-10264) instead of the entry snapshot; bit-safe no-ops while snapshot==live,
proven by the parity below. No physics, tolerance or gate change.

## G1 builds (Zig 0.17.0)
- zig build install -Doptimize=ReleaseSafe RC=0 (clean); candidate deck binary sha above; Debug test
  compile RC=0. No engine files touched outside scope (git diff --stat = dispatch +54, apply +23/-6).

## G2/G3 verification (from scratch, pristine scenario deck)
- Run audit/runs/ottawa/cycle7-verify-candidate-20261022 (deck evidence/runs/cycle7-verify-candidate-20261022/deck,
  verbatim copy of the read-only scenario directory + candidate binary; no resume, no checkpoint reuse).
- 1999 d140 daily conservation ACCEPTED: stderr.log:70059, carbon residual 2.014808080157643e-14.
- Zero HourlyPlantConservationFailure in the entire run (grep count 0). 557 accepted daily conservation lines.
- Bit-parity vs cycle-6 verified run (evidence/runs/cycle6-verify-scratch-20261022 outputs): all 34
  modelled-output files identical for every shared row through 1999 d139 — 89,712 rows, 0 mismatches.
  The fix therefore changes output only in the executed defect hour and beyond (root litter now booked),
  with zero drift before it.
- Diagnosis evidence (pre-fix, same binary lineage, probes): audit/runs/ottawa/cycle7-probe-scratch2-20261022
  TEMPDIAG at 1999 d140 — seed leg books exactly (seed 1.32, booked 0.132, removed==booked); the whole
  residual 2.328132700984975e-6 g C (N 8.04e-8, P 8.0e-9 class) equals the host-root removal that had no
  plant output leg. The earlier stale-snapshot hypothesis is explicitly SUPERSEDED by these numbers.

## G2 trajectory verdict
- Frontier advanced 1999 d140 -> 1999 d193 h2 (total_hour 13370). Engine exits there with a NEW distinct
  defect SoluteReactionAcceptedStateConservationFailure (nitrogen retained-state inventory residual
  4.23e-11 vs limit 7.36e-13, cell 0 layer 0) — registered as issue-118 with evidence lines; not caused
  by this cycle's booking (post-defect-hour trajectory, different subsystem).

## G4 suites/tests
- tests-module ReleaseSafe RC=0 (clean quiet pass, serial); tests-module Debug RC=0 with 0 error/panic/FAILED
  lines (2,429 warning lines of pre-existing solver-guard test noise). 4405 tests total incl. 1 pre-existing
  skip (count receipt: bash-159). New discriminating check in scope: "issue-117 tillage root litter is booked
  into the plant litter sink for every element"; end-to-end discriminating evidence = scratch2 failure vs
  candidate acceptance at the same hour.

## G5 scope discipline
- Changed: ecosys-ng/src/management/disturbance_management_dispatch.zig, plant_harvest_runtime_apply.zig
  (fix+test); audit/issues issue-117 (resolution) + issue-118 (new frontier); .agent/state.md hygiene;
  audit/experiments/ottawa-resume-deck-tools/build_resume_deck.py repo-root path fix; audit/runs/ottawa/
  cycle7-* evidence. All TEMP probes stripped before candidate (grep probe_/TEMPDIAG = 0 in engine sources).
- Untracked files unrelated to this cycle (.DS_Store, audit/reviews/turn-error-recovery-20261018/*) preserved.

## G6 disclosures
- Two transient test-suite "failures" (jobs bash-225/238) were parallel zig build cache collisions with my
  own foreground builds, not real; resolved by strict serial reruns (bash-234/249 + final RC=0 runs).
- Deck hygiene: cycle7-probe-scratch, cycle7-probe-scratch2 and cycle7-verify-candidate decks are CONSUMED
  (their runs advanced/died mid-trajectory); never resume from them. The scratch2 binary contains log-only
  probes (identical numerics; replay-confirmed) and must not be used for verification.
- Restart-fidelity observation (from resume-deck experiments, cycle-7): deck-restored state at 1999 d140
  diverges from the in-memory state at the first advanced hour (heat guard vs conservation failure), so all
  issue-117 diagnosis/verification used from-scratch runs. Kept as a backlog note (no issue opened).

## G7/G9
- doc_consistency.py consistent:true (re-checked pre-close); this digest + receipts bound every claim; close
  stages owned paths only.

## G8 (remote equality)
- Push at close; HEAD==origin/main verified after push (recorded in cycle.json close entry).
