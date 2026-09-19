# Issue 029 -- `trnsfr.f`/`trnsfrs.f` vertical macropore/micropore double-depletion guard is applied only for downward (donor-current-cell) flow, not the mirror upward case

Status: OPEN, disposition remains `unresolved` (confirms and closes out the "secondary, lower-confidence lead, not closed" flagged in `audit/features/feature-009-trnsfr-trnsfrs-solute-gas-transport.md`'s Addendum; extended 2026-09-19 to the sibling salt file, see "Sibling-file confirmation" below; further extended 2026-09-19 with an independent architectural re-confirmation, see "Independent review, not closure (2026-09-19)" at the end of this file -- structural claims confirmed, but this issue is NOT closed this pass)
Owner: unassigned
Candidate/input hashes: `f77src/trnsfr.f` sha256 `466E28F9A84BC67DB7998F213B48FD56312CC9C01DA09E59E6C36117637635EC`; `f77src/trnsfrs.f` sha256 `89F5D7CD44C0561E9B7233AD42164CBB1F9A6DF84BF90480A7A126177C34C5F1`

## Confirmed content and location

`f77src/trnsfr.f:4373-4522` implements vertical (`N.EQ.3`) macropore convective solute/gas transport between a "current" cell (`N3,N2,N1`) and an "adjacent" cell (`N6,N5,N4`), gated on the sign of `FLWHM(M,N,N6,N5,N4)` (macropore water flux from `watsub.f`):

- **`FLWHM.GT.0.0`** (`:4373-4484`, current cell is the donor): a nested `IF(N.EQ.3.AND.VOLAH(N6,N5,N4).GT.VOLWHM(M,N6,N5,N4))THEN` (`:4396`, explicitly commented "IF VERTICAL MACROPORE FLOW ACCOUNT FOR MACROPORE-MICROPORE EXCHANGE IN CONVECTION") nets each donor concentration against the donor cell's own already-computed lateral macropore-micropore exchange flux before multiplying by `VFLW`, e.g. `RFHNH4=VFLW*AMAX1(0.0,(ZNH4H2(N3,N2,N1)-AMIN1(0.0,RN4FXW(N3,N2,N1)*VLNH4(N3,N2,N1))))*VLNH4(N6,N5,N4)` (`:4419-4421`). This guards against depleting the donor's macropore solute pool by more than it actually holds when a simultaneous lateral exchange (`RN4FXW` etc., a sink when negative) has already committed some of that same mass. The `ELSE` (`:4459-4484`, comment "OTHERWISE DON'T ACCOUNT FOR MACROPORE-MICROPORE EXCHANGE IN CONVECTION") uses the plain, unnetted form when the `N.EQ.3.AND.VOLAH>VOLWHM` condition fails.
- **`FLWHM.LT.0.0`** (`:4491-4521`, adjacent cell is the donor): computes every `RFH*` term directly from `*H2(N6,N5,N4)` with **no netting check at all** -- there is no analog of the `:4396` condition (which would naturally be `N.EQ.3.AND.VOLAH(N3,N2,N1).GT.VOLWHM(M,N3,N2,N1)` for this mirrored direction, checking the now-current-cell as receiver) and no subtraction of the adjacent cell's own lateral exchange flux (`RN4FXW(N6,N5,N4)` etc.) anywhere in this branch. It is structurally identical to the "otherwise don't account" `ELSE` form of the positive-flow branch.

**This is the same recurring shape this project has confirmed four times before** (issue-017 pond-vs-soil x2, issue-018 salt-vs-gas, issue-020 nitro.f litter clamp, issue-021 starte.f Gapon weighting): a defensive/corrective term coded for one side of a physically-symmetric pair (here, one flow direction of a bidirectional vertical macropore exchange) and never verified against, or extended to, its mirror case. Vertical macropore flow genuinely reverses direction over a simulation (e.g. capillary rise, differential drainage), so the missing upward-flow protection is not obviously inapplicable by physical construction -- it reads as an unexamined gap, matching the pattern rather than one of the correctly-ruled-out non-asymmetries (e.g. watsub.f snow-vs-soil conduction, uptake.f band-vs-non-band).

## Zig counterpart search and finding

The production transport driver (`ecosys-ng/src/driver/transport_step.zig`, sha256 `8561548CC1D67FCD2EBF8CE9F31706531EA5120188F2A85CA489DEC97076F7F0`) wires `soil/solute/transport.zig` (salts) and `soil/gas/transport.zig` (gases) together with `transport_solver.zig`/`coupled_gas_solver.zig`. Neither implements `trnsfr.f`'s donor-upwind-with-conditional-netting formula at all. Instead, the architecture (best represented by `ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig`, sha256 `012702E6DCCEA82DF4CC19CF6A4A37E82FF2FF320A99D2F2EEA9D1EDE0EC54BC`, `advance`/`solve`, `:76-167`) computes vertical inter-layer macropore transport as a symmetric, conductance-based face solve (Newton/Picard/Anderson-iterated, bounded and transactional per this project's solver policy) and then, as a **separate, subsequent, per-layer step**, applies the lateral macro-micro pore exchange via `soil/solute/transport.zig`'s `calculateConvectivePoreExchangeFlux`/`poreExchange` (already assessed `preserved` for the basic donor-upwind form in `feature-009`'s item 2, and confirmed there to exercise both flow directions symmetrically). Because vertical transport and lateral exchange are sequenced as two independent, symmetric operations rather than one intertwined single-pass forward-difference calculation, Zig's architecture has no equivalent of `trnsfr.f:4396`'s conditional netting term in *either* flow direction -- not the protected downward case, and not the unprotected upward case.

**Net effect: Zig does not inherit the Fortran's directional asymmetry, but only because it omits the entire ad hoc netting mechanism (for both directions), not because the asymmetry was identified and symmetrically fixed.** Whether Zig's iterative, bounds-checked, transactional solve (`acceptLocalConservation`, `aqueous_extensive_transport.zig:153`) already provides an equivalent (or superior) safeguard against the same double-depletion scenario `trnsfr.f:4396`'s netting was defending against was not proven this pass -- it is architecturally plausible (iterative acceptance with local conservation checks is a more robust general-purpose guard than a one-off forward-difference patch) but not demonstrated with a targeted edge-case test (e.g. an unsaturated macropore layer, `VOLAH>VOLWHM`, undergoing simultaneous vertical macropore flow and a substantial lateral macro-micro exchange in the same step).

This general architecture (iterative macropore/micropore exchange replacing Fortran's forward-difference form) is the same class of change already flagged under `SOLUTE-XFRS-PHYSICAL` / `audit/issues/issue-018-xfrs-physical-fix-not-extended-to-gas-domain.md`, but that documented approval is specifically about the *diffusive* exchange formula (the `XFRS=0.05` cap replacement) -- it does not explicitly discuss or cover this *convective* vertical-netting mechanism. Extending that approval's scope to cover this finding is plausible but not confirmed by any citation found this pass.

## Sibling-file confirmation (2026-09-19, `trnsfrs.f` salt-solute audit pass, range `:3352-6814`)

The identical asymmetry is directly confirmed in the sibling salt file. `f77src/trnsfrs.f:5431-5688` implements the same vertical (`N.EQ.3`) macropore convective solute transport between a "current" cell (`N3,N2,N1`) and an "adjacent" cell (`N6,N5,N4`), gated on the sign of `FLWHM(M,N,N6,N5,N4)`:

- **`FLWHM.GT.0.0`** (`:5431-5626`): nested `IF(N.EQ.3.AND.VOLAH(N6,N5,N4).GT.VOLWHM(M,N6,N5,N4))THEN` (`:5473`, comment "IF VERTICAL MACROPORE FLOW ACCOUNT FOR MACROPORE-MICROPORE EXCHANGE IN CONVECTION") nets each of the 48 tracked salt/phosphate species' donor concentration against that species' own already-computed lateral macro-micro exchange flux, e.g. `RFHAL=VFLW*AMAX1(0.0,(ZALH2(N3,N2,N1)-AMIN1(0.0,RALFXS(NU(N2,N1),N2,N1))))` (`:5474-5475`). The `ELSE` (`:5576-5625`, comment "OTHERWISE DON'T ACCOUNT FOR MACROPORE-MICROPORE EXCHANGE IN CONVECTION") uses the plain unnetted form when the condition fails.
- **`FLWHM.LT.0.0`** (`:5627-5688`, adjacent cell is the donor): every `RFH*` term is computed directly from `*H2(N6,N5,N4)` with **no netting check at all** -- no analog of `:5473`'s condition (mirrored for the adjacent cell as receiver) and no subtraction of the adjacent cell's own `RALFXS(NU(N5,N4),N5,N4)`-style lateral exchange flux anywhere in this branch. Structurally identical to the unnetted `ELSE` form of the positive-flow branch, exactly mirroring `trnsfr.f`'s shape at `:4491-4521`.

Both files share the same process skeleton (confirmed at the top of `feature-009`'s dossier: "sibling routines, same process skeleton, tracking disjoint species sets"), and this defect is reproduced line-for-line in structure between them -- it is the same underlying authoring gap duplicated across the salt/gas sibling pair, not two independent defects. This is now the sixth confirmed file-location instance of this project's recurring directional-asymmetry pattern (issue-017 x2, issue-018, issue-020, issue-021, issue-029/`trnsfr.f`, and now issue-029/`trnsfrs.f`).

**Zig side**: the salt-solute production path shares the same generic, per-species-array vertical-transport architecture already documented above for gases -- `ecosys-ng/src/driver/transport_step.zig`'s `advanceSoilSolutes` (`:410-419`) applies `solute.calculateConvectivePoreExchangeFlux`/`calculatePoreExchangeFlux` uniformly over `0..micropore.species_count` (all 50 `transport_species.AqueousSpecies` members, confirmed including `hydrogen_silicate` at index 33), with vertical inter-layer transport itself handled by the symmetric, iterative, conductance-based `solute_solver.solve` (`:383-384`) rather than `trnsfrs.f`'s forward-difference form with its one-sided netting term. The same conclusion applies: Zig does not inherit the Fortran asymmetry for salts either, but only because the whole ad hoc netting mechanism was replaced by a different, symmetric architecture -- not because the asymmetry was identified and symmetrically fixed. This was not independently re-verified with a dedicated salt-specific edge-case test this pass; it follows from the shared-architecture evidence already gathered for the gas path.

## Disposition: `unresolved`

The Fortran-side defect is confirmed real (directional asymmetry, matching the project's recurring pattern). The Zig-side does not reproduce it, but the reason it doesn't (a wholesale architecture replacement whose approval scope has not been shown to explicitly cover this specific mechanism) has not been reviewed and documented for this specific case. Per contract, this cannot be marked `preserved` (Zig doesn't preserve the Fortran form, asymmetric or otherwise) or `legacy-defect-corrected` (no recorded review approving this as the resolution) or `replaced-by-approved-feature` (the specific approval scope is unconfirmed) without that review. **Disposition: `unresolved`**, filed as the fifth instance of this project's directional-asymmetry defect pattern.

## Next bounded action

1. An independent reviewer should determine whether `SOLUTE-XFRS-PHYSICAL`'s approval (or a separate, dedicated review) explicitly covers the vertical convective macropore-netting mechanism, not just the diffusive exchange formula -- if yes, reclassify as `replaced-by-approved-feature`. This applies to both the gas (`trnsfr.f`) and salt (`trnsfrs.f`) instances since they are the same underlying mechanism.
2. Failing that, construct a targeted matched-state test: an unsaturated macropore layer (`VOLAH>VOLWHM`) with simultaneous nonzero vertical macropore flow and a substantial negative (sink) lateral macro-micro exchange flux, run through both the legacy `trnsfr.f`/`trnsfrs.f` formula (by hand or a minimal harness) and the Zig `aqueous_extensive_transport.zig`/`transport_step.zig` solve, to confirm Zig's iterative acceptance does not allow the same over-depletion the netting term was written to prevent, in either flow direction, for both gases and salts.
3. Independent review before closing.

## Independent review, not closure (2026-09-19)

Re-read as part of a batch closeout pass covering this and five other Tier 2
Group A issues (`issue-020`, `issue-021`, `issue-025`, `issue-033`,
`issue-036`), under a read-only/no-build/no-test-execution constraint for
that pass. Unlike those five, this issue's own text explicitly declines
self-closure twice (2026-09-18 original filing and the 2026-09-19
sibling-file addendum), stating the equivalence between Zig's architecture
and the legacy netting term's protection "was not proven this pass" and
requires either a scope-approval review or a matched-state numerical test.

Independently re-read `ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig`'s
`advance` (`:76-167`) and `acceptLocalConservation` (`:729-768`), and
`ecosys-ng/src/driver/transport_step.zig`'s `advanceSoilSolutes` (`:348-`,
convective exchange at `:414`). This independently confirms the issue's
structural claim: vertical macropore transport is solved first, via a
symmetric conductance-based iterative solve (`solve`, `:173-`) with no
donor-direction-dependent term of any kind; the lateral macro-micro pore
exchange (`calculateConvectivePoreExchangeFlux`/`state_updatePoreExchange`/
`poreExchange`, `:129-141`) is then computed strictly afterward, reading the
already-updated post-vertical-transport amounts, not a shared pre-image
concentration. This sequential (not simultaneous) ordering is a plausible
source-level explanation for *why* the specific double-counting failure mode
`trnsfr.f:4396`'s netting term defended against (two flux computations both
derived from the same stale base-state concentration) cannot arise in
Zig's architecture in either flow direction -- but this is architectural
reasoning from reading the solver, not the matched-state numerical test the
issue itself calls for, and this pass's constraints (no `zig build`, no
executed binary/test) preclude performing that test now.

**No disposition change.** This issue is not marked closed, `preserved`,
`legacy-defect-corrected`, or `replaced-by-approved-feature` by this review.
No code comment was added (a citation comment is only warranted once a
disposition is actually confirmed, per this batch's own operating
instructions). The two next-bounded-actions above remain open and are the
correct path to closure: a scope-review of whether `SOLUTE-XFRS-PHYSICAL`'s
approval covers this mechanism, or the matched-state test. No traceability
row was added or altered for this issue this pass (`TRC-093` and `TRC-164`
both continue to correctly record `disposition=unresolved`).
