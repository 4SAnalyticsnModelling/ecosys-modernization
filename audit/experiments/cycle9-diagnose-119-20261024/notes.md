# Cycle 9 diagnosis — issue-119 InvalidPlantInventory 1999 d286 (h6851 scene2)

## Deterministic reproduction
- attempt3-ABORT-DATA run audit/runs/ottawa/cycle9-probe-d286-20261024-attempt3-ABORT-DATA:
  abort identical to cycle-8 close run (mortality diagnostic litter_c=3.0413572522379505e-4
  byte-identical; census_positive_control last_hour=6851; exit InvalidPlantInventory).
- FIRST bad value in entire run (single occurrence): roots.salt_content_mol salt_index 104
  = root 13 = layerIndex(plant 0, domain 1, layer 1), species Al (slot 0) = -2.465190328815662e-32;
  companion vector K=+1.0097419586828951e-12, rest 0 except idx6 ~1e-27.
- domain=1 slot => mycorrhizal-side slot space (mycorrhizal pairs root=(p,0,l), myc=(p,1,l)).
- Created between h6850 guard (clean) and h6851 guard (fatal) => an hour-6851 leg.
- Sweep coverage note: validator sweep ran only in whole-landscape aggregate entry in attempt3;
  blind to per-cell/per-layer entries (guard entries) -> badtot=0. Fixed in attempt4.

## Writer census (production writes to roots.salt_content_mol)
1. plant_root_salt_exchange.zig:676 (+= staged; per-competitor guard vs base, unique (plant,domain,layer)
   competitors from admission iterator -> no same-slot accumulation; no caller swallows guard error).
2. plant_root_mycorrhizal_exchange.zig:253-254 (absolute writes; preflight/commit split passes,
   adjacent calls, disjoint pairs -> statically safe; guard preflight-only).
3. plant_exchange_shoot_root.zig:388 (validate->commit sequential per pair, guarded).
4. plant_salt_harvest_adapter.zig:152 (staged write-back unclamped; harvest stages ran ZERO times).
5. layer_remap (scene-transition hours only, not 6851).

## attempt4 instrumentation (binary aae859d65603, deck rebuilt from pristine scenario)
- TEMPDIAG119W writer tags at all 4 commit sites (post-write <0 check, log-only).
- probe119Sweep extended to per-cell and per-layer aggregate entries (hourly visibility).
- Watcher: engine exit / tag ping. Launched 15:18.

## Decision rules
- Tag fires at writer X -> minimal legacy-parity clamp/recheck in X; discriminating unit test
  (pool near zero, transfer > pool -> no negative written; conservation ledger exact).
- No tag + guard dump -> instrument transaction accept paths next (pool_transaction_replay).
