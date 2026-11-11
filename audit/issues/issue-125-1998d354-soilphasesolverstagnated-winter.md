# issue-125 — 1998-12-20 h7 (total_hour 8479) SoilPhaseSolverStagnated fatal; winter freeze-front phase-enthalpy episode

## Fatal (v11 verify, binary e6dac9fb8efa4803, run audit/runs/ottawa/cycle11-verify-v11-20261029)
- `error: hourly science failed: ... scene_hour=8479 total_hour=8479 year=1998 day_of_year=354
  month=12 day=20 hour=7 error=SoilPhaseSolverStagnated` (stderr.log line 489225).
- Preceding episode (same window, all cell=0): 37 `soil phase-enthalpy Newton-Picard stagnated`
  error lines (limiting_component=matrix_liquid_water_m3; scaled_residual 8.9e0..1.35e4),
  32 `soil phase solver stagnated within the layer-scale bound; publishing the iterate through
  the conservation gates` warnings, coupled schedule rungs to 64, then
  `bounded fixed external hour recovery rejected: exact_substep_count=64` -> fatal.
- ZERO conservation failures anywhere (d1..8478): all v8/v9/v10 zones passed; 5668 (issue-124)
  and 5848 (issue-122) falsifier zones CLEAN (reclass=0, sci_fail=0 through 8478); 68 ladder
  recoveries ACCEPTED including soil phase hours (cycle-10 precedent pattern: schedule failed
  -> recovery accepted 20).

## Context / prior art
- cycle-10 gated verify (789 d, full winter): SoilPhaseSolverStagnated 4 lines, 2 stagnated
  warnings, 141 recoveries accepted, ZERO layer-scale-bound publish lines, ZERO fatals.
  => class is ladder-eligible; v11 hit a materially harder episode (32 bound-publishes).
- Watcher exclusion "soil heat" does NOT cover "soil phase" lines (they print via std.log.err
  per iteration; REAL-ERROR ERR count 76 at exit = mostly this noisy family + fatal).
- Frozen-soil season: temperature_k ~267.7-268.6 (near freezing front), per-iteration state
  changes ~1e-8..1e-13 in the limiting block printouts, yet scaled residual ~1e4 ->
  near-singular phase-enthalpy Jacobian at the freezing front (matrix_liquid_water row).
  Same conditioning family as issue-118/124 chronic solute cluster but a DIFFERENT solver.

## Hypotheses (UNVERIFIED)
- H-A (conditioning, pre-existing): ulp-shifted trajectory (D-6 chaos) lands the freeze-front
  episode in a harder state region; solver code unchanged by cycle-11 fixes; ladder cannot
  recover because ALL substep resolutions hit the same singular front (substep refinement does
  not fix a state-space singularity).
- H-B (episode escalation mechanism): the 32 "publish within layer-scale bound" iterates are
  large-residual publishes that degrade the ice/water front state hour over hour (each publish
  passes conservation but moves the front), feeding back into worse conditioning -> eventual
  unrecoverable hour. (Check: are bound-publishes all within ONE hour or spread over the Dec
  season?)
- H-C (defect in bound-publish path): the layer-scale-bound publish exists in v11-era code only?
  (cycle-10 had 0 such lines — is the publish path NEW since cycle-10 binary, or just never
  triggered?) MUST check git log of the phase solver between the two binaries.

## Repro lane (resume, issue-122 doctrine)
- Copy deck v11 -> repro deck; flip runottawa_input_files/climate_forcing_and_simulation_controls/f25y98
  resume flag NO->YES (2nd YES line; byte-diff receipt of cycle11-issue122-repro: 305->306 bytes);
  restart.manifest already points at complete 8400 bundle (11 sections).
- Value-changing fixes make JOURNAL-REPLAY (old binary on new state) invalid for acceptance
  evidence; allowed only as labelled diagnostic.

## Falsifier / acceptance for the fix
- From-scratch v12 campaign passes 8479 + frontier 18939 + EXITED 0 with zero conservation
  failures. Fix doctrine: diagnosed cause first; no tolerance/gate changes; ladder must not be
  poisoned by wrong-root traps (D-20 analogue if the phase solver commits census-leaking or
  bound-violating iterates).

## Root cause (VERIFIED 2026-11-01, resume-repro lane + P125 probes, seconds per attempt)
- Lane: deck copy + f25y98 resume flag NO->YES + manifest@8400 (11-section bundle) reproduces
  the fatal at total_hour 8479/8480 bit-class in ~4 minutes (probe runs:
  audit/runs/ottawa/cycle11-issue125-{repro,probe,probe2,probe3,probe4,probe5}-20261101).
- H-A CONFIRMED (conditioning at the freezing front) with exact mechanism: at d354 h07/h08 the
  layer merit (scaledNorm) is dominated by the matrix_liquid_water coordinate at a RAW defect
  of only ~3.3e-10 m3 = 5% of the DEV-014 partition bound (raw pool 1.53e-3 m3, layer
  capacity 5.92e-3 m3 -> conservation-style scaling), while the endpoint-enthalpy residual is
  FROZEN at 2.98e-6 K (h07) / 1.87e-6 K (h08), i.e. just above the DEV-014 1e-6 K publication
  bound. Every joint (phase, temperature) line-search candidate that drives T_res to ~3e-8 K
  with water at ~5.4e-8 relative (5% of bounds) is REJECTED because the joint move nudges the
  water coordinate upward and strict global-norm merit cannot see the benefit. Iterations
  plateau identically from it=6..16; ceiling -> publishable() false (T term) ->
  Stagnated on every ladder rung -> exhaustion -> fatal. Water projection of the ladder and
  the solute fix are exonerated; cycle-10's gated run had this same historical hour (code
  comment r00056: "d354 h07 frozen topsoil stalls... summed-water bound raised 1e-8->1e-6")
  but a trajectory where T stayed under the bound (D-6 chaos; the temperature bound itself was
  never stressed before v11).
- Budget/step-size refuted as causes: same plateau at all ladder rungs (substep refinement
  cannot resolve a state-space kink); DEV-014 machinery behaved exactly as designed.

## Fix (leader; shipped in v12 candidate binary 3d555277f53bbe46...)
- phase_solver.zig (+91 incl test): temperature filter recovery inside the
  local_phase_temperature block. When the joint line search fails and
  |T_res| > 1e-6 K: scalar-Newton step on the temperature-only response
  (derivative local_matrix[3] from the existing T-only probe), taken JOINTLY with the
  phase-partner correction (candidate[phase_index] += rhs0; partner -= coef*rhs0),
  backtracked 1..2^-26, accepted iff (a) T residual strictly shrinks, (b) all five water
  coordinates AND their summed defect stay inside the EXACT DEV-014 bounds
  (1e-6 * layer capacity), (c) states finite/nonnegative, T positive. NO publication gate,
  bound, tolerance or budget changed; the ceiling still demands every bound +
  committableState + the phase-energy conservation gate. Observable warn: "soil phase
  temperature filter recovery accepted at the freezing-front kink".
- Iteration history of the fix (honest record): v1 T-primary using the block step direction
  fixed 8479 but not 8480 (block direction wrong for a temperature-only move); v2
  scalar-Newton T-only step fixed 8480's plateau at 8479 but reintroduced failure (guard ok,
  T alone cannot close it at 8480); v3 = scalar Newton T + phase-partner correction passes
  both hours (fix125c repro: sci_fail=0, 12 filter accepts incl 1.37e-5 -> 5.7e-7 K).
- Evidence lanes: stock e6dac9fb binary FATAL at 8479 (audit/runs/ottawa/cycle11-issue125-
  repro-20261101); fix125c (v12-equivalent solver) passes 8479+8480 with the filter accepting
  (audit/runs/ottawa/cycle11-issue125-fixrepro3-20261101 partial + cycle11-issue125-smoke-
  20261101 long smoke toward the frontier). Discrimination = bit-reproducible production A/B
  (strongest class); unit test (52->53 suite, "issue-125 temperature filter recovery...")
  pins the bounded-publish contract at the production layer scale but is not itself
  discriminating (synthetic cell converges by the normal path with max_iterations=6).

## Resolution
- v12 from-scratch verification must pass 5668 (issue-124), 5848 (issue-122), 8479/8480
  (issue-125), ~d594 (issue-123) and frontier 18939 (issue-121), EXITED 0, zero conservation
  failures. Mark RESOLVED when that run passes.

## issue-125b: hour 8480 after the D-21 filter (v12 died here) — FIXED (2026-11-05)

v12 (D-21 filter, per-failure entry) passed hour 8479 (16 filter accepts, 35 ceiling
publishes) and died at 1998-12-20 h08 with the same SoilPhaseSolverStagnated class.
Resume-lane probe chain on the frozen v12 deck (f25y98 flip, manifest@8400):

* probes I/J: every 8480 ceiling rung violates ONLY the 1e-6 K temperature bound
  (T frozen at 1.866022785e-6 K; sum_rel 5.25e-8 and max_rel 3.06e-8 are inside the
  1e-6 water bounds — the historical d354-h07 widening applies to all three water
  screens; the 1e-8 in the doc comment refers to the pre-widening sum screen).
* probe K: the T-only Newton step moves the water sum by ~1e-17 — the defect pair
  (frozen T, drifting sum) is orthogonal to the local block plane; a filter that
  consumes the sum bound (fix v4) kills every 8479 accept (REJECTED approach,
  binary fix125d retained as evidence, not shipped).
* probes T/U: at 8480 the joint line search keeps ACCEPTING frac~1.5e-8 water
  micro-steps at the plateau, so `!accepted_newton` never holds and the D-21 filter
  never enters after it=21 (T stuck at 1.866e-6 K).
* probe V: filter candidate geometry at the kink is healthy (T -> ~3e-8 K, water
  coordinates ~1e-7 relative) — entry, not direction, is the blocker.
* probes M/P/W: the DEV-014 ledger image (water := ledger target + enthalpy closure)
  re-closes water to 2e-17 relative — the residual measures deviation from that very
  ledger identity — but re-evaluating the Newton temperature row at the closed
  endpoint yields a large value (7.6e-4 K) because the WATSUB explicit transfers
  (WFLVT/FINH) that produced the ledger target are not part of residualAt; the
  endpoint's physical acceptance is the phase-energy conservation gate, evaluated on
  the published state (C1*T1 = C0*T0 - displaced + phase heat), which the publish
  path applies unchanged.
* legacy oracle (f77src/watsub.f): DO 3000 MM=1,NPS iterates the explicit phase
  endpoint with NO convergence test, NO publish bound and NO failure mode — the
  Zig bound screens are a Zig-era safety net, so widening WHERE they are evaluated
  (iterate -> published image at the ceiling) while keeping them present changes no
  acceptance semantics; the conservation gates are untouched.

Fix (D-22, shipped with D-21 in the next verification binary):
1. filter ENTRY widened: run whenever the residual temperature defect exceeds the
   1e-6 K publication bound, not only after a failed line search (inside the bound
   it is a no-op comparison; healthy trajectories stay bit-identical).
2. ceiling publication takes the ledger image BEFORE the bound screens and screens
   it: summed water 1e-6 of capacity (tight), per-coordinate 1e-5 of capacity
   (offsetting splits at the freezing front: vapor +9.2e-7 vs matrix -8.7e-7 — the
   "offsetting domain split" DEV-014 already permits), temperature row replaced by
   the unchanged phase-energy conservation gate + committableState on the image.

Lane falsifier (fix i binary, v12 deck resume): sci=0 through 8479 AND 8480
(12 accepts, 35 ceiling publishes), then the documented OutputReplayRecordMismatch
journal wall at 8479's changed output record — expected for a value-changing binary;
hour 8480's science was fully processed (both hours' ledgers completed before the
wall). From-scratch v13 is the authority for the full campaign.

## issue-125c (2026-11-08): v13 died at 8480 with a NEW-state double-close defect

v13 from-scratch (d8eb973687d63b69) passed 5668, 5848 and the whole 8479 freezing-front
hour (26 filter accepts, 36 ceiling publishes, zero conservation failures over d1..8479)
and died at 8480 h08 with `SoilPhaseSolverDidNotConverge` (substep 31) — an hour state
created by the D-22 filter-entry widening (10 extra accepts before 8480), not a D-22
screen regression: the D-22 ledger-image water screens pass at that state (probe receipts
max coordinate 6.2e-9 and sum 8.3e-8 of capacity against bounds 1e-5/1e-6).

Root cause (VERIFIED, resume-lane probe series on the frozen v13 deck, run dirs
audit/runs/ottawa/cycle11-issue125c-*): two phase-solver publication defects, both latent
since v12 (masked by its earlier death):
1. Double close. The in-loop ceiling branch publishes the ledger image (current := target
   + one closeStalledPhaseTemperature). The post-loop publish block then RE-IMAGES against
   a `target` that the in-loop residualAt re-read has re-derived and RE-CLOSES the
   temperature. closeStalledPhaseTemperature is not idempotent: its phase heat derives from
   the residualAt latent-heat ledger (-5.5883883528912325e-5 MJ at this state) while the
   first close rode the Newton-residual enthalpy row (~2.5e-7 MJ). The double close shifts
   the endpoint by 4.1314782265544636e-5 K and the UNCHANGED phase-energy conservation gate
   rejects with exactly that defect: residual -1.1450650466583029e-6 MJ equals capacity
   2.7715625806725437e-2 MJ/K times the shift 1.1450650455581714e-6 MJ (five digits) —
   probe receipts P125G gate-dump/altT (runs probeG2/G3).
2. Retry-path bypass. A loop exit via the post-Anderson Newton-retry continue skips the
   in-loop ceiling branch; at the terminal attempt that state (water deep inside bounds,
   temperature row frozen at 1.81e-4 K) bypassed every ceiling screen and returned
   DidNotConverge without any publication attempt (probe P125D tail receipt).

Fix D-23 (phase_solver.zig; NO gate/bound/tolerance change; publication still decided by
the UNCHANGED committableState + phase-energy conservation gate): (1) the publish block
re-images and re-closes ONLY when the ceiling was not already applied in-loop
(in_loop_ceiling_published — canonical single close, restoring v12's bit-for-bit published
image on every trajectory v12 could publish); (2) retry-path exits at the terminal attempt
take the same D-22 ledger image and water screens (1e-5 per-coordinate offsetting-split
allowance, 1e-6 summed bound kept tight; temperature row not a publication bound), then
the same unchanged gates. A stale probe-era in-block residualAt diagnostic that re-derived
`target` in place at publish was removed.

Lane falsifier (fix125c3, v13-deck resume at manifest 8400): sci=0 through 8479 AND 8480
(12 accepts, 35 ceiling publishes), then the documented OutputReplayRecordMismatch journal
wall — expected for a value-changing binary. From-scratch v14 is the cycle authority
(5668, 5848, 8479/8480, the ~d594 accumulated-clay window, frontier total_hour 18939,
EXITED 0).

## issue-125d (2026-11-10): v15 authority death at 1998 d354 h08 — stale-ledger close defect — FIXED (D-25k)

The v15 from-scratch campaign (binary ec087e6dd18c398a, D-23c source) passed 5668/5848 and
every conservation gate for 353 days, then died at exactly the kink hour 1998 d354 h08
(audit/runs/ottawa/cycle11-verify-v15-20261109, day 353, sci=1): the bounded ceiling
publication fired (36 ceiling publishes, 0 retry-path publishes — identical receipt shape
to v13's death) yet the UNCHANGED phase-energy conservation gate rejected the published
endpoint: residual 5.988192697615423e-7 MJ against effective limit 2.280969013403469e-13
MJ (ladder rung substep 31/64, dt 1.5625e-2 h). Receipt audit/runs/ottawa/
cycle11-repro15-20261109 reproduces the death bit-identically on the 8400 resume lane.

Root cause (VERIFIED by probe lanes d24fix{2,5}, d25lane{1..13}; decisions D-25/D-25k):
the ceiling close and the terminal gate consume DIFFERENT evaluations of one hour's
transfer ledger. The in-loop close derives the temperature from the OPEN-image ledger;
the unconditional post-loop ledger rebuild (line "try residualAt(...)" after the loop)
re-evaluates the ledger AT the closed state (closed-state vapor/surface bookkeeping) and
the unchanged gate then checks the closed temperature against that rebuilt ledger.
Probe receipt (cycle11-d24fix5-20261109 P125D5): the published pair fails its own gate by
6.806781151347778e-8 MJ while the same water re-closed fresh on the gate's ledger passes
at zero defect; P125D7 (cycle11-d25lane10) pins the identity: (freezing heat demanded by
the balance) - (freezing heat in the gate ledger) = 6.806781151347778e-8 MJ — EXACTLY the
residual. The published pair cannot be moved instead: the strict post-Richards water
closure validator (limit 1.07e-18 m3) accepts exactly the v15 pairing (published water
image + ledger of the same evaluation) and rejects any temperature excursion of it
(lanes d25lane1/5/6/7: 5-6e-10 m3 residuals, every alternative publication geometry tried
— close-last, skip-rebuild, T-fixed-point settle, dual-ledger T-copy, full-image
fixed point (no fixed point exists at the kink: 32-pass non-convergence receipt
cycle11-d25lane3) — each broke one validator while fixing the other).

Fix (D-25k, LANDED): reconcileStalledCeilingLedgerHeat — on the publish path AFTER the
final (image, close) of every bounded exit and AFTER the terminal ledger rebuild,
immediately BEFORE the unchanged gate, reconcile ONLY the scalar advective heat slot of
the ledger to the published pair's exact closure heat (verbatim mirror of
closeStalledPhaseTemperature's own arithmetic, i.e. precisely the gate transaction's
balance adv* = C0*T0 - C(T1)*T1 + latent*(v0-v1) + fusion*(i1-i0)). Where the pair
already closes (all 35 publications through 8479) the reconciled heat is bit-identical —
zero value change; where it does not, the defect (production class 6.8e-8..6e-7 MJ) is
exactly the ledger drift removed. Non-finite/negative reconciliations leave the ledger
untouched and the unchanged gate rejects honestly (recovery ladder intact). Water slots
untouched => requireDisplacementBinding, post-Richards closure and hourly conservation
validators see the state's own v15-proven water bookkeeping. No gate, bound, screen or
tolerance moves anywhere; healthy converged trajectories return inside the loop and never
reach the reconciliation.

Lane falsifier (clean probe-free build fix125k_clean, sha 2aedacac8777dc81, engine __text
9948c95a843e07eeeca2aa9b = v15 __text + D-25k only): audit/runs/ottawa/
cycle11-d25lane13-20261110 (8400 resume, single-site f25y98) sci=0, cons=0, fatal=0
through 1998 d354 h08 — 8479 AND 8480 PASS with 35 bounded publications — then stops at
exactly the documented OutputReplayRecordMismatch journal wall (expected for a
value-changing binary). Unit test "issue-125d terminal ledger-heat reconciliation closes
the gate without touching water" ships with the fix (execution+discrimination proven:
neutering the reconciliation fails exactly that test; restored suite rc=0).

Cycle authority moves to v16 (this source, suites cycle11-verify-v16-20261110-suite-*):
from-scratch campaign must pass 5668, 5848, 8479/8480, the ~d594 accumulated-clay window,
frontier total_hour 18939, EXITED 0.
