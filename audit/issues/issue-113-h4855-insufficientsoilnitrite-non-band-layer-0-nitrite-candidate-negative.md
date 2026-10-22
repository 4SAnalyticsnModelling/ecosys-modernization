# issue-113 — h4855 (1998 d203 h7) InsufficientSoilNitrite: non-band layer 0 nitrite candidate −1.3670655422748992e-11 g against operation scale 3.246187603319597e-7

**Status: OPEN (owned by cycle 00004).** Found 2026-10-21 in
`audit/runs/ottawa/zig017-verify-dev021-20261021/stderr.log:35908-35911,35937` and reproduced
2026-10-22 with the reproducible ReleaseSafe candidate (sha256
36c3784ae0e378d3193ea870050cf33ad659480e07fed0eec2b478caf0ed8556, recorded in
`audit/runs/cycle3-confirm-build-ReleaseSafe-20261021234803/receipt.json`) resuming from the
durable h4320 checkpoint (`audit/runs/ottawa/cycle3-confirm-resume4320-20261022b`).

## Symptom (byte-identical across from-scratch and resume-from-h4320 runs)

```
error: soil nitrogen state_update rejected negative candidate: error=InsufficientSoilNitrite
value=-1.3670655422748992e-11 operation_scale=3.246187603319597e-7 roundoff_limit=4.6131100409064584e-21
error: soil nitrogen state_update failing site: zone_non_band layer=0
error: soil nitrogen state_update non_band pool basis: layer=0 nitrate_conc_mol_m3=3.895445053878768e-3
water_m3=3.256243364830634e-3 effective_water_m3=3.256243364830634e-3 zone_fraction=9.999999999998899e-5
n_mass_g_mol=1.4e1 pool_g=1.7758323953655115e-8 potential_reduction_g=5.6182661611343505e-9
```

Relative overdraw ≈ 3.3e-5 of operation scale — NOT rounding-sized (roundoff limit 4.6e-21); the
DEV-022 deadband class cannot excuse it.

## First steps (playbook `.agent/playbooks/convergence-and-balance.md`)

1. Term-by-term nitrite supply/consumption dump at h4855 (nitrification NO2 production,
   denitrification NO2 reduction stage, plant/microbial NO2 fluxes) vs legacy
   (`nitrif.f`/`nitro.f`/`redist.f` via f77query).
2. Check whether the DEV-022 NO3 cap changes NO2 demand timing relative to legacy at this hour.
   UNVERIFIED.
3. No cap/floor may be added before the causal term is proven (protocol: diagnose before
   changing scale/floor/solver path).

Related: issue-112 (fixed analogue), DEV-022, DEV-019 precedent.

## RESOLVED (cycle 00004, 2026-10-22) — DEV-023

Causal attribution (VERIFIED): audit/runs/ottawa/cycle4-diag-no2-20261022005737/stderr.log temporary term dump
at the h4855 gate: pool 1.5668109806674771e-7 g; available 1.6230254483826847e-7 g (= pool + nitrate_reduction
5.6182661611343505e-9 + NH4-oxidation 3.174e-12 + autotrophic 6.33e-15); consumed 1.6231621549369122e-7 g of
which heterotrophic_nitrite_reduction 1.6231499047096993e-7 g = 99.99%. Overdraw 1.3670655422748992e-11 g
(8.4e-5 relative) — not roundoff (64*eps allowance ~1e-14 relative). Mechanism: `denitrification.zig` 113-116
caps each population's NO2 demand at supply x FNO2-share, but FMN-floored shares (legacy `nitro.f` 1781-1782
`AMAX1(FMN,RVMX2/RNO2Y)`) sum >1 across populations; legacy applies the NO2 balance unclamped
(`redist.f` 6221-6222) so legacy dips negative — DEV-022 analogue one stage downstream (issue-112/DEV-021
pattern of stage-by-stage surfacing).

Fix: DEV-023 per-layer nitrite supply admissibility in heterotrophic_denitrification_step.zig (uniform supply
fraction across acceptor stages + respiration; supply = zone NO2 pool rate + own nitrate-capped NO3->NO2
production; nitrifier supply excluded — conservative). Permanent nitrite-breakdown failure diagnostic added
next to the existing ammonium/nitrate breakdown logs in nitrogen_state_update.zig.

Verification: unit test "DEV-023 layer nitrite supply cap ..."; confirmation run
audit/runs/ottawa/cycle4-dev023-resume-20261022011616 — h4855 fired DEV-023 once (factor 9.999037288974819e-1,
requested NO2 bit-identical to the dump), no gate failure, 291 daily conservation accepted through ~h11784.
Final candidate re-verification (clean 4320-parent deck, replay of 4321-4854 + new territory): this cycle's
close record. Trajectory now terminates at a distinct later defect: issue-114 (InvalidRootGasTransportSettings).
