# issue-114 — h11806 InvalidRootGasTransportSettings (1999 d127 h22)

Status: OPEN (first observed cycle 00004, DEV-023 candidate trajectory; distinct from issue-113)

## Observation

audit/runs/ottawa/cycle4-dev023-resume-20261022011616/stderr.log:35143:

    error: hourly science failed: execution=1 scenario=1 scenario_repeat=1 scene=2
    scene_hour=3046 total_hour=11806 year=1999 day_of_year=127 month=5 day=7 hour=22
    error=InvalidRootGasTransportSettings

Preceded by 291 accepted daily conservation ledgers (through 1999 d126) — no near-zero balance
or pool-integrity anomaly in the failing hour region.

## Raise sites (Zig)

`plant/root/plant_root_gas_transport.zig`:
- 181-190 `rootGasFractionsAt`: rejects non-finite or out-of-[0,1] ammonium zone fractions or
  `|non_band + band - 1| > 16*eps` (fractions come from hydrology zone geometry per layer).
- 545-548 settings validation (static config; cannot fail only at h11806) — the trigger is 189.

## Hypotheses (all UNVERIFIED)

1. Mid-May 1999 drying/re-wetting cycle drives a layer's zone fractions (matrix/macropore) outside
   the admissible band by more than 16 eps (e.g. evaporation front, snowmelt aftermath).
2. Root growth crosses into a layer whose water state is degenerate (zero liquid water) making the
   fraction computation ill-conditioned; legacy equivalent is warn-tolerant (check `grosub.f`/
   `hour1.f` root-gas path via f77query before any change).
3. Interaction with `root_uptake_geometry` — the one process still listed NOT YET INSTRUMENTED in
   the run summary (absence is not evidence).

## First steps (playbook `.agent/playbooks/convergence-and-balance.md`)

1. Add failure-path diagnostic next to line 189 dumping layer, water state, and the offending
   fractions (mirror existing breakdown-log pattern), rebuild ReleaseSafe, resume from
   evidence/runs/cycle3-confirm-resume-20261022/deck (now at gen 11640, 1999 d120 h23) — short run
   (~150 h to h11806) to capture the offending values.
2. Compare legacy root gas transport substrate-fraction handling before any relaxation; the
   16*eps gate is a modern admissibility bound — diagnose, do not loosen.
3. If fractions legitimately leave [0,1], that is an upstream hydrology defect — file separately
   with the causal layer, do not patch the validator.

## Resolution (cycle 00005, 2026-10-22) — FIXED, verification in progress

Cause (VERIFIED): translation defect in `fertilizer_band_state.scienceZoneFractions`. During a
pending application hour with recorded pre-prepare band fraction (band-expansion hours, FVL != 0),
the band side came from the stored `hour_coordinator.prePrepareBandFraction` while the non-band
side was reconstructed as `current_non_band/(1+FVL)`. The two formulas are independent
roundings, so the pair is not an exact complement: instrumented validator dump
(audit/runs/ottawa/cycle5-diag-h11806-*/stderr.log, binary fdcffd43) captured exactly one
violation at h11806 (1999 d127 h22, soil=1): non_band=9.402985596461554e-2,
band=9.059701440353886e-1, sum_deviation=3.9968028886505635e-15 (~18 ulp > 16*eps bound).
Python check proved non_band != fl(1-band). Hypotheses 1-3 (hydrology/root geometry) falsified:
fractions are individually admissible; only closure breaks.

Legacy basis (G4/G7): `hour1.f` 369-374 and 5049-5055 compute the band volume fraction VLNOB,
then set `VLNO3(L,NY,NX)=1.0-VLNOB(L,NY,NX)` — band authoritative, complement exact, at both
application andHour entry points. The Zig reconstruction violated that invariant.

Fix (translational, no DEV, validator untouched): `scienceZoneFractions` now takes the stored
band as authoritative and emits `non_band = 1 - band` for all three families
(fertilizer_band_state.zig, issue-114 comment block). Bit-safety: for FVL = 0 (all non-application
hours) `band = 1 - current_non_band` by construction and the complement map is an involution on
[0,1], so `1 - band == current_non_band` bit-exactly; only band-expansion hours change (by 1-18
ulp toward the legacy pair). Replay attribution (audit/runs/ottawa/cycle5-fix-h11806-20261022024755):
resume at gen 11640 replayed d121-d126 bit-clean, then `OutputReplayRecordMismatch` at
generation 11804 (1999 d127 h19) = the 1999 application hour — divergence starts exactly at the
first output affected by the fix. 4320-deck replay (audit/runs/ottawa/cycle5-replay-4320-20261022025737):
mismatch at generation 4354 (1998 d182 h9) = the first 1998 band-expansion hour; days 181 identical.
Output-changing from that hour onward ⇒ from-scratch verification (precedent
zig017-verify-dev021-20261021): audit/runs/ottawa/cycle5-verify-scratch-20261022025641 on
evidence/runs/cycle5-verify-scratch-20261022/deck (inputs diff-verified byte-identical to
ecosys-ng-prod-examples). Unit test: "science fractions on a band-expansion hour stay exact
complements" (fertilizer_band_state.zig) asserts stored-band authority and exact closure.
Validator plant_root_gas_transport.zig:181-196 unchanged (16*eps intact); the diagnostic dump
added at the raise site is retained as permanent evidence.
