# issue-132 — hydrogen layer-scope ledger deficit after bounded-recovery publication (2002 day 100)

Status: REGISTERED (cycle 14 close-out; fix scope = cycle 15)
Owner: leader. Depends on: D-33 v3 (0e11350) lane passing issue-131 frontier 35283.

## Boundary receipt
Lane: audit/runs/ottawa/cycle14-verify-v21lane-20261126 (ship131 v3, __text
76233418bbd74420e516, frozen v19 deck, resume 35064).
- PASSED old frontier 35283 CLEAN: 2002 days 9..99, absolute counters zero
  (hourly science failures, conservation violations, FATAL, SoluteConcentration).
- NEW BOUNDARY 2002-04-10 hour 05 (scene_hour 2381, abs hour 37445):
  error HourlyLayerConservationFailure, scope layer_scope=9, quantity=hydrogen:
  before=2.1141187599272815e-6 after=2.0917866954878356e-6 external_inputs=1.7993557498908417e-9
  external_outputs=2.413142021039971e-8 internal_production=1.777819877043314e-19
  internal_consumption=5.55285223192443e-18 residual=2.6438128362738157e-17
  normalized_relative=1.0195656465268062e-9 physical_limit=2.5930775966021185e-17
  arithmetic_roundoff_allowance=4.723075592650381e-21 effective_limit=2.5935499041613834e-17.
  Engine fail-closed EXITED 1 (correct). Frontier extended 35283 -> 37439 (+2156 h).

## Immediate context (same hour, same lane stderr)
Cell=6 layer=7 SOLUTE DidNotConverge storm: reaction solver failed, snapshot
ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene5-year2002-day100-hour5.bin, fixed-hour
recovery attempt failed at 20 substeps, 'SOLUTE inventory-balance progress stopped'
(cell=6 iteration=24, best=4.066e-4), bounded entry-state retry spent=25, recovery ACCEPTED
at exact_substep_count=32 -> at publication the hydrogen layer-scope ledger refuses with the
above residual. Cell 6 = issue-130-family sliver-heavy cell (layer-scope 9 = the sliver
depth band; pool 2.1e-6 g hydrogen = sliver zone water scale). Residual 2.6e-17 g is
~1e-11 of the sliver pool: far above double-ulp for the recorded terms, far below any
physically meaningful exchange - consistent with a BOOKING gap (a process path in the
bounded-recovery/best-bounded publication not feeding the layer-scope hydrogen ledger),
NOT a state corruption.

## Hypotheses (UNVERIFIED)
H1: bounded-recovery publication (exact_substep_count=32 path) books hydrogen-conserving
    chemistry through a lane whose layer-scope ledger feed is skipped on the retry route.
H2: the DidNotConverge best-bounded state rewrite (failure_report_bound=true) adjusts a
    hydrogen-bearing pool without emitting the compensating layer-scope ledger delta.
H3: genuine tiny transfer through a lane whose allowance floor was calibrated only on
    normal-hours census (issue-126/101-style provenance lane) - least likely: the deficit
    direction (after < before beyond fluxes) must still be booked somewhere if real.

## Acceptance (cycle 15)
- Root cause pinned with source receipts (legacy parity comparison where applicable;
  legacy has no layer-scope hydrogen ledger - this is a port-only invariant, so the
  parity test is: does LEGACY conserve this sliver's hydrogen mass across the same hour?)
- Fix never loosens the ledger bound: either the missing booking is emitted (preferred)
  or the provenance-lane precedent applies with receipt-backed ulp accounting.
- Lane resume from checkpoint 37224 (deck journals through 37311+ kept) must pass
  37445 clean and continue toward natural scene-5 end 43824.

## Evidence map
audit/runs/ottawa/cycle14-verify-v21lane-20261126/FRONTIER_RECEIPT_v21lane3.txt;
stderr.log.gz (gz-verified); receipt.json (exit 1); failure snapshot bin at
.tmp/cycle121/v19-deck/runottawa_output_files/logs/ (deck is retained state, do not
delete; relocate to evidence/runs with retention manifest at cycle 15 close).
