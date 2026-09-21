# Issue 080 -- ecosys-ng applies tillage soil mixing ONCE per event; legacy applies it on every substep of the tillage day (96 doses at NFH=4)

Status: OPEN, diagnosis-only, filed 2026-09-21 by the adversarial Claude/Pi session while identifying issue-078's legacy counterpart. Source-reading only: no production run, no build, no test executed for this finding specifically. Not a re-filing of issue-078 -- that issue is about the pore-capacity guard rejecting the resulting state; this one is about the number of mixing applications, which is a separate fidelity question that would remain even if issue-078's guard/relief question were fully resolved.

Owner: unassigned.
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979

## Finding

Legacy's tillage mixing block lives in `redist.f:11261-12842` and is gated at `redist.f:11276-11278`:

```
      IF(ITILL(I,NY,NX).GE.0.AND.ITILL(I,NY,NX).LE.20
     2.AND.XCORP(NY,NX).LT.1.0-ZERO2)THEN
```

Both gate operands are day-scoped, not substep-scoped:

- `ITILL(I,NY,NX)` is indexed by `I`, the day of year, read from the tillage management file.
- `XCORP(NY,NX)` is assigned once per day in `day.f:346-356` from that day's `ITILL`: `CORP=AMIN1(1.0,AMAX1(0.05,ITILL(I,NY,NX)/10.0))` then `XCORP(NY,NX)=1.0-CORP` (and `XCORP=1.0`, which closes the gate, on non-tillage days).
- Nothing inside the mixing block clears `ITILL` or raises `XCORP`, so the gate stays open for the entire day once opened.

`REDIST` is called inside the substep loop, not once per day: `soil.f:135` opens `DO 9995 J=1,24`, `soil.f:145` opens `DO 9990 NFZ=1,NFH` (closing at `:223`), and `:221 CALL REDIST` sits inside both. So on a tillage day the mixing block executes `24 * NFH` times -- **96 applications at the committed `NFH=4`** -- each one followed by the next substep's `:157 CALL WATSUB`.

ecosys-ng applies the mixing **once** per tillage event, from `applyDeferredTillageSoil` in `postScienceManagementAndGasAccounting` via `redistribution/tillage/runtime_adapter.zig`'s `apply()`.

## Why this is a science question and not just bookkeeping

The blend at `redist.f:12180-12181` is a contraction toward the mixing zone's mean, weighted by `CORP=1-XCORP`. Applying a contraction once leaves a partial blend; applying it 96 times converges to near-complete homogenization of the tillage zone. For the Ottawa deck's own values (`day.f:346-356` gives `CORP` of 0.8 for `ITILL=8` and 1.0 for `ITILL>=10`), a single dose and 96 doses are materially different end states for every mixed quantity, not only water: the same three-way blend carries bulk density, `FC`/`WP`, sand/silt/clay mass, `CEC`/`AEC`, Gapon selectivity coefficients, sediment, ice, heat, and the organic and solute families handled in the surrounding blocks.

It also interacts with issue-078, though it is not the same finding: legacy's 96 small doses are each separated by a full WATSUB pass that drains any resulting pore deficit upward (`watsub.f:212`, `:4898-4902`, `:4927-4928`, litter terminus `:3683-3685`), whereas ecosys-ng's single dose creates the entire excess at once with no intervening relief. issue-078's second-candidate experiment measured the consequence: 3 of the 4 mixing-zone layers simultaneously over capacity, with a `3.102824561055228e-3 m3` shortfall that no in-zone redistribution can absorb.

## Not yet established

- Whether the *first* dose's blend in ecosys-ng is numerically identical to legacy's first substep dose (structurally it appears to be -- the same `ti`/`tx`/`fi` weighting and the same `CORP` -- but this has not been checked term by term, and the previously-recorded translation of `redist.f:12137-12203` should be re-read against this cadence question rather than assumed).
- Whether ecosys-ng's single dose uses `CORP` or an already-cumulative equivalent fraction intended to represent the whole day. If the latter were true and documented somewhere, the cadence gap would be a deliberate lumping rather than an omission; no such record was found this pass, but the search was not exhaustive.
- The magnitude of the resulting end-state difference for any specific quantity. That needs either a matched-state kernel comparison (apply the ecosys-ng blend once versus 96 times to the same starting zone and compare) or oracle output at a tillage day. **The kernel comparison is cheap, needs no production run, and is the recommended first experiment.**
- Whether legacy's own repeated application is intentional design or a legacy defect. Note `redist.f`'s whole-ecosystem mass-balance check is already known to be 100% commented out, so legacy is not self-policing here; "legacy does it 96 times" is evidence about the oracle's behavior, not automatically evidence about correct physics. If ecosys-ng's single dose is judged better science, this becomes an approved intentional divergence needing a feature record, exactly like issue-024's disposition question.

## Recommended next action

Run the matched-state kernel comparison described above (single dose versus 96 doses of the existing `physical_redistribution.redistribute()` blend on one synthetic zone), then decide disposition. Do not fold this into issue-078's fix: that issue's remaining work is an hour-schedule/ordering decision about re-running the accepted upward-displacement path, and conflating the two would make both harder to review.
