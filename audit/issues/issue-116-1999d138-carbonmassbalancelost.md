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

## Prior state

Not fix-induced: issue-114 complement fix changed band-expansion-hour outputs by 1-18 ulp from h4354;
ulps cannot open a 1.32 g hole, and all ledgers through 1999 d137 closed at ~1e-14. This territory
(1999 tillage) was never reached by earlier binaries (cycle-4 frontier died at h11806, 1999 d127 h22).

## Next steps (next cycle)

1. Diff the tillage carbon ledger: enumerate every carbon pool transfer the tillage pass performs
   (runtime_adapter.zig + redistribution) against the n_ledger accumulation for d138; locate the leg with
   no counter-entry (suspect surface->soil organic transfer or residue placement into a layer the cell
   ledger attributes elsewhere).
2. Legacy: tillage carbon redistribution in `tillag.f`/`redist.f` (f77query) — compare booking sides.
3. Falsifier for chaotic-amplification doubt: rerun 1999 d130-138 from a pre-fix binary deck segment? Not
   possible (old binary died at h11806 pre-dating tillage); instead bisect by disabling only management
   tillage? No — diagnose by ledger legs, no physics toggles.
