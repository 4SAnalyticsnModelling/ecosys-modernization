# Issue 063 -- after issue-062's heat-floor-discard ledger fix, hour 2,894 now fails on a DIFFERENT, previously-masked field: `carbon_dioxide_carbon_g`

Status: NOT_ASSESSED/OPEN -- diagnosis-only, discovered while validating issue-062's fix. No fix attempted this pass.
Owner: unassigned
Discovered by: this session, 2026-09-19, immediately after implementing and unit-testing issue-062's shared heat-floor-discard ledger and attempting a live validation run resumed from a hour-2,880 checkpoint.

## Summary

Issue-062 diagnosed `RelayeringActivityConservationFailure` at hour 2,894 as caused by `heat_layer_remap.zig`'s VHCPRX-floor fallback (and/or `heat_step.zig`'s WATSUB-6907 solve-time discard) leaking into `relayering_activity.zig`'s `stageBoundary` heat_megajoules check. This session implemented the recommended fix (a `FloorDiscard` struct threaded from `heat_layer_remap.zig` through `relayering.zig` into `stageBoundary`'s `known_heat_floor_discard_megajoules` parameter, netted into the `heat_megajoules` comparison) and validated it with unit tests (see issue-062's disposition update).

**A live validation run, resumed from this session's own hour-2,880 checkpoint (see "Validation run" below), confirms the heat-floor-discard fix works exactly as intended -- and reveals that hour 2,894's `RelayeringActivityConservationFailure` was hiding a SECOND, independent, previously-masked conservation defect underneath it, on a completely different field: `carbon_dioxide_carbon_g`.**

## Evidence

Added temporary-turned-permanent diagnostic logging to `relayering_activity.zig`'s `stageBoundary` (both failure branches: `ReversedRelayeringActivity` and `RelayeringActivityConservationFailure`), since the function previously returned a bare error with no field/value context -- this is itself a small, permanent improvement (the project's own principle: "prefer explicit error propagation with coordinates/time/process context"), not a diagnostic-only throwaway.

Rebuilt `ReleaseFast` and re-ran the same resumed deck. Full failing log line (`verify-stderr.log` in this session's scratchpad, `prod-run-issue062-verify/`):

```
error: relayering activity conservation failure: cell=0 donor_layer=1 recipient_layer=0 field=carbon_dioxide_carbon_g
raw_loss=1.871191561431118e-4 raw_gain=1.0616077229168134e1 allowed=1.107024591227907e-8
donor_before=1.1070088596858334e1 donor_after=1.106990147770219e1 recipient_before=1.0825659535201865e-1
recipient_after=1.0724333824520153e1
```

then `error: hourly science failed: ... total_hour=2894 ... error=RelayeringActivityConservationFailure` (unchanged terminal error name -- both this defect and issue-062's original heat mechanism raise the same generic error, which is exactly why issue-062's own diagnosis, done from log text alone before this session added field-level logging, could not distinguish them).

## This is proof the issue-062 fix works, not a regression of it

`inventory.Storage`'s fields are checked by `stageBoundary` in **declaration order** via `inline for (std.meta.fields(inventory.Storage))`, and the loop returns immediately on the first field that fails. `heat_megajoules` is declared second (`landscape_mass_inventory_support.zig:36-37`, right after `water_m3`); `carbon_dioxide_carbon_g` is declared much later (`:52`), after eight `diagnostic_*` fields plus `oxygen_g`, `hydrogen_g`, `residue_carbon_g`, `organic_carbon_g`. Since the loop reached and failed on `carbon_dioxide_carbon_g`, every field checked before it -- including `heat_megajoules` -- **passed**. Before this session's fix, the identical scenario failed on `heat_megajoules` itself (issue-062's own evidence, and this session's own first, pre-fix validation attempt at this exact resumed hour showed the bare `RelayeringActivityConservationFailure` immediately after the WATSUB-6907 discard warning, consistent with the heat field failing first). This is a clean, deterministic, field-order-based proof that the heat-floor-discard netting fixed the mechanism it was built for.

## The new defect: `carbon_dioxide_carbon_g` is being manufactured at the recipient, not conserved

Donor (layer 1) loses essentially nothing (`1.87e-4` g C, consistent with a small REDIST boundary-displacement fraction `fx` for this hour). Recipient (layer 0 -- the SAME degenerate thin/dry cell-0/layer-0 state issue-060/062 already characterize as being at/below the VHCPRX heat-capacity floor this same hour) gains `10.6` g C -- roughly 100x the donor's loss and roughly 100x the recipient's OWN pre-transfer inventory (`0.108` g C). `allowed` (the acceptance tolerance for this field/scale) is `1.1e-8`, twelve orders of magnitude smaller than the actual mismatch. This is not a rounding/representation issue.

**Working hypothesis (NOT confirmed by a targeted experiment this pass -- diagnosis-only, per the project's three-experiment discipline):** `gas_remap.transferLayerFractions` (`ecosys-ng/src/soil/gas/layer_remap.zig`), the actual mutator called for this boundary's gas transfer (relayering.zig item "2. Gas"), is a pure `moved = fraction * source; source -= moved; destination += moved` transfer with no floor/fallback logic anywhere in it (read in full this pass) -- it cannot manufacture mass by construction, and its own regression tests pin exact conservation. The 10.6 g discrepancy must therefore come from something else that changes layer 0's `carbon_dioxide_carbon_g`-contributing state between `donor_before_activity`'s capture and the post-transfer `stageBoundary` capture, for this same boundary's processing window -- either:
1. A genuine local CO2-producing process (e.g. microbial respiration/decomposition, a mineralization reaction) that legitimately runs on layer 0 during this same hour and is being incorrectly attributed to (or double-counted with) this specific relayering boundary's before/after diff, when `stageBoundary`'s donor/recipient model assumes the diff is due to the transfer alone; or
2. A carrier-collapse defect analogous to issue-060/061's `aqueousCarrierM3` fix (`landscape_mass_inventory_phosphorus_ions.zig`) -- i.e. whatever computes the `carbon_dioxide_carbon_g` value for `relayering_activity`'s `SnapshotSource.capture_fn` at layer 0 may divide by (or otherwise depend on) the same near-zero water/aqueous carrier that collapsed this hour, in a module that was never updated with issue-060/061's floor fix because it is a different call site.

**This is explicitly NOT the same mechanism as issue-062** (that issue is about `heat_megajoules` and a heat-capacity floor; this is about `carbon_dioxide_carbon_g` and, if hypothesis 2 holds, a water/aqueous-carrier floor -- a mass-domain concern, not a heat-domain one). Per the task's own standing instruction not to conflate independent fixes, this is filed as a new, separate issue rather than folded into issue-062 or issue-060/061.

## What this is not

- **Not a regression of issue-062's fix.** The field-order proof above shows the heat mechanism is fixed; this is a different field entirely.
- **Not yet confirmed to be caused by the water-carrier-collapse mechanism (hypothesis 2) rather than a legitimate local-production attribution gap (hypothesis 1).** Both are plausible from the evidence gathered this pass; neither has been tested with a targeted reproduction.

## Recommended next steps (not performed this pass)

1. Read `relayering_activity.zig`'s production `SnapshotSource.capture_fn` wiring (the call site that supplies `carbon_dioxide_carbon_g`, likely in the same conservation-composition-root file that wires `landscape_mass_inventory_phosphorus_ions.zig` or a sibling gas-inventory module) to determine which of the two hypotheses above is correct.
2. If hypothesis 2 (carrier collapse): check whether that call site shares `aqueousCarrierM3`/`legacyNegligibleWaterVolumeM3` with issue-060/061's already-fixed guard, or has its own unguarded exact-zero-only substitution that needs the same floor.
3. If hypothesis 1 (local production attribution): determine whether `stageBoundary`'s donor/recipient model needs a "known local production/consumption" netting term analogous to issue-062's `known_heat_floor_discard_megajoules`, generalizing the same architectural pattern to a second, independent quantity.
4. A cheap synthetic reproduction (constructing the exact before/after `Storage` values and calling `stageBoundary` directly, as issue-062's own regression tests do) is strongly preferred over another full/resumed production run, per the project's bounded-experiment discipline.
5. Before spending another live run on this, consider checkpointing this session's hour-2,880 resume point somewhere durable (it currently lives only in this session's scratchpad) so a follow-up pass does not need to re-derive or re-run from hour 1.

## Disposition

No source fix attempted this pass -- diagnosis-only, filed promptly per the project's established discipline ("do not fix blind"). This is the new frontier for the "production run completes to the end" goal as of this pass. Issue-062's own fix and disposition are unaffected and not reopened by this finding (see issue-062's updated disposition, which now records this exact interaction).
