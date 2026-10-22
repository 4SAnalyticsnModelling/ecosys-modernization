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

## Resolution (cycle 00006, 2026-10-22)
ROOT CAUSE (VERIFIED): the driver reseed/replant seeding site (ecosys-ng/src/ecosys_ng.zig,
plant_lifecycle_external_input block ~7186-7220) admits the injected seed ElementalMass at the hourly
cell gate (preflight) but nothing mirrored that mass into the cumulative landscape boundary ledger,
and the daily elemental identities carried no planting term. The hourly gate therefore closed while
the daily audit saw +1.320000 g C/m2 (soyb33, 37.5 stems/m2 x 0.0352 g seed C) appear in the plant
census without a donor on the 1999 reseeding day (d138). probe v3 (audit/runs/ottawa/cycle6-diag-scratch2-*)
shows 1998 carried its 1.32 g C seed storage inside the initial condition (plant=1.320000 g from day 1,
1998 d138 emergence dP=+2.8e-5 only) - the baseline covers t0, so only the post-t0 reseed leaks.
FIX (ledger-only, physics untouched): landscape_boundary_balance.Fluxes += planting_{carbon,nitrogen,
phosphorus}_input (appended order-preserving); accumulateAcceptedPlanting (organic-fertilizer precedent);
publish() maps the three into new audit.Totals cumulative_planting_*_input_g fields; balance() subtracts
them for C/N/P; the driver reseed site books exactly the preflight-admitted mass per event; landscape
mass-balance checkpoint v19->v20 with explicit legacy rejection (LegacyCheckpointMissingPlantSeeding-
ConservationHistory) - v19 histories cannot distinguish seed gain from an unexplained source.
The startup (initial-condition) seeding site is intentionally NOT booked: it is inside the baseline.
Note: seed N and P (grain ratio) were equally unbooked and are covered by the same term set.
LATENT (UNVERIFIED, out of scope): self-reseed with preserve_reseed_inventories=true books nothing
anywhere (claims internal carryover) - if that carryover is invisible to the census during dormancy,
a similar leak would appear; no Ottawa evidence that path fires. Standing-dead injection at replanting
(standing_dead_carbon_g_per_m2>0 PFTs) may need the same treatment; soyb33 injects zero here.

## Next steps (next cycle)

1. Diff the tillage carbon ledger: enumerate every carbon pool transfer the tillage pass performs
   (runtime_adapter.zig + redistribution) against the n_ledger accumulation for d138; locate the leg with
   no counter-entry (suspect surface->soil organic transfer or residue placement into a layer the cell
   ledger attributes elsewhere).
2. Legacy: tillage carbon redistribution in `tillag.f`/`redist.f` (f77query) — compare booking sides.
3. Falsifier for chaotic-amplification doubt: rerun 1999 d130-138 from a pre-fix binary deck segment? Not
   possible (old binary died at h11806 pre-dating tillage); instead bisect by disabling only management
   tillage? No — diagnose by ledger legs, no physics toggles.

## Verification plan (cycle 00006)
Checkpoint v20 invalidates every v19 resume deck => from-scratch verification on candidate
52aba77c13d37470480216e7b522402b99d9a8d8420d5b2a56357b6f86e77cea, deck
evidence/runs/cycle6-verify-scratch-20261022/deck (diff-verified prod inputs), receipt
audit/runs/ottawa/cycle6-verify-scratch-candidate-20261022095502. Acceptance: 1999 d138 daily
conservation accepted (deviation ~roundoff, not 1.32); 1998 ledgers bit-comparable to cycle-5
candidate through d365 (no physics change); run advances past h12073 to the next distinct defect.

## Verification RESULT (cycle 00006, 2026-10-22) — RESOLVED
Canonical from-scratch run audit/runs/ottawa/cycle6-verify-scratch-candidate-20261022101316:
- 1999 d138 "daily conservation accepted" carbon defect 8.754659807282035e-14 (was +1.32 g C/m2); d139 accepted.
- 504 accepted ledgers (1998 d1..1999 d139); first 502 lines bit-identical to the cycle-5 canonical run (cmp)
  => outputs untouched; DEV-022 x2 / DEV-023 x3 / InsufficientSoilNitrite 0 (identical event profile).
- Engine exit moves to a DISTINCT defect at 1999 d140: HourlyPlantConservationFailure -> issue-117 registered
  (audit/issues/issue-117-1999d140-hourlyplantconservation.md).
