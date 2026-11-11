# issue-123 — AccumulatedCellConservationFailure clay cell=0 at 1999 d230 (scene-hour 5496+, total_hour ~14264)

## Status
REGISTERED 2026-10-27, during cycle-11 v8 from-scratch verification
(audit/runs/ottawa/cycle11-verify-v8-20261027, binary cd22ff864452152f9361f66d91998dab253df5cf16dc1bb4e04752b02fc6c068).
Engine EXITED 1 after accepting 1999 d229 (594 run-days). NOT yet root-cause-probed:
rewrite-source attribution (relayering vs other mineral-texture writers) pending TEMP123 bracket.

## Receipt (observed)
stderr line 312439 (run aborts right after `day advanced: scene_weather_hours=5496`):

    error: accumulated cell conservation failure: cell=0 quantity=clay
    before=1.0508189126618181e0 after=1.0508189126618206e0
    external_inputs=0e0 external_outputs=0e0 internal_production=0e0 internal_consumption=0e0
    residual=2.4424906541753444e-15 absolute=2.4424906541753444e-15
    normalized_relative=1e0 physical_limit=2.4424906541753446e-24
    arithmetic_roundoff_allowance=2.333286703097452e-15  (exceeds by ~4.7%)

followed by `error: AccumulatedCellConservationFailure`.

## Validator (VERIFIED by source)
validation/accumulated_cell_conservation.zig:
- baseline = immutable scene-start cell storage (hourly cellStorage basis, megagrams);
- continuity = latest-storage delta + booked terms vs zero expected (lines 103-115);
- closure = baseline-vs-latest (lines 117-122) with limit = abs_tol + rel_tol*scale +
  arithmeticRoundoffAllowance(scale, accumulated_steps) — allowance grows far slower than
  the observed unbooked drift walk, hence the mid-scene break at 5496 scene-hours;
- check runs EVERY accepted hour (postScienceAccounting before acceptHourAndPublish,
  enforced structurally by the file's own contract test, lines 375-385).
Clay inventory mirror (what "latest.clay_megagrams" is): plain sequential left-fold
`result.clay_megagrams += properties.clay_mass_megagrams[cell*cap+layer]` over active layers,
validation/landscape_mass_inventory_misc.zig aggregateSoilMineralTextureRange (lines ~65-79).
Sand/silt/rock_additive/cation_exchange_capacity/anion_exchange_capacity share the same fold
and the same accumulated check — clay is simply the first to break the allowance.

## Class identity
Third instance of the VERIFIED root class of issue-120/issue-121: cell-LOCAL slot rewrites
(~4600 naive moved=f*src; src-=moved; dst+=moved transfers per relayering hour in
soil/profile/relayering.zig applyLayerRedistribution) recompose the validator's inventory
with nonzero fp drift that no ledger books. issue-121 = organic-carbon accumulators at the
HOURLY tier (fixed by validator-mirror sum completion, D-16). issue-123 = MINERAL TEXTURE
quantities at the ACCUMULATED tier, where the allowance is ~zero-scale so the same per-event
drift (~1e-16..1e-15 Mg, few-layer fold) breaks through after thousands of hours.
cycle-10 unfixed verify and v7 smoke show 0 occurrences (different trajectory / event mix —
chaotic relayering-hour selection, D-6 precedent; class is trajectory-luck, not fix-created:
nothing in v7/v8 writes clay).

## Falsifier / repro lanes
- Resume lane armed: v8 deck checkpoints at scene-hour 14040 (1999 d220) + restart.manifest;
  flip f25y98 record-6 NO->YES relaunch -> expect identical fatal ~220 h later (~20-40 min).
- TEMP123 bracket (planned): validator-mirror clay/silt/sand before/after per cell around
  applyLayerRedistribution (and geometry-stage outer bound) proving the unbooked delta equals
  the accumulated walk; then validator-mirror completion fix (generalize sum_completion.zig).

## Fix policy (leader)
Same doctrine as D-16/D-17: NO gate, limit or tolerance change. Restore the validator's own
pre-rewrite texture totals bit-exactly inside the local rewrite (sum completion), so the
accumulated ledger sees exactly-zero unbooked drift; distribution across layers keeps hourly
layer-scope budgets; non-convergence warns, never silently drifts; mass-scale refusal guards.

## Probe receipts (2026-10-27)
- Resume-repro (pure v8, checkpoint 14040): BYTE-IDENTICAL fatal (before=1.0508189126618181
  after=1.0508189126618206) -> deterministic lane ~55 min (audit/runs/ottawa/cycle11-issue123-repro-20261027).
- TEMP123U (accumulated-validator per-hour unbooked deltas, hours 14041..14263, cell 0):
  67 events = 49 aec + 18 cec, magnitudes up to +/-1.1368683772161603e-13 mol;
  ZERO sand/silt/clay/rock events in the window. The fatal-hour (14264) clay jump of
  +2.4424906541753444e-15 (11 ulp) happens after the probe sample -> writer acts mid-hour,
  invisible to hour-boundary continuity.
  (cec/aec pass the gate only because their tolerances are loose; the same writers move the
  zero-tolerance clay/silt/sand/rock folds, whose breaks hit the accumulated gate first.)
- CENSUS FACT: suspended-sediment stages NEVER execute on this campaign (13 of 19
  instrumented stages zero) -> hourly_sediment.zig texture writeback is NOT the producer.
- Remaining writer set: relayering's mineral_remap calls (relayering.zig:644
  transferLayerFraction = per-pair naive fraction transfer of sand/silt/clay/rock/CEC/AEC;
  :773 rebaseLayerCarrier = fl(fraction x recomposed soil mass) recomposition) — inside the
  end-of-hour geometry stage, i.e. the same rewrite that produced issue-121's carbon drift.
- TEMP123B bracket probe (fold deltas around applyEndOfHourGeometry) running:
  audit/runs/ottawa/cycle11-issue123-probe2-20261027. Fix = wire
  soil/profile/texture_sum_completion.zig (3/3 unit tests green, bit-exact validator-fold
  restore + mass-scale refusal) into the relayering wrapper alongside the carbon completion.

## Fix execution and supersession (2026-10-27)
- TEMP123B bracket probe (audit/runs/ottawa/cycle11-issue123-probe2-20261027): 541 fold deltas
  in a 220 h window, ALL mineral quantities (clay 54, sand 113, silt 124, rock 26 rows), magnitudes
  0.5-1 ulp of ~1.05-scale totals (1.11e-16/2.22e-16 quanta), firing EXCLUSIVELY at relayer_exit;
  relayer_enter events carry only cec/aec chemistry churn. PRODUCER CONFIRMED:
  mineral_remap.transferLayerFraction (:644) + rebaseLayerCarrier (:773) inside
  applyEndOfHourGeometry, which runs AFTER accumulated accounting, so deltas stay invisible to
  hour-boundary continuity until the constant-baseline allowance breaks (11 ulp > 10.5) at 14264.
- FALSIFIER-1 (fix v1, bin 57f33b0b, audit/runs/ottawa/cycle11-verify-v9-20261027): REFUTED.
  Proportional distribution + finisher breached the LAYER tier (HourlyLayerConservationFailure
  sand layer_scope=10 residual 5.551115123125783e-16 vs effective_limit 4.858348514380635e-16
  at 1998 d64; engine killed at the same point, killed_reason.txt) and left 1-grid residuals
  (7.105427357601002e-15 at target 59.632900000000156) = non-convergence.
- Root cause of non-convergence (VERIFIED by permanent unit test): the validator fold's
  quantization grid at the CELL-FOLD magnitude (ulp 7.105427357601002e-15 at 59.6329...) can be a
  multiple of every individual slot ulp; a single-slot correction must commit THROUGH absorbed
  (fold-invisible) ulp steps until one lands the grid. v1 broke on non-improving steps and stalled.
- FIX v2 (shipped candidate, bin 1a8b569147f6cce3...): exact validator-order ulp-ladder restore
  (slotLadderCommit/exactSlotRestore in soil/profile/texture_sum_completion.zig): per-candidate
  chain evaluation foldWithSlot mirrors the validator's naive left fold; per-slot budget 12 ulp/hour
  (~70% of the ~17-ulp hourly layer allowance, fixing the tier breach); slots descending magnitude,
  <=4 passes; first fold==target wins; mass-scale refusal unchanged. Tests 4/4: fold identity,
  400-hour production-cadence rewrite every hour bit-exact (>=200 hours genuinely drifted),
  mass-scale refusal, production-signature one-grid stall guard.
- v10 shared from-scratch verification running: audit/runs/ottawa/cycle11-verify-v10-20261027
  (pristine deck, prod-examples inputs). Acceptance for this issue: zero AccumulatedCell- /
  HourlyLayer- / HourlyCellConservationFailure through and beyond 1999 d230 and frontier
  total_hour 18939, campaign EXITED 0, zero "texture sum completion residual" warns.
