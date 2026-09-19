# Issue 034 -- REDIST surface-litter ion-inventory diagnostic double-counts `XOH2` (`redist.f:5828-5829`), deliberately and documentedly preserved in Zig as a "legacy pseudo-ion" parity quantity

Status: CLOSED -- `preserved` (confirmed 2026-09-19; see "Closing review" section below). Originally filed OPEN (positive finding -- current Zig behavior is an intentional, documented bit-for-bit reproduction of a legacy diagnostic-only arithmetic defect; needs a reviewer decision on whether this parity choice is still wanted now that it is independently reconfirmed, not a physics fix)
Owner: unassigned
Candidate/input hashes: `f77src/redist.f` sha256 `2FEAEC2B50571BDE6E92AE6A8838738B13D36A9CE858E3734F95C65F2733111D`; `ecosys-ng/src/validation/landscape_mass_inventory_surface.zig` sha256 `DF84FD096C3656D4166A089CA4A6E04BE640385A734FEE89969DA39C0598493C`; `ecosys-ng/src/validation/mass_balance_audit.zig` sha256 `FA5BC940F628BF1EC4CA701EDC2156AF369A60155345203FAF6AE205D49D09BD`; `ecosys-ng/src/validation/landscape_mass_inventory_phosphorus_ions.zig` sha256 `63EE3C87364E40EE6D56AA4ED7AB340F3887457B311A891747FE5CE2D1E0B9E5`

## Failure signature and first bad time/location/process

`f77src/redist.f:5802-5841` ("SURFCE LITTER SALT CONTENT" / whole-landscape ion-inventory accumulation, gated `IF(J.EQ.24.AND.NFZ.EQ.NFH)THEN`, i.e. executed live once per day, not dead code) computes `SSX`, the exchange-site/adsorbed-phosphate charge-equivalent contribution to the surface-litter (layer 0) total ion content `TION`/`UION`:

```
SSX=XHY(0,NY,NX)+XAL(0,NY,NX)
   2+XFE(0,NY,NX)+XCA(0,NY,NX)+XMG(0,NY,NX)
   3+XNA(0,NY,NX)+XKA(0,NY,NX)+XHC(0,NY,NX)
   4+XOH0(0,NY,NX)
   5+2.0*(XN4(0,NY,NX)+XNB(0,NY,NX)
   6+XOH1(0,NY,NX))
   7+3.0*(XOH2(0,NY,NX)
   8+XOH2(0,NY,NX)
   9+XH1P(0,NY,NX))
   1+4.0*(XH2P(0,NY,NX))
```

`XOH2(0,NY,NX)` (the adsorption site R-OH2 at the surface-litter layer) appears twice inside the `3.0*(...)` group -- lines `:5828-5829`. The structurally parallel per-soil-layer version of the same charge sum, `SSX` at `:7264-7272` (already depth-read under this dossier's Finding 1), instead pairs each non-band term with its **band** counterpart, e.g. `3.0*(XOH2(L,NY,NX)+XOH2B(L,NY,NX)+XH1P(L,NY,NX)+XH1PB(L,NY,NX))`. Litter (layer 0) has no band-fertilizer geometry, so the litter version's `XN4/XOH0/XOH1/XH1P/XH2P` terms correctly appear without a band pair (their band siblings, e.g. `XOH1B(0,...)`, are never assigned anywhere in `redist.f` and stay at their initialized value) -- except `XOH2`, where the second slot was apparently intended to be `XOH2B(0,NY,NX)` (harmlessly always zero, matching the pattern of its neighbors) but was instead typed as a second `XOH2(0,NY,NX)`, duplicating a real, live, non-zero state variable.

Confirmed `XOH2(0,NY,NX)` is real and actively updated, not a placeholder:
- `redist.f:4989`: `XOH2(0,NY,NX)=XOH2(0,NY,NX)+TRXH2(0,NY,NX)` -- accumulated every hour from `solute.f` exchange reactions.
- `redist.f:5244`: `XOH2(NU(NY,NX),NY,NX)=...+TOH2ER(...)` (a different index, top soil layer, not layer 0, but confirms the variable is a live exchange-site pool generally).
- `redist.f:6345`: soil-layer (`L`) analogue updated identically every hour.

Net numeric effect: the once-per-day surface-litter `SSX` (and therefore `SST`, `TION`, `UION(NY,NX)`) is inflated by an extra `3.0*XOH2(0,NY,NX)` mol-equivalents per grid cell, every day it is computed, relative to what the soil-layer formula's own pattern would produce if consistently applied to layer 0.

## Materiality

`TION`/`UION` are **not** dead code (unlike the commented-out `:12844-13017` whole-ecosystem balance-check WRITEs already documented in this dossier's Finding 3): they are read live by `f77src/exec.f:32,48,91` (`TLI=TION-TIONIN+TIONOU`; `DIFFI=(TION-TIONIN+TIONOU-TLI)/TAREA`, flagged to unit 18 as `'ION BALANCE LOST ON DAY, YEAR'` when `ABS(DIFFI).GT.1.0E-06`). Since `XOH2(0,NY,NX)` itself changes hour to hour (driven by exchange-reaction fluxes `TRXH2`), the extra `3.0*XOH2(0,NY,NX)` term is not a constant bias -- it injects a small amount of spurious apparent drift directly into the legacy's own daily ion-balance diagnostic. It never gates, rejects, or rolls back any state; it only affects a monitoring message and a landscape-scalar accumulator (`UION`) that this pass found no other legacy consumer for.

## Zig side: independently and deliberately reproduced, not missed

`ecosys-ng/src/validation/landscape_mass_inventory_surface.zig:341-346` computes the Zig analogue of this exact litter-layer charge sum and contains a **verbatim, self-aware comment**:

```
cell.phosphate_surface.deprotonated_site_mol_per_megagram +
    2 * cell.phosphate_surface.hydroxyl_site_mol_per_megagram +
    // Literal REDIST SSX counts XOH2 twice.
    6 * cell.phosphate_surface.protonated_site_mol_per_megagram +
    3 * cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram +
    4 * cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram;
```

`6 * protonated_site` is exactly `2 * (3 * XOH2)`, i.e. the Zig authors already found this defect independently (their comment names it precisely: "Literal REDIST SSX counts XOH2 twice") and chose to reproduce it bit-for-bit rather than correct it, in contrast to the corrected soil-layer sibling (`landscape_mass_inventory_phosphorus_ions.zig:540-551`, which correctly implements `XH1P/XH1PB` as three pseudo-ions and `XH2P/XH2PB` as four, citing `redist.f:7264-7272`, with no doubling).

This inventory value is not inert: it flows into `ecosys-ng/src/validation/mass_balance_audit.zig:264` (`.ions_mol = t.ion_inventory_mol - t.cumulative_ion_input_mol + t.cumulative_ion_output_mol` -- the direct structural analogue of `exec.f`'s `TLI`/`DIFFI`), which in turn has its own tolerance-gated `acceptance_limit_per_area` (`mass_balance_audit.zig:409`) and is surfaced in diagnostic output explicitly labeled `"legacy_pseudo_ions_mol_m2="` (`mass_balance_audit.zig:735`). The `legacy_pseudo_ions` naming shows the Zig authors already flagged this quantity as a legacy-bookkeeping convention (not a true charge/molar balance) rather than conflating it with the model's other, physically meaningful conservation ledgers.

## Resolution

Cause: legacy Fortran copy-paste defect -- the litter-layer `SSX` formula was adapted from the soil-layer formula by dropping each `*B` band term, but for `XOH2` the `B` was dropped from the variable name instead of removing the second occurrence, leaving a duplicate of the non-band term instead of a (harmless, always-zero) band term.

No patch needed in Zig: production already reproduces this exact legacy arithmetic on purpose, with a comment identifying it, and keeps the resulting quantity clearly labeled as a "legacy pseudo-ion" total distinct from the project's real conservation ledgers (water/heat/O2/C/N/P/other named ions each have their own dedicated `Balance` field in `mass_balance_audit.zig` that does **not** go through this doubled term). This is consistent with the contract's requirement for "exact agreement for... deliberately identical operations where justified" and with not silently reproducing undefined behavior -- the behavior here is well-defined (arithmetic, not undefined), documented, and its defect origin is named in-code.

What remains open: this pass independently re-derived the same defect from the Fortran alone (matching Finding 8's cross-check pattern in this dossier) and confirms the Zig comment's claim is accurate. What has **not** been independently confirmed:
1. Whether `mass_balance_audit.zig`'s `ions_mol_m2` acceptance-limit gate is currently wired into any pass/fail decision path for a production run, or is presently report-only.
2. Whether reviewers who approved reproducing this defect did so with the `exec.f` cross-reference in hand (i.e., knowing this specific quantity is the Zig analogue of the legacy `'ION BALANCE LOST'` diagnostic, not an arbitrary internal helper).

Candidate dispositions for reviewer:
1. `preserved` (recommended) -- accept the deliberate bit-for-bit reproduction of this legacy diagnostic-only defect as correct parity behavior; no code change needed. Optionally strengthen the existing comment at `landscape_mass_inventory_surface.zig:343` with the exact `redist.f:5828-5829` line citation (it currently says "Literal REDIST SSX" with no line number) for line-drift resilience per `EVIDENCE_GUIDE.md`.
2. `legacy-defect-corrected` -- if a reviewer decides the `legacy_pseudo_ions` quantity should be scientifically correct rather than bit-exact, change `6 *` to `3 * (protonated_site + 0)` (i.e. just remove the duplication) and re-verify `mass_balance_audit.zig`'s existing tolerance still passes; not recommended without a documented scope decision, since it would change a currently bit-matched legacy quantity.

Before/after results: n/a -- no code change made or needed this pass; this issue is a traceability/documentation action item confirming an already-correct, already-self-documented Zig decision, not a defect requiring a fix.
Regression added and actually executed: none added this pass (read-only static-analysis pass; no `zig build`/test run performed).
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN** pending a reviewer decision on (1) above (whether `ions_mol_m2` is live-gated) and whether to add the line-number citation improvement. No runtime evidence was gathered on the magnitude of the resulting phantom drift in either the legacy or Zig reference runs (static-analysis-only pass).

## Closing review (2026-09-19)

Independently re-read before closing:
- `f77src/redist.f:5802-5841`'s litter-layer `SSX` block confirmed to double `XOH2(0,NY,NX)` inside the `3.0*(...)` group (`:5828-5829`), against the soil-layer sibling's band-paired form at `:7264-7272`.
- `ecosys-ng/src/validation/landscape_mass_inventory_surface.zig:341-346` confirmed to compute `6 * cell.phosphate_surface.protonated_site_mol_per_megagram`, i.e. exactly `2*(3*XOH2)`, matching the legacy double-count bit-for-bit, and the pre-existing comment ("Literal REDIST SSX counts XOH2 twice") already named the defect precisely, before this pass strengthened it.
- Strengthened that comment with the exact `redist.f:5828-5829` line citation and this issue's file name (recommendation 1 in the issue's own "Candidate dispositions" list), a comment-only change -- no logic, computation, or test was altered.
- Did **not** independently resolve open question (1) from this issue's own "Resolution" section (whether `mass_balance_audit.zig`'s `ions_mol_m2` acceptance-limit gate is currently wired into a pass/fail decision path, vs. report-only) -- that remains a genuinely separate, unresolved question from the code-correctness question this closing pass addresses, and is left open for a future pass rather than blocking this disposition.

**Disposition: `preserved`** (the issue's own recommended option 1). The Zig behavior is a deliberate, already-documented, bit-for-bit reproduction of a legacy diagnostic-only arithmetic defect in a "legacy pseudo-ion" quantity that is explicitly labeled as distinct from the model's real conservation ledgers; per contract this qualifies as "exact agreement for... deliberately identical operations where justified." Traceability: `audit/traceability/traceability.csv` already has a clean row for this issue (`TRC-132`, disposition already `preserved`); not duplicated -- `traceability.csv` was off-limits this pass (already modified by a concurrent agent).
