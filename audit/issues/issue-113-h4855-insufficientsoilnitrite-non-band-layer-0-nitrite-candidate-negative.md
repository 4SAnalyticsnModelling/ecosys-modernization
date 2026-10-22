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
