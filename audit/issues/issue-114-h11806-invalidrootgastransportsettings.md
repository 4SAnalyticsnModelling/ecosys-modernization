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
