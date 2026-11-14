# issue-126/127/128 — hourly carbon census provenance + accumulated mineral drift (cycle 00011, D-27/D-28)

## Terminal failure (reproduced bit-exactly three times)
- cycle11-d25lane21e7-20261109 (fix125e_p9 deep, v16-8400 state), cycle11-carbon2-20261114
  (fix125e_p10 on v15-deck snapshot + lane-local output tree): identical terminal
  `HourlyCellConservationFailure` at the 1999-d80 hour, cell 0, quantity=carbon:
  residual=-1.6061700580660698e-11, physical_limit=3.384900330274832e-12,
  arithmetic_roundoff_allowance=1.1537038046109396e-11,
  effective_limit=1.4921938376384226e-11, before=5.159108975213581e3,
  after=5.159105590313251e3, external_outputs=3.384900314213131e-3.
- cycle10-verify-candidate-20261026 / cycle10-restartx10-fixed-20261026: same class
  (residual -1.2619e-11 > 1.2371e-11) at the cycle-10 campaign frontier: PRE-EXISTING.

## Forensics (lanes carbon3..carbon6, 10-minute deterministic repros via kink-lane2.sh)
- carbon3 (P126RES per-hour probe): the cell-0 carbon closure defect is CHRONIC,
  present every lane-day: 6358/13616 hours > 1e-12, median 1.17e-13, p90 2.25e-11,
  winter max 7.03e-11; death hour is the run's only surface-respiration-rebase hour
  AND a tiny-throughput hour — the effective limit shrinks (relative slack scales
  with throughput) below the standing rewrite noise. Signs near-random
  (lag1 autocorr -0.07), bounded at 61.3 ulps of the 5159.108975213581 g pool.
- carbon4 (P126DECOMP): inventory delta equals the four-pool component sum to
  4.5e-13 (compensated-sum fidelity); the defect is booked-throughput vs
  inventory-difference noise at per-layer pool ulp scale, not a missing transfer.
- carbon5 (D-27 v1, completion residuals only): death hour short by 8.5e-14 —
  chronic rewrite noise exists in hours without completion events.
- carbon6 (P127 op counter): booking op counts cannot carry it either (median 0).
- Structural gap: `carbon_storage_update_roundoff_allowance_g` had ZERO production
  writers while oxygen (`oxygenStorageUpdateRoundoffAllowance`, a-priori 4×substep×eps)
  and water (exact ledger publication provenance, upward nextAfter adds) both feed
  their lanes; CEC/AEC already carry a 128-eps standing census floor in the same
  expression (chemistry-commit census precedent).

## Fix D-27 (carbon)
1. `sum_completion.completeCellCarbon` now RETURNS `CompletionResiduals` (the exact
   post-retry residuals it already computed and warned about; honest
   `measureExitResiduals` on the exclusion-overflow early exits).
2. `relayering.Context.carbon_rewrite_provenance_g` accumulates |residual| per cell.
3. `stages/hourly_geometry_disturbance.zig` publishes the per-cell provenance onto
   `hourly_cell_boundary_ledger.accumulateCells` as
   `carbon_storage_update_roundoff_allowance_g` (validator lane: exact events,
   carried into the accumulated domain by the existing commit path).
4. Validator census floor: `256 * floatEps * max(|before|,|after|)` for carbon —
   structural budget 64 recovery substeps × 4 fold owners; proven empirical bound
   61.3 ulps over 13,616 lane hours leaves a 4.2× structural margin.
   Physical limits, tolerance structs and all physics are UNCHANGED.

## Fix D-28 (mineral texture, issue-128)
Lane carbon7 (fix126_p15, D-27 live) passed the 1999-d80 carbon hour and every
hour to day 197, then died at `AccumulatedCellConservationFailure` quantity=silt
cell=0: residual 2.220446049250313e-15 (2 ulps of the 0.978 standing; texture
completion rewrite drift with zero throughput; effective_limit 2.172e-15 missed
by 4.8e-17). D-28: 128-eps standing census floor for sand/silt/clay/rock_additive
(CEC parity, same expression, same doctrine).

## Receipts
- Lanes: audit/runs/ottawa/cycle11-carbon{2,3,4,5,6,7,8}-20261114 (carbon7:
  197 days carbonfail=0; carbon8 scout on the full fix set passed both walls).
- Tests: `issue-126 hourly carbon census floor covers rewrite roundoff but not
  leakage` + `issue-128 mineral texture census floor absorbs completion drift not
  leakage` (hourly_cell_conservation.zig), each neuter-discriminated
  (floor→false ⇒ exactly one failing test; /tmp/n126.log /tmp/n128.log).
- Suites: cycle11-verify-v17-20261114-suite-final-{testmodule,debug,releasesafe}.log
  (testmodule rc=0; debug 4542/4544 with only the known issue-115 crash).
- Authority: cycle11-verify-v17-20261114 from-scratch campaign (in progress).
