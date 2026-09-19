# Issue 028 -- `starte.f`'s initial manure-protein 50% NH4 pre-mineralization has no Zig counterpart

Status: OPEN (confirmed gap; escalates the "open trace, not a confirmed gap" note in `audit/features/feature-008-starte-soil-chemistry-initialization.md`'s Addendum)
Owner: unassigned
Candidate/input hashes: `f77src/starte.f` sha256 `BBE124F6809BD1720B94DDB8512FAAD5DA2FBAF7131C57A0A13E36496DC174A5`; `f77src/starts.f` sha256 `21D67B83BBAC47D9D7B9D882E2088D7F489F2D89EFB9C4F780634434B3152635`

## What the legacy code does

`f77src/starte.f:1688-1694`, inside the `K.EQ.3.AND.I.EQ.1` one-time soil-initialization branch (opened at `:1348`, closed at `:1706-1708`):

```
C     AMEND INTITIAL NH4 FOR INITIAL MANURE
C
C     ZNH4S=soil NH4+ (g)
C     OSN=intitial manure from soil file (g)
C
      ZNH4S(L,NY,NX)=ZNH4S(L,NY,NX)+0.5*OSN(1,2,L,NY,NX)
      OSN(1,2,L,NY,NX)=OSN(1,2,L,NY,NX)-0.5*OSN(1,2,L,NY,NX)
```

`OSN` is declared `OSN(5,0:4,0:JZ,JY,JX)` in `f77src/blk13a.h:9`, a shared `COMMON` array populated earlier in the initialization sequence by `f77src/starts.f:1453` (`OSN(M,K,L,NY,NX)=AMAX1(0.0,CFOSC(M,K,L,NY,NX)*CNOSC(M,K,L,NY,NX)/CNOSCT(K)*(OSNI(K)-OSNX(K)))`). Index `M=1` selects the **protein** organic-matter quality fraction (`starts.f:834`, "CFOSC=fraction of litter in protein(1),nonstructural(2)..."); index `K=2` selects the **manure** litter/residue complex specifically (matching `starte.f`'s own comment, "OSN=initial manure from soil file"). So this amendment takes exactly half of the *protein-nitrogen fraction of the manure complex* and moves it into the inorganic soil ammonium pool `ZNH4S`, leaving the other half as organic N -- a mass-conserving representation of the common agronomic assumption that a portion of manure nitrogen is already mineralized (as ammonium) at the time of land application, rather than 100% organic. `ZNH4S` itself was already seeded three lines of logic earlier at `starte.f:1443` from the soil-water NH4 solute concentration (`CN4U*FC*VLNH4*14.0`) -- this amendment is an *addition on top of* that base seed, not a replacement of it.

## What was searched in Zig, and what was found instead

1. **`ecosys-ng/src/soil/organic/initialization.zig`** (sha256 `639E652AFBA35B0B67CA319E0E8DA087D6D6A20591A29E62157A8B0BCCF36F62`) -- this is the actual Zig counterpart of **`starts.f`** (it cites `starts.f` lines 776-796, 1290-1356 directly, e.g. `:343,524`), not `starte.f`. It does implement a buried-manure carbon/nitrogen/phosphorus partition (`manureStructuralFraction`, `:220-233`, and the buried-manure path at `:544-648`), but this only reproduces `starts.f`'s protein/nonstructural/cellulose/lignin speciation of the manure pool -- it has no step that subsequently moves any fraction of that nitrogen into an inorganic ammonium pool. Feature-008's addendum searched here and correctly found nothing, but for the wrong file-identity reason (it is `starts.f`'s home, not `starte.f`'s).
2. **`ecosys-ng/src/soil/chemistry/initialization.zig`** (sha256 `57BE2C7F2E7592786B381331C604FBC03644F4323AA2B1047E63F4DF16F12B05`) -- this is `starte.f`'s actual Zig home (confirmed by its own citations of `starte.f:265-273,323-360,715-763`, etc.). Its ammonium seeding function, `seedProfilePrimaryState` (`:538-591`), sets `aqueous.ammonium_non_band`/`aqueous.ammonium_band` (`:563-565`) **exclusively** from `parameters.soil_ammonium_extract_multiplier * max(minimum_ammonium_g_n_per_megagram, inputs.ammonium_g_n_per_megagram) / masses.nitrogen * extract_scale` -- i.e. directly from the soil input file's ammonium field (the `starte.f:1443` analog, itself the subject of the separate, already-filed `issue-007-ottawa-ammonium-extract-multiplier-10x.md`). There is no term here, or anywhere else in this function, that reads any organic/manure nitrogen quantity.
3. A repository-wide, case-insensitive search for `manure` combined with `mineraliz`/`ammonium`/`0.5`/`protein` across all of `ecosys-ng/src` turned up the `starts.f`-side structural-fraction partition (organic_fertilizer_material_fractions.zig, soil/organic/initialization.zig) and an unrelated grazing-manure test constant, but no code anywhere that reduces an organic/manure nitrogen pool by 50% and adds the same amount to an inorganic ammonium pool at initialization.
4. Traced the actual production driver call sequence in `ecosys-ng/src/ecosys_ng.zig` (`soil_organic_initialization.State.init` at `:9673/9684`, then `soil_chemistry_initialization.seedProfilePrimaryState` at `:9814`, then the phosphate/cation-exchange/carboxyl seed calls at `:9909-9913`) -- no step between or after these performs the manure-protein-to-ammonium transfer.

**Conclusion: this is a genuinely missing translation, not a naming/location mismatch.** The Zig soil-organic-initialization path computes the manure protein-N pool at its full, un-reduced value, and the Zig soil-chemistry-initialization path seeds ammonium purely from the input file's mineral-N field -- neither is aware of the other for this specific 50/50 split. Any production soil input file that specifies a nonzero initial manure amendment (`OSN(1,2,...)` nonzero, i.e. a nonzero manure/protein fraction in the soil file's initial organic matter) will therefore start Zig with too little inorganic ammonium and too much organic manure-protein nitrogen relative to the legacy model, for however long it takes the coupled decomposition/mineralization kinetics to close the gap during the run.

## Materiality caveat

This defect is conditional: it only has a nonzero effect when the soil input deck specifies nonzero initial manure organic matter at the affected index. It was not verified this pass whether the current production example deck (`ecosys-ng-prod-examples/`) actually carries a nonzero initial manure amendment; if it does not, this gap is real but currently dormant for that specific deck. This should be checked before deciding urgency.

## Disposition: `unresolved`

Per `PROJECT_CONTRACT.md`, a discovered legacy defect (or, as here, a discovered *missing* translation) needs evidence and review, and is not to be silently dismissed. This is not a translation defect in an existing Zig routine but an absent routine -- there is no legacy behavior currently reproduced, correctly or incorrectly, for this specific mass transfer. **Disposition: `unresolved`**, escalated from feature-008's "open trace, not a confirmed gap" framing to a confirmed gap needing a scope decision: either add the missing initialization step (mass-conserving, mirroring `starte.f:1693-1694` exactly: `ammonium_non_band/band += 0.5 * manure_protein_nitrogen_g_n`, `manure_protein_nitrogen_g_n -= 0.5 * manure_protein_nitrogen_g_n`, at the same point in the initialization sequence, after both the organic and chemistry initialization states exist) or file an explicit `retired-with-explicit-scope-approval` decision if the project intentionally chooses not to port pre-mineralized-manure initialization.

## Next bounded action

1. Confirm whether the Ottawa (or any other currently-used) production soil input deck has nonzero initial manure organic matter, to establish real-world materiality.
2. If material, implement the missing 50/50 transfer as a small, reversible, regression-tested addition at the initialization call site in `ecosys_ng.zig` (after both `soil_organic_initialization.State.init` and `soil_chemistry_initialization.seedProfilePrimaryState` have run for a given layer), citing `starte.f:1688-1694` directly in the new code, with a unit test asserting mass conservation across the two pools.
3. Independent review before closing.
