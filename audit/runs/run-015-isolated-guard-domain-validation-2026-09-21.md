# run-015 -- isolated guard-domain fix: the `RuntimeSoilPoreCapacityExceeded` abort is GONE, frontier unchanged, and a deeper conservation defect is now exposed

Date: 2026-09-21. Lane: editor (Claude Code), adversarial Claude/Pi session. One heavy run at a time respected (no other model process running at launch).

## Result

**The hour-3,253 `RuntimeSoilPoreCapacityExceeded` abort no longer occurs.** The run reaches the same accepted hour 3,252 and fails at 3,253 with a **different and much more diagnostic** error, `HourlyLayerConservationFailure`. So:

- **The guard-domain fix is vindicated.** That abort was a domain error, exactly as `issue-078`/`issue-083` argued from the oracle, and removing it removed the abort. Neither `RuntimeSoilPoreCapacityExceeded` nor the new `exceeds its physical bound` message appears anywhere in the log.
- **No regression.** Frontier is hour 3,253 in both this run and `run-014`'s pre-change baseline. This is the isolated control `run-013` never had, and it demonstrates that `run-013`'s 280-hour regression came from the *other* change (the donor-only relief rewrite), not from this one.
- **The frontier does not advance.** A second, genuine defect sits at the same hour and is now visible because the false guard is no longer masking it.

## What was under test -- exactly one change

`ecosys-ng/src/soil/profile/runtime_material_refresh.zig` only. `git diff --stat` showed `1 file changed, 74 insertions(+), 6 deletions(-)`. The entry guard now rejects `matrix_occupied > matrix_bulk_volume_m3` instead of `matrix_occupied > previous_matrix_capacity`, admitting pore-capacity overfill as the oracle does (`watsub.f:211-217`'s signed `VOLP1Z` beside the clamped `VOLP1`; donor-bounded drain at `:4898-4902`; re-clamp and no error at `:4927-4932`; `hour1.f:4366` clamping rather than rejecting). Tag `MATRIX-ENTRY-OVERFILL-DOMAIN-002`.

**The relief-term rewrite from `run-013` was NOT reapplied and stays reverted.**

Pre-run evidence:
- `zig test src/module_index.zig` (unfiltered): **4375 passed, 1 skipped, 0 failed, exit 0** -- identical to the documented baseline, so zero regressions. (The count does not rise because this round's new assertions live inside the existing `"accepted material refresh is atomic..."` test rather than adding a test.)
- `soil.profile` filter 142/142, `accepted material refresh` filter 53/53.
- `zig build -Doptimize=ReleaseFast` exit 0, binary SHA-256 `7944903E4B8E9A0FAF843880C11475092F1E4E8E18B10B24F5BDC6194D7E8377`.
- Safety independently reviewed: reviewer lane round 22 returned **SAFE**, matching an independent check here. The decisive point is that the clamped air carrier's range is **unchanged** (`[0, capacity]`) -- a saturated layer already reads exactly zero today -- so no consumer sees a state it could not already see; and `soil/water/solver_solve.zig:2662-2666` already declares the signed negative legal in its own words, *"A negative value is an explicit displacement demand, not an invalid carrier"*, discarding the result and using the call only to validate the conserved inputs.

Run configuration identical to `run-014`: fresh from hour 1, no checkpoint, `robocopy /E` scratch copy of the deck with `runottawa_output_files` recreated empty, tracked deck never written.

## The newly exposed failure, and why its signature is valuable

```
census_positive_control      entries=3252 first_hour=1 last_hour=3252
tillage_soil_application     entries=2    first_hour=2532 last_hour=3252
fertilizer_application       entries=2    first_hour=2508 last_hour=3252

error: hourly cell conservation failure: cell=0  quantity=water before=5.690384395061972e-3 ...
error: hourly cell conservation failure: cell=0  quantity=heat  before=7.27782706332724e0  after=4.161966836177862e0
        external_inputs=1.0713762519314653e1 external_outputs=9.807355868551346e0
        internal_production=2.5300129612649214e-1 internal_consumption=0e0
        residual=-4.2752681740391765e0
error: hourly cell conservation failure: cell=17 quantity=water before=4.414122164330099e-6 after=3.1508646318483594e-3
        external_inputs=1.770269949390615e-4 external_outputs=1.0381433927985882e-4
        residual=3.0732378540248265e-3
error: hourly cell conservation failure: cell=17 quantity=heat  before=5.739470599797588e-3 after=3.949405471206189e0
        external_inputs=1.7737349190295377e0 external_outputs=2.5417091356352377e0
        internal_production=4.363720432467812e-1 internal_consumption=7.515295352685155e-11
        residual=4.2752681740404e0
error: HourlyLayerConservationFailure
```

Exactly **four** failures, on exactly **two** layer slots, and the numbers pin the mechanism:

1. **The heat residuals are equal and opposite to ~11 significant figures**: `cell=0` is `-4.2752681740391765` and `cell=17` is `+4.2752681740404`. That is not drift or a tolerance problem. It is a **transfer between two layer slots that no ledger booked** -- heat left slot 0 and arrived at slot 17 without an equal-and-opposite external entry on either side, which is precisely what this audit exists to catch.
2. **Slot 17 is not an active layer.** The deck runs `cell_count=1 layer_count=12` (the run's own `STARTE chemistry beginning` line). Slot 17 is beyond the twelve active soil layers, and it enters the hour essentially empty (`water before=4.414e-6`, `heat before=5.739e-3`) and leaves it holding real material (`water after=3.151e-3`, `heat after=3.949`).
3. **Slot 0 is the chronically-overfilled top layer.** Its water entering the hour is `5.690e-3`, consistent with the elevated top-layer water `issue-024` has tracked all along, and slot 17 gains `~3.07e-3` of water -- a substantial fraction of it.
4. **The second tillage event fires at exactly hour 3,252**, the hour before the failure. `issue-078`'s dynamic diagnosis recorded tillage at 3,252 and this run confirms it, with the census now showing **two** events (day 106 at hour 2,532 and day 136 at hour 3,252). That also resolves the apparent discrepancy flagged in `run-014`, whose census showed only the first event.

So the working picture: at hour 3,252 the second tillage event runs; material is displaced from the overfilled top layer into an **inactive** layer slot without being booked; and the hour-3,253 conservation audit catches it. Previously the pore-capacity guard aborted first and this was never reached.

**Not concluded here**: whether the displacement is done by the tillage adapter, by the geometry/relayering transaction, or by the refresh itself. The equal-and-opposite heat pair and the inactive-slot destination narrow it sharply, but naming the writer requires a bounded instrumented rerun. Filed as **`issue-089`** with that as its first experiment.

## Disposition

**The guard fix is kept.** It is oracle-verified, independently reviewed SAFE, has zero test regressions, removes a demonstrably false abort, and causes no frontier regression. Keeping it also means the next diagnosis works against a real defect rather than a masking one, which is strictly better ground.

Diagnosis budget: this is `issue-083`'s second of three experiments. The third should go to `issue-089`'s instrumented rerun, not to another variation of the relief-term idea.

## Honest statement of where this leaves v1.0.0

The production-run criterion is **still not met**. The deck completes 3,252 of 262,920 hours (1.24%) and the frontier hour is unchanged. What changed is the quality of the blocker: it was a guard whose domain contradicted the oracle, and it is now a conservation violation with a sharp, almost fully localized signature. That is progress in diagnosis, not in completion, and it should not be reported as the latter.
