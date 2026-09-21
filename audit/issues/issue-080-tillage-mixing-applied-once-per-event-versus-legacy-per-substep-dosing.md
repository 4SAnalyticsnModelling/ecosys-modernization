# Issue 080 -- ecosys-ng applies tillage soil mixing ONCE per event; legacy applies it on every substep of the tillage day (96 doses at NFH=4)

Status: OPEN, diagnosis COMPLETE for the mechanism (2026-09-21) -- both sides verified from source and the end-state difference settled analytically, not merely suspected: legacy homogenizes the tillage zone completely on the tillage day (residual gradient `(1-CORP)^96`, `~8e-68` at `CORP=0.8` and `~7e-3` even at the floored minimum `CORP=0.05`), while ecosys-ng applies one dose and leaves `(1-CORP)`, i.e. 20% to 95% of the pre-tillage profile structure intact. What remains open is not the mechanism but **which behavior is correct**, which is a scientific-policy decision, plus the approved-divergence record that G3 output comparison will need either way. Filed by the adversarial Claude/Pi session while identifying issue-078's legacy counterpart. Source-reading only: no production run, no build, no test executed for this finding specifically. Not a re-filing of issue-078 -- that issue is about the pore-capacity guard rejecting the resulting state; this one is about the number of mixing applications, which is a separate fidelity question that would remain even if issue-078's guard/relief question were fully resolved.

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

## Established by the follow-up pass (2026-09-21, same session; peer-asserted then independently re-verified here, both sides read directly)

**The dose fraction is the raw per-substep `CORP`, with no cumulative whole-day scaling.** `ecosys-ng/src/management/disturbance_schedule.zig:71-79` builds the tillage operation with `mixing_fraction = @max(0.05, code/10.0)` for codes `0-10` and `@max(0.05, (code-10)/10.0)` for codes `11-20`, and its own inline comments cite `day.f:347-348` and `day.f:353-354` as the source of exactly that expression and floor. So ecosys-ng takes legacy's per-application fraction and applies it once. This closes the "maybe it is a deliberate whole-day lumping" escape: there is no scaling anywhere on that path, and no record claiming one.

**Nothing clears `ITILL` or raises `XCORP` mid-day.** Every write in `f77src` was enumerated: `ITILL` is assigned only at `reads.f:792` (`=-1`, the no-tillage initialization), `reads.f:902` (`=IDIST`, the management-file load, indexed by day `IDY`) and `routs.f:46` (`=0`, restart reset, indexed by day `M`); `XCORP` only at `day.f:349`, `:355` and `:357`. All three `ITILL` sites live in input/restart routines called from `soil.f:28-71`, i.e. **outside** `DO 9995 J=1,24`; `DAY` is called at `soil.f:131`, inside the day loop but outside the hour loop. Every index is a day slot, not a substep. The gate at `redist.f:11276-11278` therefore stays open for the whole tillage day, and the mixing block runs all `24*NFH` times.

**End-state difference, by construction rather than by measurement.** For a layer wholly inside the mixing zone the blend at `redist.f:12180-12181` reduces to `VOLW <- (1-CORP)*VOLW + CORP*FI*TVOLW`, i.e. the layer's deviation from the zone mean contracts by exactly `(1-CORP)` per application. Residual gradient after `N` doses is `(1-CORP)^N`:

| `ITILL` | `CORP` | ecosys-ng, 1 dose | legacy, 96 doses |
|---|---|---|---|
| 8 | 0.8 | `0.2` (20% of the pre-tillage gradient survives) | `~8e-68` (exact homogenization to machine precision) |
| 1 (or 0, floored) | 0.1 / 0.05 | `0.9` / `0.95` | `~4.1e-5` / `~7.3e-3` |

So this is not a few-percent discrepancy: **legacy tillage homogenizes the mixing zone completely on the tillage day, at every tillage intensity including the floored minimum, while ecosys-ng leaves most or (at low intensity) nearly all of the pre-tillage profile structure intact.** The originally-planned "1 dose versus 96 doses" kernel comparison is therefore no longer needed to establish *that* the end states differ; the contraction factor settles it analytically. A kernel test would only confirm that the Zig implementation's own contraction factor really is `(1-mixing_fraction)`, which is worth one cheap regression but is not the open question.

## Still not established

- Whether the *first* dose's blend in ecosys-ng is numerically identical to legacy's first substep dose (structurally it appears to be -- same `ti`/`tx`/`fi` weighting, same `CORP` -- but this has not been checked term by term).
- **Which behavior is correct.** `redist.f`'s own whole-ecosystem mass-balance check is already known to be entirely commented out, so legacy is not self-policing here, and "legacy does it 96 times" is evidence about the oracle, not automatically about correct physics. Complete same-day homogenization of the full tillage depth is a strong physical claim; so is leaving 80% of the gradient after a mouldboard pass. This needs the same kind of scientific-policy decision as issue-024's disposition, and it should be made explicitly rather than settled by whichever choice makes outputs agree.
- The consequence for output parity if ecosys-ng's single dose is kept: every mixed quantity (water, ice, heat, bulk density, `FC`/`WP`, texture masses, `CEC`/`AEC`, Gapon coefficients, and the organic/solute families in the surrounding blocks) would diverge from the oracle at and after each tillage day, by construction. That has to be recorded as an approved intentional divergence before G3 output comparison, or it will be misdiagnosed as a translation defect.
- Whether legacy's own repeated application is intentional design or a legacy defect. Note `redist.f`'s whole-ecosystem mass-balance check is already known to be 100% commented out, so legacy is not self-policing here; "legacy does it 96 times" is evidence about the oracle's behavior, not automatically evidence about correct physics. If ecosys-ng's single dose is judged better science, this becomes an approved intentional divergence needing a feature record, exactly like issue-024's disposition question.

## Recommended next action

Run the matched-state kernel comparison described above (single dose versus 96 doses of the existing `physical_redistribution.redistribute()` blend on one synthetic zone), then decide disposition. Do not fold this into issue-078's fix: that issue's remaining work is an hour-schedule/ordering decision about re-running the accepted upward-displacement path, and conflating the two would make both harder to review.
