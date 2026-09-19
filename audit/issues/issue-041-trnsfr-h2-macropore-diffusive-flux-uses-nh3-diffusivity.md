# Issue 041 -- `trnsfr.f:4744` H2 macropore-to-macropore diffusive flux uses the NH4/NH3 aqueous diffusivity coefficient (`DIFNH`) instead of its own (`DIFHG`); Zig does not reproduce this but only incidentally

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected`.** Independently re-verified this session (read `dissolved_gas_face_parameters.zig` in full): the per-species loop always indexes `reference_diffusivity_m2_per_h[species]` for that same species, so H2 always gets its own `HLSG` constant and never `ZNSG`, confirming the issue's own claim. A citation comment has been added at `ecosys-ng/src/soil/gas/dissolved_gas_face_parameters.zig:82-88` (immediately before the per-species loop) naming this issue and instructing future refactors not to reintroduce the legacy species-swap. A clean traceability row already existed for this exact disposition (`TRC-175`, `disposition=legacy-defect-corrected`); no duplicate row added.

Owner: found by this session's audit fork, 2026-09-19, during a full statement-level read of `trnsfr.f:3918-5906` (the "SOLUTE FLUXES BETWEEN ADJACENT GRID CELLS" / macropore-micropore exchange / gaseous transport block, the largest remaining unread contiguous range in `trnsfr.f` per `feature-009`).

## Background

`trnsfr.f:4552-4794` computes the diffusive flux of all 18 non-salt solute/gas species between the macropores of the current and an adjacent grid cell (lateral or vertical). For each species the pattern is: compute a species-specific diffusivity-times-tortuosity term `DIF<code>` (`:4713-4725`), then a flux `DFH<code>=DIF<code>*(C<code>H1-C<code>H2)` (`:4730-4767`). The per-species diffusivity constants used are the macropore-tortuosity-weighted aqueous diffusivities from `hour1.f` (`OCSGL2`,`ONSGL2`,...,`ZNSGL2` for NH4/NH3, `HLSGL2` for H2, etc.), each assigned to its own local variable name (`DIFOC`,`DIFON`,...,`DIFNH` for NH4/NH3, `DIFHG` for H2).

## What was found

At `:4717` and `:4725`:
```fortran
DIFNH=ZNSGL2(N6,N5,N4)*TORTL*AREA(N,N6,N5,N4)   ! NH4/NH3 diffusivity
...
DIFHG=HLSGL2(N6,N5,N4)*TORTL*AREA(N,N6,N5,N4)   ! H2 diffusivity
```
Both are computed correctly. But at `:4744`, the H2 macropore diffusive flux statement is:
```fortran
DFHHGS=DIFNH*(CH2GSH1-CH2GSH2)
```
It uses `DIFNH` (the NH4/NH3 diffusivity), not `DIFHG` (H2's own diffusivity, computed two lines earlier and otherwise unused anywhere in this block). Every structurally parallel instance elsewhere in the same routine uses the correct, species-matched diffusivity for H2:
- The **micropore** analog two blocks earlier, `trnsfr.f:4310`: `DFVHGS=DIFHG*(CH2GS1-CH2GS2)` -- correct.
- The **litter/soil-surface boundary** analog, `trnsfr.f:2090`: `DFVHGS=DIFHG*(CH2GS1-CH2GS2)` -- correct.

So `DIFHG` is computed at `:4725` and then never referenced again in this macropore block -- a dead assignment -- while `DIFNH` is (correctly) used for NH4/NH3 at `:4745-4747` *and* (incorrectly) reused for H2 at `:4744`. This is the classic signature of a copy/paste index error: the H2 diffusive-flux line was likely cloned from the immediately-preceding NH4/NH3 block during authoring and the diffusivity variable was never updated to match.

The bug is not inert: `DFHHGS` feeds directly into the aggregated macropore flux `RHGFHS(N,N6,N5,N4)=RFHHGS+DFHHGS` (`:4865`), which is accumulated into `XHGFHS` (`:4978`) and consumed downstream in `redist.f` as the actual H2 macropore-to-macropore mass transfer for the timestep. Physically, `ZNSGL2` (NH4/NH3's aqueous diffusivity, ~a different molecule/molar-mass class) is not equal to `HLSGL2` (H2's own diffusivity), so this produces a systematically wrong-magnitude H2 macropore diffusive flux whenever macropore water is present and connected between adjacent cells.

## Scope of the bug (confirmed, not extrapolated)

Checked every other location in `trnsfr.f` where `DIFHG`/`DIFNH` appear (full-file grep): `:2034-2098` (litter/soil-surface boundary block) and `:4276-4334` (micropore inter-cell block) both correctly pair `DIFHG` with H2 and `DIFNH` with NH4/NH3. The macropore-micropore *within-layer* exchange blocks (`:2475-2642` surface, `:4991-5298` general layers) use a single shared time-constant (`XNPHX`) rather than per-species `DIF*` diffusivities, so this specific bug shape cannot occur there, and confirmed it does not (H2's own state variables `H2GSH2`/`H2GS2` are used correctly in both). **The bug is confined to `trnsfr.f:4744` alone** -- the adjacent-grid-cell macropore diffusive-flux block, one statement, one species.

## Zig side

`ecosys-ng/src/soil/gas/dissolved_gas_face_parameters.zig` (sha256 `BDAC133847F460DA1D117B3B9ADC5E1C28E6C62B2C9CD7880F53C86D4F52547B`) is the Zig home for this diffusivity computation (doc comment `:46-47`: "HOUR1 `CLSGL/CQSGL/OLSGL/ZLSGL/ZVSGL/ZNSGL/HLSGL` combined with the exact TRNSFR aqueous face geometry"). It computes `macropore_conductance_m3_per_step` generically in a per-species loop (`:82-87`):
```zig
for (0..gas.species_count) |species| {
    const diffusivity_m2_per_step = parameters.reference_diffusivity_m2_per_h[species] * temperature_factor * step_h;
    ...
    self.macropore_conductance_m3_per_step[index] = diffusivity_m2_per_step * macro_tortuosity_per_m * area_m2;
}
```
with `reference_diffusivity_m2_per_h` (`:10-18`) an explicit 7-entry array keyed by species (`CLSG`,`CQSG`,`OLSG`,`ZLSG`,`ZVSG`,`ZNSG`,`HLSG` -- H2's own `7.34e-6`, distinct from NH3's `4.00e-6`). Because every species always indexes its own diffusivity constant in this shared loop, **the Zig implementation architecturally cannot reproduce this specific species-swap bug** -- H2 always gets `HLSG`, never `ZNSG`, regardless of which legacy statement it is standing in for.

This means Zig's H2 macropore-to-macropore diffusive flux is scientifically *correct* relative to the legacy routine's evident intent, but *different* from what the legacy reference actually computes at `:4744`. This is the same shape as this dossier's finding #3 (bubbling min/max asymmetry) and `issue-029`'s vertical-macropore-netting non-reproduction: a real legacy defect that the Zig rewrite does not carry forward, but only as an incidental consequence of a generic architecture, not because anyone identified, reviewed, and approved fixing this exact statement.

## Why this needs review, not an autonomous close

1. This is a genuine, reproducible, source-only defect (no compiler flag, no equivalent-under-limits argument rescues it -- `ZNSGL2 != HLSGL2` in general).
2. Per the project contract, a discovered legacy defect needs evidence and review before a disposition of `legacy-defect-corrected` is finalized, and should not be silently absorbed into "the generic design happens to differ."
3. H2 is a minor trace-gas pathway in this model (produced by fermentation, consumed by methanogens/homoacetogens); the macropore fraction of total soil gas flux is itself typically a minor pathway relative to micropore flux. The physical significance of this specific defect is likely small but has not been quantified this pass (no kernel test run, static read only per this session's read-only constraint).
4. Recommend: (a) a reviewer confirm the disposition as `legacy-defect-corrected` (matched-state kernel test isolating this one term would be the fastest confirmation), and (b) if confirmed, add an explicit code comment / feature-register cross-reference at `dissolved_gas_face_parameters.zig` noting the intentional non-reproduction, per this project's evidence discipline (the same gap already flagged for finding #3 and `issue-029`).

## Evidence

`D:\ecosys-modernization\f77src\trnsfr.f:2034-2098,4276-4334,4552-4794,4865,4978` (sha256 `466E28F9A84BC67DB7998F213B48FD56312CC9C01DA09E59E6C36117637635EC`); `D:\ecosys-modernization\ecosys-ng\src\soil\gas\dissolved_gas_face_parameters.zig:7-23,46-90` (sha256 `BDAC133847F460DA1D117B3B9ADC5E1C28E6C62B2C9CD7880F53C86D4F52547B`).

## Closing review (2026-09-19)

Independently re-read `ecosys-ng/src/soil/gas/dissolved_gas_face_parameters.zig` in full this pass (not just the excerpt quoted above). Confirmed: `RuntimeParameters.reference_diffusivity_m2_per_h` is a 7-entry array keyed by species (index 6 = H2's own `7.34e-6`, index 5 = NH3's `4.00e-6`), and `State.refresh`'s per-face loop (`for (0..gas.species_count) |species|`) always reads `parameters.reference_diffusivity_m2_per_h[species]` for the same `species` index it is currently computing -- there is no code path by which one species' conductance could read another species' constant. This structurally cannot reproduce `trnsfr.f:4744`'s `DIFNH`-for-`DIFHG` swap. Disposition confirmed: **`legacy-defect-corrected`**. A code comment citing this issue was added directly above the loop (`dissolved_gas_face_parameters.zig:82-88`). Traceability: `TRC-175` already carries this exact disposition; no new row needed.
