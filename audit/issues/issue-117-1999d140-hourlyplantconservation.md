# issue-117 — HourlyPlantConservationFailure at 1999 d140 (tillage destroys 10% of emerged crop; plant-side output leg missing though litter receives the mass)

## Observation (VERIFIED)
Canonical cycle-6 verification run audit/runs/ottawa/cycle6-verify-scratch-candidate-20261022101316
(candidate 52aba77c..., deck evidence/runs/cycle6-verify-scratch-20261022/deck, from scratch):
- 1999 d138+d139 daily conservation accepted (issue-116 fixed; d138 carbon defect 8.754659807282035e-14).
- 504 accepted ledgers (1998 d1..1999 d139); first 502 bit-identical to the cycle-5 canonical run (cmp of
  "daily conservation accepted" lines) => the cycle-6 fix changed no physics.
- Engine exits during 1999 d140 (last "day advanced: scene_weather_hours=3336" = end of d139) with
  error: HourlyPlantConservationFailure (stderr.log:70085), immediately preceded in the same hour by
  TEMP_DIAGNOSTIC tillage surface carbon/energy lines and the plant-gate breakdown (stderr.log:70058):
    plant=0 C 1.3200229636121652e0->1.18802095319431e0  N 5.2800173623156074e-2->4.752016036317263e-2
    P 5.280031208033361e-3->4.752028828054558e-3
    dfix=0e0 dresp=-3.30747292934927e-8 droot_c=3.507895750582844e-7
    dlitter_c=1.3199999999999998e-1 dlitter_n=5.279999999999999e-3 dlitter_p=5.279999999999999e-4
    doxid_c=0e0 dharv_c=0e0 manure_c=0e0
  => exactly a factor 0.900 single-hour removal of plant C/N/P; the litter pools receive EXACTLY the removed
  mass (0.132 / 0.00528 / 0.000528), yet the hourly PLANT gate still rejects the hour.

## Reading (VERIFIED from the diagnostic terms)
The mass is not lost - it moves plant->surface litter as an internal tillage transfer. The failure is a
booking/gate defect: the plant-side ledger for the hourly plant conservation gate has no output leg for the
tillage destruction (dharv_c=0, activity output legs empty), while the litter-side delta exists. The gate
therefore sees an unexplained plant debit.

## Not fix-induced (VERIFIED)
Pools are untouched by the cycle-6 ledger-only fix (502-line ledger bit parity vs cycle-5 candidate). Pre-fix
runs died at d138 (issue-116) and never reached this hour; the event is masked, not created.

## Next steps (cycle 00007)
1. Locate the 0.9 destruction factor in the Zig tillage pass (runtime_adapter/disturbance management) and the
   deposit into surface litter; f77query tillag.f for the legacy crop-removal fraction and its destination
   (surface residue inputs) to confirm the transfer semantics.
2. Book the plant-side output leg of the tillage transfer so the hourly plant gate admits the hour (mirror how
   the litter side already books its input); the daily identity should remain untouched (internal transfer).
3. The plant-gate diagnostic site is ecosys_ng.zig:5879 (existing TEMP_DIAGNOSTIC; reuse for attribution).
4. Verification: if ledger/gate-only (no pool change), resume from this run's own v20 checkpoints
   (deck evidence/runs/cycle6-verify-scratch-20261022/deck currently at the d139/140 boundary) - ledger-only
   candidates replay bit-clean.

## Booking-math refinement (cycle 00007 static pass, 2026-10-22)
The gate identity itself is fine (litter sink IS booked as a plant output leg). Failure is a small booking
MISMATCH (VERIFIED from stderr:70058 arithmetic): booked litter delta = 0.13199999999999998 (= 0.1 x exactly
1.320000 - the pre-hour partition snapshot), while the actual pool debit was 1.3200229636121652-1.18802095319431
= 0.1320020104178552 (= 0.1 x CURRENT plant pools incl. this-hour growth +2.0104e-6). Gap 2.0104e-6 g C >>
~1e-13 tolerance. Same-class gaps in N/P. => The tillage deposit leg is computed from a one-hour-stale
partition snapshot while the plant pools are thinned by 10% of their current contents.
Booking route (VERIFIED sites): plant_harvest_runtime_harvest.zig:203/312 writes shoot_litter_*_by_plant
(= next partition pool totals); driver stage reads them at ecosys_ng.zig:4214-4228
(accumulateLitterStateUpdate, adds root_harvest_litter arrays); gate = plant/accounting/daily_flux.zig
evaluateAcceptedHour (identity confirmed incl. litter sink output leg); tillage entry =
disturbance_management_dispatch.zig:1032 applyAbovegroundTillage(remaining = 1-mixing_fraction=0.9).
UNVERIFIED (next step): instrument the tillage hour (probe: plant pool sums before/after the transaction vs
booked shoot_litter next values) to pin the exact stale-snapshot line; candidate fix = deposit exactly the
transaction-removed mass (bit-parity of removal and deposit), no pool change => resume verification from the
cycle-6 deck (v20 checkpoint at 1999 d139 end, journal written by same-source binaries).

## Legacy tillage semantics (VERIFIED f77query grosub.f, cycle 00007 session 3)
Legacy tillage books EVERY plant removal as a fraction of the LIVE pool array read at leg time, then
applies the retention in place, so deposit == debit by construction:
  - branches: CSNC(M,..)+=(1-XHVST)*CFOP*(CPOOL+CPOLNB+CPOOLK+WTRSVB..) live reads (10096-10108);
    branch state variables then *= XHVST (10161-10234).
  - standing dead: CSNC(M,..)+=(1-XHVST)*CFOP*WTSTDG(N,..) live (10250-10264), pools *= XHVST (10267+).
  - seasonal storage reserves: litter=(FHVSH-FHVST)*live, export=(1-FHVSH)*live, WTSTDG=FHVST*live
    (10541-10551); plant-level WTRVC..*= XHVST (10479-10481). Roots same pattern (10292-10370).
Zig deviation: applyAbovegroundTillage captures entry snapshots (standing @~751, storage_before @~765)
BEFORE applyEventInternal, then books removals from those snapshots. Any intra-transaction movement of
the same pools is lost from the ledger (seed pool additionally OVERWRITTEN from the snapshot).
Applied fix direction = legacy live-read at leg time (both legs; validation keeps entry snapshots).

## Live probe status
applyEventInternal (918-1145 pre-edit numbering) contains NO plant_seed_storage writes on the tillage
path (include_roots=false, include_standing_dead=false), so seed/standing snapshots equal live values
unless another tillage-path stage mutates them. Upgraded from-scratch probe (mobres branch totals,
node intermediates, seed N/P, standing N/P, litter array pre) running:
audit/runs/ottawa/cycle7-probe-scratch2-20261022. If all above-ground legs book exactly while the gate
still fails, the defect is on the separate dispatcher legs (host-root tillage root_litter_carbon_ledger
path, disturbance_management_dispatch.zig:1010-1061) or in gate inventory components not covered by the
shoot_litter arrays (root/nodule). Probe v3 will then target the roots side (roots state IS reachable
at the dispatch site).
