# Issue 105 -- hour 3,289: root gas exchange reads a zero root radius for a layer whose uptake geometry was skipped

Status: **FIXED (run-036, task `20260924-104044-3fc27a08`)**: root geometry is now defined for every layer and the error is gone. Hour 3,289 still fails, now on C/Ca/Na/K closure (issue-108). Localized in run-035.

## Measurement (run-035)

- Build `audit/runs/issue-105-probe-build/receipt.json` (exit 0, 869.3 s; exe prefix `72AD5A17AD7DDBAF`). HEAD `1ce33c5` plus a TEMP_DIAGNOSTIC error-path wrapper `issue105Conductance` in `plant/root/plant_root_gas_transport.zig`, which logs the call site, indices and every input only when `radialAqueousConductanceM3PerH` fails.
- Run on a fresh prod-deck copy: `audit/runs/issue-105-probe-run/receipt.json`, exit 1, 2,122.8 s. stderr SHA256 `6931E6E1863CAF912FE616D8787F0F0BD07E7872AA97F51F8650CBA9516A6928`. The frontier is unchanged (`census_positive_control entries=3288`; fails `scene_hour=3289`, 1998-05-18 hour 1).
- `TEMP_DIAGNOSTIC issue-105 site=oxygen_soil_to_surface err=InvalidRootAqueousDiffusionInput root=2 soil=2 diffusivity_m2_per_h=8.141780245346882e-6 tortuosity=1.6020744374678472e-1 area_per_radius_m=0e0 radius_m=0e0 film_m=7.278403353441644e-5 root_aqueous_volume_m3=5.28e-6 root_surface_area_m2_per_plant=5.35342505506354e-4`

Prediction registered before the run (`audit/runs/issue-105-probe-prediction/prediction-registered-before-run.txt`): radius 0 with positive volume and area. **Confirmed.** Surface area per radius is also 0.

## Cause (source)

- The consumer, `plant_root_gas_transport.zig` (the oxygen loop around `:280-310`), visits every root with `aqueous_volume_m3 > 0` and `root_surface_area_m2_per_plant > 0`.
- The producer, `plant/root/water_balance.zig:288-320`, writes `workspace.root_cylinder_radius_m`, `root_surface_area_per_radius_m` and `soil_path_length_m` only after six `continue` guards: root length density <= 0, primary or secondary axis count <= 0, rooted fraction <= 0, matrix liquid water <= 0, matrix volume <= 0, and unsaturated conductivity <= 0. A layer skipped by any of them keeps a zero geometry.
- Legacy always defines the geometry. `uptake.f:526-538`: `IF(RTDNP.GT.ZERO.AND.FRTDPX.GT.ZERO)` computes `RRADL=AMAX1(RRAD2X, SQRT(...))`, `PATH=...` and `RTARR=6.283*RTLGP/FRTDPX`; otherwise `RRADL=RRAD2M`, `PATH=DLYR`, `RTARR=6.283*RTLGP`. That block is not gated on water or conductivity. The gas exchange then uses `RRADS=LOG((FILM+RRADL)/RRADL)` and `RTARRX=RTARR/RRADS` (`uptake.f:2056-2058`, `2134-2135`).

## Next (fix task)

Compute or default the root geometry for every layer independently of the water and conductivity guards, per `uptake.f:526-538`. Use the `RRAD2M` / `DLYR` / `6.283*RTLGP` else-branch when root density or rooted fraction is not positive. Keep the water/conductivity gates on the hydraulic path only. Before editing, confirm which Zig quantities correspond to `RRAD2M`, `RTLGP` and `FRTDPX`, and check which of the six guards fired for root 2 at hour 3,289.
