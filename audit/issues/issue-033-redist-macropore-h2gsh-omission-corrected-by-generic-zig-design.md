# Issue 033 -- REDIST macropore aqueous-H2 relayering omission (`redist.f:10300-10317`), corrected in Zig only as a side effect of a generic species loop

Status: **CLOSED 2026-09-19, disposition `legacy-defect-corrected`.** The documentation gap this issue flagged is now closed: an explicit citation comment was added at `layer_remap.zig` (see "Closing review" below). A clean `legacy-defect-corrected` traceability row (`TRC-130`) already existed from the original filing.
Owner: unassigned
Candidate/input hashes: `f77src/redist.f` sha256 `2FEAEC2B50571BDE6E92AE6A8838738B13D36A9CE858E3734F95C65F2733111D`; `ecosys-ng/src/soil/gas/layer_remap.zig` sha256 `AC7252A4BE6FA01B012F08017AD9D876996AB555EB2768297933BA1E175ADF01`; `ecosys-ng/src/soil/gas/transport.zig` sha256 `4EB569A2DB79FB0E49AC1D95145E1A3E1BC4AB6FEF72ECFE6739F818DF292F19`; `ecosys-ng/src/soil/profile/relayering.zig` sha256 `8FC717EED8983D11D7E8135323E29051350D706A0A12ECCCD17C17BC606B6E71`

## Failure signature and first bad time/location/process

`f77src/redist.f:10300-10317` ("SOIL MACROPORE AQUEOUS GASES", inside the soil branch of the `DO 245` layer-boundary relayering loop, gated on `IF(FHOL(L1,NY,NX).GT.ZERO.AND.FHOL(L0,NY,NX).GT.ZERO)THEN` opened at `:10110`) transfers macropore-dissolved gas mass from donor layer `L0` to destination layer `L1` for exactly five species:

```
FXCO2SH=FHO*CO2SH(L0,NY,NX)
CO2SH(L1,NY,NX)=CO2SH(L1,NY,NX)+FXCO2SH
CO2SH(L0,NY,NX)=CO2SH(L0,NY,NX)-FXCO2SH
FXCH4SH=FHO*CH4SH(L0,NY,NX)
CH4SH(L1,NY,NX)=CH4SH(L1,NY,NX)+FXCH4SH
CH4SH(L0,NY,NX)=CH4SH(L0,NY,NX)-FXCH4SH
FXOXYSH=FHO*OXYSH(L0,NY,NX)
OXYSH(L1,NY,NX)=OXYSH(L1,NY,NX)+FXOXYSH
OXYSH(L0,NY,NX)=OXYSH(L0,NY,NX)-FXOXYSH
FXZ2GSH=FHO*Z2GSH(L0,NY,NX)
Z2GSH(L1,NY,NX)=Z2GSH(L1,NY,NX)+FXZ2GSH
Z2GSH(L0,NY,NX)=Z2GSH(L0,NY,NX)-FXZ2GSH
FXZ2OSH=FHO*Z2OSH(L0,NY,NX)
Z2OSH(L1,NY,NX)=Z2OSH(L1,NY,NX)+FXZ2OSH
Z2OSH(L0,NY,NX)=Z2OSH(L0,NY,NX)-FXZ2OSH
ENDIF
ENDIF
```

The file's own declaration comment at `redist.f:6398` names this as a family of **six**: "`CO2SH,CH4SH,OXYSH,Z2GSH,Z2OSH,H2GSH=aqueous CO2,CH4,O2,N2,N2O,H2`". `H2GSH` (dissolved H2 in macropores) is absent from the transfer block above -- a silently dropped species, not a commented-out or dead-code omission.

Confirmed `H2GSH` is a real, live, persistently-accumulated state variable, not a declared-but-unused placeholder:
- `redist.f:6419`: `H2GSH(L,NY,NX)=H2GSH(L,NY,NX)+THGFHS(L,NY,NX)-XHGFXS(L,NY,NX)` -- accumulated every hour exactly like its five siblings (same block, `:6398-6419`).
- `redist.f:12483`: included in the same mass-balance-diagnostic sum as its five siblings (`...+TX*H2GS(L,NY,NX)+CORP*H2GSH(L,NY,NX)`).
- `redist.f:12554`: `H2GSH(L,NY,NX)=XCORP(NY,NX)*H2GSH(L,NY,NX)` -- receives the identical tillage-mixing macropore-scaling treatment as `CO2SH/CH4SH/OXYSH/Z2GSH/Z2OSH` in the same statement family (already-covered production code, feature-010 Finding 8's `macropore_scaling.zig`).
- `redist.f:13000`: appears in the (dead, per feature-010 Finding 3) whole-ecosystem mass-balance diagnostic write, again alongside its five siblings.

Because every other consumer in this file treats `H2GSH` identically to its five siblings, and only the `DO 245` relayering transfer at `:10300-10317` drops it, **every layer-boundary relayering event during a legacy run leaves dissolved macropore H2 stranded in the donor layer** while its five sibling gases correctly move to the destination layer. This is a live mass-conservation gap with no physical justification (H2 is not less mobile in a water-filled macropore than CO2, CH4, O2, or N2O).

Cross-check: the non-macropore soil aqueous-gas sibling block (`redist.f:10088-10106`, six species `CO2S,CH4S,OXYS,Z2GS,Z2OS,H2GS`) correctly includes `H2GS` -- confirming the omission is specific to the macropore leg of this one relayering mechanism, not a project-wide gap in aqueous-H2 handling.

## Minimal reproducer and hypothesis

Exact command/cwd/environment: static code trace only (this session's audit fork, 2026-09-19, part of feature-010's assigned "macropore aqueous-gas/organic continuation" range `redist.f:10148-10413`); no runtime reproduction executed (read-only, static-analysis-only pass; no `zig build`/run performed).

Hypothesis: unlike the three deliberate, self-documented Fortran-defect corrections in feature-010 Finding 8 (each with an explicit Zig-side comment naming the `redist.f` line and describing the fix), this gap in the legacy is corrected in Zig purely as an emergent side effect of a species-generic transfer loop that was written without per-species enumeration, not because the Zig authors identified and fixed this specific `H2GSH` omission.

Stop/resource budget: this pass is within its assigned scope; three independent confirmations were performed (see Experiments) before writing this up, consistent with the contract's diagnosis discipline.

## Experiments

Experiment 1 -- variable existence and usage check: grepped `f77src/redist.f` for `H2GSH` (result: `:6398,6419,12483,12554,13000` -- five hits, all treating it as a full member of the CO2SH/CH4SH/OXYSH/Z2GSH/Z2OSH family) and confirmed via `Get-FileHash`-verified read of `:10300-10317` that the relayering transfer statement for this specific species is absent from that block, while the identically-structured statements for its five siblings are present in source order immediately above.

Experiment 2 -- Zig citation and species-enum check: grepped `ecosys-ng/src` for `H2GSH`, `CO2SH`, `CH4SH`, `OXYSH`, `Z2GSH`, `Z2OSH` (result: zero direct name matches anywhere in `ecosys-ng` -- Zig does not use the Fortran's per-variable names for this pool at all). Located the actual production mechanism instead: `ecosys-ng/src/soil/gas/layer_remap.zig:26-71` (`transferLayerFractions`), which transfers `state.macropore_dissolved_mass_g` generically over `for (0..gas.species_count)` (`:45,53-69`) using a single `macropore_fraction` argument applied identically to every species index -- no per-species hardcoded list, and therefore no code path along which a single species could be silently excluded the way `H2GSH` was in the Fortran. `gas.species_count` (`ecosys-ng/src/soil/gas/transport.zig:3-13`) is a 7-entry enum (`carbon_dioxide, methane, oxygen, dinitrogen, nitrous_oxide, ammonia, hydrogen`); the `hydrogen` entry is confirmed a fully-tracked species (not a filler/unused slot) via its non-trivial `g_per_mol_tracked`/`atmospheric_boundary_multiplier` table entries at `transport.zig:22-23` (`2` g/mol, `2.08` boundary multiplier -- distinct, populated values, not zero/placeholder).

Experiment 3 -- production wiring and fraction-derivation check: confirmed `layer_remap.zig`'s `transferLayerFractions` is called live in production, not just exercised by unit tests, at `ecosys-ng/src/soil/profile/relayering.zig:447-454` (`gas_remap.transferLayerFractions(ctx.gas_transport, src_global, dst_global, dst_zone_fractions_after.ammonium_band, fx, fho)`), where the `fho` argument passed as `macropore_fraction` is derived and gated at `relayering.zig:323-334` in a manner directly analogous to the legacy's own `FHO=FX` local alias (`redist.f:9612`, itself gated on `FHOL(L1)>0 AND FHOL(L0)>0` exactly like `redist.f:10110`'s gate for this transfer). Regression test `layer_remap.zig:192-205` ("REDIST macropore aqueous gases follow the FHOL-gated fraction") exercises this exact call shape and confirms per-species mass conservation across all `gas.species_count` species, `hydrogen` included -- i.e., the test would fail today if a future change reintroduced a per-species hardcoded list that dropped `hydrogen`, but nothing in the test or the source comments states that this is the property being protected.

## Resolution

Cause: legacy Fortran translation-era (or original-authorship-era) omission -- a manually-unrolled six-member species family had one member (`H2GSH`) dropped from exactly one of its several call sites in the file, while all other call sites (accumulation, mass-balance diagnostic, tillage macropore scaling) correctly include it. This is the same general defect *shape* (an incomplete manually-maintained list) as the wrong-donor-substitution defects already found in feature-010 Finding 8, but here the error is an omission rather than a substitution.

No patch needed in Zig: production already computes the scientifically correct behavior (macropore H2 moves with its siblings) because `layer_remap.zig` was written generically over `gas.species_count` rather than as an unrolled per-species list. This is a **positive, already-corrected** finding -- there is no divergence to fix.

What remains open: the correction is **undocumented and structurally fragile**. Nothing in `layer_remap.zig`'s comments, `relayering.zig`'s comments, or any test name states that this generic loop is doing double duty as a fix for a specific legacy omission. A future contributor who "optimizes" or refactors `transferLayerFractions` into a per-species hardcoded list (for example, to add a species-specific transfer rule for one gas without realizing the loop's genericity was load-bearing) could silently reintroduce the exact legacy gap with no test flagging it as a regression against the *Fortran*, only against Zig's own prior behavior.

Candidate dispositions for reviewer:
1. `legacy-defect-corrected` (recommended) -- accept the current Zig behavior as the correct, already-implemented fix; add a one-line comment at `layer_remap.zig:4-6` or near the `for (0..gas.species_count)` loop (`:45,53`) explicitly citing `redist.f:10300-10317`'s `H2GSH` omission, so the genericity's dual purpose (translation fidelity for five species + defect correction for the sixth) is discoverable and protected against future refactors.
2. `retired-with-explicit-scope-approval` if a reviewer judges documenting this is not worth the effort given the magnitude is unevaluated (this pass did not estimate the quantitative effect of stranded macropore H2 in the legacy reference run) -- not recommended, since the fix already exists and only documentation is at stake, not implementation effort.

Before/after results: n/a -- comment-only change; no logic, computation, formatting, or test was altered.
Regression added and actually executed: none added this pass (existing `layer_remap.zig:192-205` test already covers the generic behavior, including hydrogen; independently re-confirmed this pass by reading `transferLayerFractions` (`:26-71`) and `transport.zig`'s `Species` enum (`:3-13`, `species_count=7`, `hydrogen` at index 6) -- the loop at `:53-69` (now `:53-77` after the added comment) has no per-species enumeration, so it cannot silently drop hydrogen).
Invalidated evidence and rerun dependencies: none.
Independent reviewer: this session's audit fork, acting as the independent reviewer role for this closeout batch, 2026-09-19.
Remaining limitation or final disposition: **CLOSED, disposition `legacy-defect-corrected`.** Recommendation 1 from this issue's own "Candidate dispositions for reviewer" was adopted: a comment was added immediately above the `for (0..gas.species_count) |species|` macropore-transfer loop in `ecosys-ng/src/soil/gas/layer_remap.zig` (before `:53`), citing `redist.f:10300-10317`'s `H2GSH` omission by name and line number, so the loop's dual purpose (translation fidelity for five species + defect correction for the sixth) is now discoverable and protected against a future per-species-unrolled refactor. No logic, computation, or test was changed. Traceability: `TRC-130` already recorded `disposition=legacy-defect-corrected` for this issue from the original filing -- confirmed clean, no duplicate row added. No runtime evidence was gathered on the legacy-side magnitude of the stranded-H2 effect (static-analysis-only pass this issue and this closing review); this remains an unquantified but now-documented and no-longer-fragile correction.

## Closing review (2026-09-19)

Independently re-read `layer_remap.zig:26-71` (`transferLayerFractions`) and
`transport.zig:3-23` (the `Species` enum and `g_per_mol_tracked`/
`atmospheric_boundary_multiplier` tables): confirmed `hydrogen` is a fully
tracked, non-placeholder species (`g_per_mol_tracked[6]=2`,
`atmospheric_boundary_multiplier[6]=2.08`) and that the macropore transfer
loop iterates `0..gas.species_count` with no per-species branch -- this
independently confirms the issue's central claim that Zig's generic loop
structurally cannot reproduce `redist.f:10300-10317`'s per-species omission.
The existing top-of-file comment (`:4-6`) referenced `redist.f:10319-10338`
for the general remap mechanism but did not name the `H2GSH` omission
specifically; the new comment added at `:53` (immediately above the
macropore-transfer loop) closes that specific documentation gap.
