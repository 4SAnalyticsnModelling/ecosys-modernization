# Issue 116 — CarbonMassBalanceLost at 1999 d138 (first tillage day beyond the old frontier)

Status: OPEN (registered cycle 00005; fix is the next cycle's target)

## Observation (VERIFIED)

Canonical cycle-5 verification run `audit/runs/ottawa/cycle5-verify-scratch-candidate-20261022040928`
(candidate ReleaseSafe a1510feb, from-scratch byte-identical prod inputs) advanced the strict trajectory
502 accepted daily conservation ledgers (1998 d1 .. 1999 d137), cleared h11806 (zero zone-fraction
violations), then exited:

- stderr.log:69915 `error: carbon mass balance lost: day=138 year=1999 deviation_per_m2=1.319999999996071e0
  tolerance_per_m2=4.2075323895100345e-8` -> `CarbonMassBalanceLost` at h12073 (1999 d138).

Deviation 1.32 g C/m2 is ~3.1e7x the ledger tolerance — a structural booking gap, not rounding, and the
day boundary ledger (not an in-hour gate) caught it: d137 closed accepted (stderr.log ~69911) with all
elements at ~1e-14.

## Immediate context (VERIFIED, same day window)

1999 spring tillage executes inside d137-d138:
`TEMP_DIAGNOSTIC tillage surface carbon: packed=1.6372822766021888e0 authoritative=1.6372822766021888e0`
(surface carbon consistent across representations at tillage start) and
`TEMP_DIAGNOSTIC tillage surface booking: heat_before=3.831568061104868e0 heat_after=3.4484112549943817e0
booked_heat=3.831568061104864e-1` lines appear immediately before the failing day (runtime_adapter.zig:1188
onwards). The magnitude (~1.32) is in the scale of a single pool transfer (~1.64 g C/m2 surface carbon was
present), consistent with one tillage carbon transfer booked on one side of the ledger only.

## Diagnosis (cycle 00006, 2026-10-22)

Probe v1 (day-gated daily identity dump in mass_balance_audit.check; instrumented 5377f83f,
audit/runs/ottawa/cycle6-diag-d138-20261022074627, resume from candidate deck gen 11880, replayed
11881-12072 bit-clean then re-fired the failure):

day  plant_C_delta  residue_delta  organic_delta  co2_delta  cum_co2_in  deviation
136  +0.000000       -1.700522      +0.130012      +0.181134  +0.005299   0
137  +0.000000       -1.844734      +0.143386      +0.162279  +0.004490   0
138  +1.320015       -2.110163      +0.168355      +0.230294  +0.001899   +1.320000 (all per m2)

VERIFIED: the deviation IS the plant-carbon pool gain of 1.320015 g C/m2 on 1999 d138 (emergence/
planting day), with no compensating donor draw (residue/organic/co2 follow the prior spring trend)
and no external-input booking (cumulative terms unchanged). Tillage did not execute on d138
(census: tillage_soil_application last_hour=8760, tillage_aboveground last_hour=7452), so the earlier
tillage-day hypothesis in this document is FALSIFIED; the event is plant establishment.

Open discriminator (probe v2 with jump trigger |Δplant|>0.4, from-scratch run
audit/runs/ottawa/cycle6-diag-scratch-*): on 1998 emergence/growth days, where does plant C come from
(donor pool delta vs cumulative external booking)? The 1998 ledgers closed, so establishment C was
sourced/booked there; 1999 re-establishment lost that leg. Candidates: establishment debit from surface
residue/seedbed applied only on first planting; or second-year planting path skips the booking that
first-year planting performs.

## Next steps (next cycle)

1. Diff the tillage carbon ledger: enumerate every carbon pool transfer the tillage pass performs
   (runtime_adapter.zig + redistribution) against the n_ledger accumulation for d138; locate the leg with
   no counter-entry (suspect surface->soil organic transfer or residue placement into a layer the cell
   ledger attributes elsewhere).
2. Legacy: tillage carbon redistribution in `tillag.f`/`redist.f` (f77query) — compare booking sides.
3. Falsifier for chaotic-amplification doubt: rerun 1999 d130-138 from a pre-fix binary deck segment? Not
   possible (old binary died at h11806 pre-dating tillage); instead bisect by disabling only management
   tillage? No — diagnose by ledger legs, no physics toggles.
