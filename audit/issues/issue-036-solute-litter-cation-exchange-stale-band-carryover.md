# Issue 036 -- SOLUTE.F litter cation-exchange closure reads a stale, leftover `RXNBQ` from the last-processed soil layer; Zig's litter path structurally excludes it (undocumented, plausibly beneficial deviation)

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected`.** Independently re-verified this pass (see "Closing review" below); Zig's litter path is confirmed structurally immune (zero closure weight, not merely zero value) to the legacy stale-`RXNBQ` carryover, now cited in-code.

Owner: found by this session's audit fork, 2026-09-19, during the FEAT-017 restricted-band-zone and litter-block follow-up pass (`f77src/solute.f:4127-5248`).

## What was found

`SUBROUTINE solute` loops over soil layers `L=NU(NY,NX),NL(NY,NX)` in `DO 9985` (`f77src/solute.f:158`, closing `CONTINUE` at `:3995`). Inside that loop, both the full-salt (`ISALTG.NE.0`) cation-exchange block (`:1210-1387`) and its restricted-domain (`ISALTG.EQ.0`) sibling (`:3348-3520`) compute a real, non-band-fraction-gated `RXNBQ` (band NH4 equilibrium exchange rate; `:1331` and `:3474` respectively) and use it in the Gapon-closure normalization:
```
TXXX=RXN4Q+RXNBQ+RXHYQ+RXALQ+RXFEQ+RXCAQ+RXMGQ+RXNAQ+RXKAQ
TXXY=ABS(RXN4Q)+ABS(RXNBQ)+ABS(RXHYQ)+...
RXNB=RXNBQ-TXXX*ABS(RXNBQ)/TXXY
```
`RXNBQ` is a plain local (no `SAVE`, no re-zeroing) that keeps whatever value it held from the **last soil layer processed before the loop closed** (`L=NL(NY,NX)`, the deepest layer for that column).

After the loop, surface-litter chemistry runs once per cell (layer 0), which has no NH4 fertilizer band at all -- litter's own cation-exchange block only ever computes `XN4Q`/`XN41` from non-band `AN41` (`:4360-4404` full-salt branch; `:4768-4812` restricted branch), never `RXNBQ`. Yet **both** litter cation-exchange closures reuse the identical `TXXX`/`TXXY`/`RXNB` formula verbatim, still referencing `RXNBQ`:
- Full-salt litter branch: `:4449-4461` (`TXXX=RXN4Q+RXNBQ+...`, `RXNB=RXNBQ-TXXX*ABS(RXNBQ)/TXXY`)
- Restricted litter branch: `:4857-4868` (identical pattern)

Because `RXNBQ` was never reset for litter, `TXXX`/`TXXY` -- which normalize the closure for **every** litter cation (`RXN4`, `RXHY`, `RXAL`, `RXFE`, `RXCA`, `RXMG`, `RXNA`, `RXKA`) -- are contaminated by a leftover, physically meaningless value from the deepest soil layer's band-NH4 equilibrium computed earlier in the same hourly call. This is order-dependent (whatever soil layer happens to run last) and has no documented rationale. `RXNB` itself (litter's own output of the formula) appears to be dead -- no `RN4B`/`TRXNB`-style band consumer exists for litter (`grep` of the litter section finds no downstream band-NH4 use) -- but the contamination of `TXXX`/`TXXY` still corrupts the real, consumed litter fluxes `RXN4`/`RXHY`/`RXAL`/`RXFE`/`RXCA`/`RXMG`/`RXNA`/`RXKA` (used at `:4987-4998` to build `RN4S`/`RHY`/`RAL`/`RFE`/`RCA`/`RMG`/`RNA`/`RKA`, which feed `TR*` mass-balance totals consumed by `redist.f`).

## What Zig does

`ecosys-ng/src/surface/litter_reaction_rates.zig` (sha256 `84303EB46E1A6AD04631A4F9A38DD8B3E6C0B94C358E275E2E08F5B6E1CB262B`), `exchangeRates` (`:780-825`), calls the shared `ecosys-ng/src/soil/solute/cation_exchange.zig` (sha256 `7E9D3B2C6FCBBEB926A3762BC52EBB067CBE175FDF8FAB0CCBE9A439DACE0EF5`) `calculateSourceOrder` kernel with `ammonium_band = 0` in both the concentration and exchange-state structs and `ammonium_band_fraction = 0` explicitly (`:784,804,819`). Inside `calculateSourceOrder`, `closeSiteChargeAndConvertToIonMoles` (`:285-321`) weights every coordinate's contribution to the closure `total`/`magnitude` sums by `siteCoordinateWeight`, which returns exactly `ammonium_band_fraction` (`:502-513`) for the ammonium-band coordinate -- i.e. **zero** for litter. There is no code path by which a stale/leftover value could reach litter's closure: the band coordinate's weight, not merely its value, is architecturally zero for every litter call. This is a structural, not incidental, difference from the Fortran's stale-read defect.

## Why this needs a record

Same shape as `issue-018`, `issue-020`, `issue-021` (all found this session): a Zig-side unification/simplification (one shared `cation_exchange.zig` kernel serving both soil and litter call sites) correctly does **not** reproduce a legacy quirk -- here, a genuine stale-variable carryover bug, not just a stylistic asymmetry -- but the decision has no feature-register entry, issue-tag, or `docs/model_changes.md` note anywhere in `cation_exchange.zig` or `litter_reaction_rates.zig`.

## Disposition

`unresolved`, pending a formal review/approval record. Zig's zero-weighted exclusion is very plausibly the scientifically correct choice (the legacy behavior is an unintended stale-read, not a deliberate design decision -- unlike the `:3578` `XMIN`/`XMINN` quirk documented in `issue-037`'s sibling finding, which the source's own surrounding structure suggests was at least stably reproduced rather than order-dependent on an unrelated loop's last iteration). Practical numerical impact is not evaluated this pass (static analysis only); the leftover `RXNBQ` magnitude at the moment litter chemistry runs depends on the deepest soil layer's band-NH4 disequilibrium in that hour, which is not necessarily small.

## Evidence

`D:\ecosys-modernization\f77src\solute.f:158,1331,3474,3995,4360-4481,4768-4891,4987-4998` (sha256 `DC0056F3EDEE5670F5EB4443802E829A24A0D3BAE1DE0C4644A33A5007442324`); `D:\ecosys-modernization\ecosys-ng\src\surface\litter_reaction_rates.zig:780-825` (sha256 `84303EB46E1A6AD04631A4F9A38DD8B3E6C0B94C358E275E2E08F5B6E1CB262B`); `D:\ecosys-modernization\ecosys-ng\src\soil\solute\cation_exchange.zig:285-321,502-513` (sha256 `7E9D3B2C6FCBBEB926A3762BC52EBB067CBE175FDF8FAB0CCBE9A439DACE0EF5`).

## Closing review (2026-09-19)

Independently re-read `litter_reaction_rates.zig`'s `exchangeRates`
(`:780-825`): confirmed `ammonium_band = 0` (concentration and exchange
state) and `ammonium_band_fraction = 0` are passed for every litter call.
Independently re-read `cation_exchange.zig`'s `normalizeSiteCharge`
(`:481-500`) and `siteCoordinateWeight` (`:502-513`): confirmed
`siteCoordinateWeight` returns exactly `ammonium_band_fraction` for the
`ammonium_band` coordinate, and this weight (not just the value) multiplies
that coordinate's contribution to both `total` and the final scale factor.
With `ammonium_band_fraction = 0` for litter, the band coordinate is
excluded from the closure by construction -- there is no code path by which
a stale carryover value could contaminate `TXXX`/`TXXY`, independently
confirming the issue's central claim.

Added a comment at `litter_reaction_rates.zig:780` (immediately above
`exchangeRates`, at the `ammonium_band`/`ammonium_band_fraction`
assignments) citing this issue and `solute.f:4449-4461`/`:4857-4868` by line
number, so a future refactor that wires a real litter band term does not
silently reintroduce the stale-`RXNBQ` contamination path. No test change:
no regression specific to this exact stale-carryover shape was identified
as missing beyond existing litter cation-exchange coverage.

**Disposition: `legacy-defect-corrected`.** Traceability: `TRC-137`
(existing row) records `disposition=unresolved` from the original filing; a
new row `TRC-292` was added to `audit/traceability/traceability.csv`
recording the closed `legacy-defect-corrected` disposition rather than
editing the historical row in place. Reviewer: this session's audit fork,
acting as the independent reviewer role for this closeout batch, 2026-09-19.
