# Issue 031 -- REDIST ground-surface secondary CH4 combustion (`redist.f:10934-10971`) has no confirmed Zig counterpart

Status: OPEN (needs reviewer decision on materiality; not yet confirmed as a mass-balance-relevant divergence, only confirmed as an unreproduced mechanism)
Owner: unassigned
Candidate/input hashes: `f77src/redist.f` sha256 `2FEAEC2B50571BDE6E92AE6A8838738B13D36A9CE858E3734F95C65F2733111D`

## Failure signature and first bad time/location/process

`f77src/redist.f:10934-10971` (inside the `ICHKF.EQ.1` fire block that starts at `:10684`, but this specific sub-block is gated independently on `TKQGX(NY,NX).GT.TCMBX`, i.e. it can also run when it is otherwise summer/no-fire, since `TKQGX` is ground-surface air temperature, not a fire flag) computes a secondary combustion of ambient canopy-air CH4:

```
IF(TKQGX(NY,NX).GT.TCMBX)THEN
RC4OK=AMIN1(-XHNET(NY,NX)*CH4Q(NY,NX)/(CH4Q(NY,NX)+CCH4GK)
2*OXYQ(NY,NX)/(OXYQ(NY,NX)+COXYGK)
3,AMAX1(0.0,(OXYC(NY,NX)-XONET(NY,NX)))/2.667)
XONET(NY,NX)=XONET(NY,NX)+RC4OK*2.667
XCNET(NY,NX)=XCNET(NY,NX)-RC4OK
XHNET(NY,NX)=XHNET(NY,NX)+RC4OK
HCBFG(NY,NX)=RC4OK*GCBC4
ELSE
HCBFG(NY,NX)=0.0
ENDIF
```

`TCMBX=473.15` K, `CCH4GK=10`, `COXYGK=2100` umol/mol, `GCBC4=0.0743` MJ/g C (all `starts.f:84-85` `DATA` constants). This combusts a Michaelis-Menten-limited fraction of the net ecosystem CH4 flux already accumulated in `XHNET` this hour, using the *canopy-air* CH4/O2 mixing ratios (`CH4Q`/`OXYQ`), capped by the remaining canopy O2 budget, and feeds the combusted amount back into `XONET`/`XCNET`/`XHNET` and the canopy heat ledger `HCBFG`. This is the ground-surface/bulk-canopy-air twin of `extract.f:175-181`'s per-PFT version (`ROGOK`/`RC4OK`, gated on `TKC`/`TKD` instead of `TKQGX`, same `TCMBX`/`CCH4GK`/`COXYGK` constants).

## Minimal reproducer and hypothesis

Exact command/cwd/environment: static code trace only (this session's audit fork, 2026-09-18, part of `feature-010`'s assigned "fire/combustion" range `redist.f:10680-10973`); no runtime reproduction executed (read-only pass; no `zig build`/run performed).

Hypothesis: this specific sub-mechanism was either (a) never translated, or (b) folded silently into some other module without a `redist.f` line citation or an identifiably-named function.

Stop/resource budget: three grep-based experiments were run before stopping, per the contract's default diagnosis budget.

## Experiments

Experiment 1 -- citation search: grepped all of `ecosys-ng/src` for `redist.f:1093` through `redist.f:1097` (the sub-block's line range). Result: zero matches. The nearby, closely related closeout block (`redist.f:10991-11002`, the canopy CO2/CH4/O2 concentration update that *consumes* `XHNET` after this sub-block would run) is confirmed present and cited (`ecosys-ng/src/redistribution/canopy/gas_closeout.zig:3`, `ecosys-ng/src/atmosphere/canopy_gas_state.zig:5`), so the citation-search method is validated as working for this file region -- the absence of a `:1093x` hit is not an artifact of the search method.

Experiment 2 -- identifier search: grepped for `RC4OK`, `ROGOK` (the Fortran local variable names, shared with `extract.f`'s twin), and for `TCMBX`/`COXYGK`/`CCH4GK` used in a canopy-air (umol/mol) context. Result: `TCMBX` appears in Zig only as `minimum_combustion_temperature_k` inside `ecosys-ng/src/soil/organic/combustion.zig` and `ecosys-ng/src/plant/root/plant_root_disturbance.zig` -- both are the *solid-fuel Arrhenius combustion trigger* (matching `nitro.f`'s `TFNCOS` computation, a different mechanism), not the canopy-air M-M kinetics gate. No canopy-air-scale (`umol_per_mol`-parameterized) implementation gated by a ground/bulk-canopy temperature threshold was found. The nearest structural analogue, `canopyFireCombustion` in `ecosys-ng/src/plant/exchange/soil.zig:679-718` (parameterized in `oxygen_half_saturation_umol_per_mol`/`methane_half_saturation_umol_per_mol`, the right units), is called only from `ecosys-ng/src/plant/growth/shoot_fire.zig` and consumes a *plant-biomass-combustion carbon rate* as its `total_combusted_carbon_g` input -- a different physical quantity from `redist.f`'s `-XHNET` (an ambient net ecosystem CH4 flux, not a biomass combustion rate). This function is therefore not this mechanism, despite the superficial parameter-shape similarity.

Experiment 3 -- production accumulator trace: read the actual `ecosys_ng.zig` accumulation of `atmospheric_ch4_net_input_g_c` (Zig's `XHNET`), at `:5659-5697`. It is built from exactly three named, cited contributors: shoot-fire CH4 emission (`EXTRACT 192-194`), root-atmosphere boundary exchange (`EXTRACT 784-789`/`REDIST 6530-6578`), and canopy carbon exchange. There is no fourth term decrementing/incrementing it via a ground-surface secondary-combustion computation before it is passed to `atmospheric_canopy_gas_state.closeAcceptedHour` at `:5729-5749`. This confirms the term is absent from the accumulator itself, not merely uncited.

## Resolution

Cause and focused patch: not yet decided; no patch applied (read-only pass; no `zig build`/run performed, per this session's operating constraint).

Candidate dispositions for reviewer:
1. `retired-with-explicit-scope-approval` if a reviewer judges this secondary CH4 sink physically negligible (it acts on an already-small net CH4 flux, gated on a temperature threshold reached only during active high-heat fire) and explicitly approves dropping it.
2. `legacy-defect-corrected`-adjacent `unresolved`-cleared if implemented and shown to change the CH4/O2/heat ledgers by more than the accepted per-quantity tolerance.
3. Left `unresolved` (current state) pending a magnitude estimate -- no runtime evidence exists yet to judge materiality, and this pass was static-analysis-only.

Before/after results: n/a -- no patch applied.
Regression added and actually executed: none yet.
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN**. Per `PROJECT_CONTRACT.md`, this is a genuine candidate gap in a gas-conservation-relevant pathway (CH4/O2/CO2/heat), not merely a documentation gap -- it should not be closed by inference; a reviewer should either estimate its typical magnitude from an existing legacy reference run (comparing `HCBFG`/`RC4OK` magnitudes against other accepted hourly canopy gas terms) or explicitly scope it out.
