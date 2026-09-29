# DEEPSEEK task — Round 00013 DESIGN (from CLAUDE)

Progress: commit 1b098e1 (exact phosphate-site projection) removed the SOLUTE crawl — DEV-011 was never
triggered in the r00005 run; per-hour cost back to ~150 ms. Frontier (strict r00005 + replays): 3,916 hours.

Blocker at hour 3917 (1998 d164 h05, 8.5 mm/h rain on a topsoil near saturation):
`surface/precipitation.zig:338 state_updateSoilIngress` — matrix ingress 9.17e-4 m3 > free air 7.47e-4 m3.
Uncommitted: overflow now raises `SurfaceIngressExceedsPoreCapacity` and the fixed-hour ladder retries it —
but it still overflows at 20/32/64 substeps (topsoil saturates during the storm).

Legacy ground truth: `watsub.f:939-947`, inside every NPH cycle, against the CURRENT air space:
  FLQRS = MAX(0, FLQ1 - VOLP1*FSNX); FLQRH = MAX(0, FLH1 - VOLPH1*FSNX)
  FLYM  = FLY1 + FLQRS + FLQRH           (excess to litter)
  HFLQR1 = 4.19*TKAM*(FLQRS+FLQRH)        (its heat at air temperature)
  FLQM = FLQ1 - FLQRS; FLHM = FLH1 - FLQRH; HWFLQM = HWFLQ1 - HFLQR1
Zig applies the same rule once per hour at prepare (`precipitation.zig:613-622 redistribute`), using
hour-start air (`precipitation.zig:143-151`).

Design a legacy-faithful per-substep FLQRS for Zig. Constraints I found:
- Per-substep water rates are rebuilt from hour-level `base_water_to_{litter,matrix,macropore}_m3_per_h`
  (`hourly_heat_water_solute.zig:5647-5651`, `:9486-9489`).
- Heat is bound in `prepareSubstep` from the base rates + `heat_to_{soil,litter}_megajoules_per_h`
  (`:4324-4366`; order pinned by the source test at `:11243-11257`); heat rates are NOT rebuilt per substep.
- Litter ingress `:704-713` precedes soil ingress `:821`; vapor rebases in between change topsoil water.
- The layer/cell ledgers book surface→litter vs surface→soil water; find where (file:line) — the reroute
  must move the booking with the water or layer water closure breaks.
Deliver (≤500 words, `.agent/adversarial/round_00013_deepseek.md`): exact insertion point(s), what state
to adjust (water, heat, ledger, precipitation-solute routing), how to stay per-substep without heat-rate
accumulation, and a discriminating unit test. Read-only. Reply `DONE <path>`.
