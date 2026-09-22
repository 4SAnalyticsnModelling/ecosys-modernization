# Issue 096 -- retiring the HCND table orphaned `PSISA`/`THETS`, leaving the micropore discharge gate comparing a value against itself

Status: **REDISCOVERY -- the defect is real and confirmed, but it was ALREADY DOCUMENTED on 2026-09-10 with a deeper cause, and this issue's central accusation was WRONG. Retained as an independent corroboration, not as a new finding. See the correction below and `issue-097`.**

> ### CORRECTION, same day, after consulting the reference documentation
>
> **1. The defect is already known, and the prior diagnosis is better than mine.**
> `production_status_2026-09-10.md:307` (in the reference `docs/` tree, absent from this
> repository -- `issue-097`): *"layer 10 sits at saturation so its two matric potentials are
> equal, which breaks the `IFLGD` chain (`solver_residual.zig:432,458-471` =
> `watsub.f:5352-5378`) and makes micropore tile drainage identically zero."* It traces the
> cause **upstream** to initial over-saturation -- 271.9 mm excess, splitting exactly at
> `DTBLZ = 1.0 m`, with layers 10/11/12 at porosity from hour 1 -- and quantifies the effect
> as "~104 of the 106.6 mm tile-drainage gap". `discrepancy_register.md:43251` adds "broke
> the IFLGD tile-drainage chain", "held the water table a metre high".
>
> My analysis identified *that* the two operands coincide; the prior work identified **why**
> they coincide in practice (saturation clamps both to the same value) and what makes the
> layer saturated in the first place. Mine is the special case, theirs is the cause.
>
> **2. The accusation below -- that retiring the HCND table left a dependency the
> feature-boundary review should have caught -- is WRONG and is withdrawn.**
> `legacy_conductivity_class_table_removal_and_air_fraction_threshold_reconciliation.md:44-61`
> enumerates all three former consumers of the air-entry pair (the wetting-front enhancement
> at `flux.zig:46-55`; the interior face conductivity, now the Kirchhoff interval average
> `PR-KIRCHHOFF-001`; and the internal water-table sub-layer placement, now van Genuchten
> effective saturation at `boundary_topology.zig:190-192`, which "needs no air-entry
> threshold") and concludes: *"the air-entry fields are dead by **three independent
> intentional replacements**, not by oversight."* The review did catch them. My `hour1.f:4305-4306`
> `THETPX` "NOT REVIEWED" entry is covered by the third of those.
>
> **What still stands:** the defect is real, and the upstream cause the prior work names
> (initial over-saturation) is recorded there as **needing to be reopened** --
> `production_status_2026-09-10.md:301-305` says register entries `HOUR1-006`,
> `SOIL-INITSAT-001` and `EXEC-INITSAT-EXTENT-001` "must be **reopened as 'the fix was wrong,
> not missing'**". **That reopening is the real next action**, and it is upstream of
> everything this issue and `issue-094` describe.
>
> **What this issue adds:** an independent confirmation from the output side rather than from
> initialization (`issue-094`'s 3.91 mm against 213.51 mm), and an independent corroboration
> of the `DTBLZ = 1.0 m` split -- I measured a `WTR_k` bias that attenuates with depth and
> vanishes exactly there (`WTR_10` +0.016, `WTR_11` -0.0003) without knowing the prior work
> had located the same boundary.
>
> The original text is retained below **unedited except this header**, because the
> mechanism description is accurate and the reproduction steps are useful. Read it as
> corroborating detail, not as a discovery.

Severity high. It is not confined to drainage: the orphaned pair gates the general micropore flux and the litter-soil water exchange as well.

## The mechanism, in five steps

1. **`PSISA`/`THETS` are the air-entry pair, not a previous-state snapshot.** `hour1.f:2287-2288` sets `PSISA(L)=PSISK(K-1)` and `THETS(L)=THETK(K-1)` at the first downward crossing of `FSCNV*SCNV` by the vertical conductivity class -- the potential and water content at which conductivity falls to `FSCNV = 0.1` of saturated (`hour1.f:120`, and `:110` names it "fraction of Ksat at which air entry water potential" is taken). The surface counterpart is `hour1.f:2022-2023`. ecosys-ng's own comment in `micropore_hydraulic_conductivity_classes.zig:6-9` states it exactly, and adds that `hour1.f:2287-2288` "is the only place in the entire legacy tree that assigns either".

2. **The assignment lives inside the HCND conductivity-table construction.** It is a by-product of building that table; there is no other producer.

3. **Production replaced the HCND table with Mualem-van Genuchten.** `micropore_hydraulic_conductivity_classes.zig:11-17`: "`hydraulic_conductivity.zig` retains the runtime-sized HCND table and its tests as the canonical executable legacy record, but production intentionally uses the Mualem-van Genuchten conductivity in `solver_hydraulics.zig`... **Neither HCND implementation has a production reader.**" That constitutive replacement is recorded in `docs/model_changes.md` and is a legitimate approved feature.

4. **Retiring the table therefore orphaned the air-entry pair.** ecosys-ng *does* compute it correctly -- `hydraulic_conductivity.zig:40-41` declares `air_entry_water_potential_megapascal` and `air_entry_water_fraction`, and `:74-95` derives them from the same `FSCNV` threshold crossing, with `runscript.zig:1992` parsing the deck's `air_entry_fraction_of_vertical_saturated_conductivity`. But because that module has no production reader, **the values are computed and never consumed**, and the deck parameter is parsed and unused.

5. **The consumer substituted a comparison of a value against itself.** `solver_residual.zig:478-480`:

```zig
const base_fraction = base[layer] / properties.matrix_bulk_volume_m3[layer];
const base_matric_megapascal = try group_hydraulics.matricPotentialMpaAtAssumeValid(properties, layer, base_fraction);
const current_layer_discharge_candidate = base_matric_megapascal > grid.matric_potential_megapascal[layer];
```

`base` is copied straight from the grid at `solver_solve.zig:854`:

```zig
@memcpy(base[0..cells], grid.matrix_liquid_water_m3);
```

and `grid.matric_potential_megapascal` was last written by `solver_flux.zig:85-95`'s `state_update` **from that same water value**:

```zig
grid.matrix_liquid_water_m3[cell] = matrix;                                  // :85
grid.matric_potential_megapascal[cell] = try group_hydraulics.matricPotentialMpaAt(
    properties, cell, matrix / properties.matrix_bulk_volume_m3[cell]);      // :91-95
```

`matricPotentialMpaAt` and `matricPotentialMpaAtAssumeValid` (`solver_hydraulics.zig:301-321`) are the same computation -- identical clamp to `[residual, saturated]`, identical multiply by `gravitational_water_potential_mpa_per_m`, differing only in whether the pressure-head call validates. So **both sides of the `>` are the same function of the same number**, and the strict inequality cannot hold.

The gate is therefore satisfied only when some stage has modified `grid.matrix_liquid_water_m3` **without** refreshing `grid.matric_potential_megapascal`. It fires on *staleness between two arrays*, not on the physical condition the legacy tests. That is consistent with the measured residual: `issue-094` records artificial drainage of **3.91 mm against the oracle's 213.51 mm**, i.e. the gate does open occasionally but nothing like as often as the physics requires.

**What the legacy gate actually means**, for the record, because ecosys-ng's comment at `solver_residual.zig:502-505` states the intent incorrectly ("require every deeper layer... to remain wetter than its previous HOUR1 matric state"): `PSISA1(L) > PSISA(L)` asks whether the layer's **current** matric potential is above the **air-entry threshold** -- whether the layer is wet enough to conduct. It is not a comparison against a previous time step at all. `watsub.f:5353-5354`'s commented-out variant, `PSISA1 > PSISA + 0.0098*(DPTH-DTBLY)`, corroborates this by adding a depth head to `PSISA`, which only makes sense for a threshold.

## Blast radius: this is NOT only the artificial drain

Every live legacy reader of the orphaned pair is a place ecosys-ng needs a value it no longer produces. From `f77query.py grep`:

| legacy site | what it gates | ecosys-ng status |
|---|---|---|
| `watsub.f:5355`, `:5364` | `IFLGD` -- micropore discharge to the **artificial** water table | the identically-false gate above; `issue-094` |
| `watsub.f:5288`, `:5297` | `IFLGU` -- micropore discharge to the **natural** water table | same gate, shared by the `for ([_]bool{false,true}) \|artificial\|` loop at `solver_residual.zig:485` |
| `watsub.f:4667-4668`, `:4689`, `:4742` | **general inter-layer micropore flux** inside `DO 4320 N` | **NOT REVIEWED.** This is internal soil water movement, not a boundary term |
| `watsub.f:3649-3651`, `:3662-3664` | `THETS`-driven litter/surface water exchange (`FLQZ`) | **NOT REVIEWED.** Same neighbourhood as `issue-083`/`issue-089`'s `FLQR` path |
| `hour1.f:4305-4306` | `THETPX`, from `(THETW(L-1)-THETS(L-1))/(POROS(L-1)-THETS(L-1))` | **NOT REVIEWED** |

So the same orphaned quantity is required in at least five distinct live computations, of which only two have been examined. **The three unreviewed ones are the priority follow-up**, and the `THETS` litter exchange is especially notable because it lands in the exact region this session has been chasing from the other end.

## Why this class of defect matters beyond the instance

`PROJECT_CONTRACT.md`'s dispositions include `replaced-by-approved-feature`. This is a case where the replacement was legitimate and documented, but a **by-product** of the replaced code was a dependency of unrelated logic, and retiring the producer left the consumers to improvise. The feature-boundary review is where that should have been caught, and the generalisable check is: *when a legacy routine is replaced, enumerate every quantity it assigned -- not just the quantity it was replaced for -- and confirm each still has a producer.* `hour1.f:2287-2288` assigned two values as a side effect of building a table that was retired for an unrelated reason.

Worth adding: this defect is **invisible to unit tests**, because the comparison is well-formed, type-correct, finite, and never errors. It simply always evaluates false. A test asserting "discharge occurs when the layer is wet enough" would catch it; a test asserting the kernel arithmetic would not. `solver_tests.zig:569` and `:629` do set `artificial_water_table_depth_m`, so there is some coverage of the path -- those tests presumably construct states where the arrays are out of sync, which is exactly why the defect survived. **Checking whether those tests pass for the wrong reason is part of the fix.**

## Fix sketch, deliberately NOT applied

1. Give production a reader for the air-entry pair. `hydraulic_conductivity.zig:40-41` already computes `air_entry_water_potential_megapascal` and `air_entry_water_fraction` from the correct `FSCNV` crossing, so the value exists; it needs to be published into the solver's per-layer properties. Deriving it from the Mualem-van Genuchten curve instead would also be defensible -- MvG carries an air-entry parameter -- but it must be *a* threshold, not a re-derivation of the current state.
2. Replace `solver_residual.zig:480` and the deeper-layer scan at `:512-514` with comparisons of the **current** matric potential against that threshold, matching `PSISA1 > PSISA`.
3. Correct the comment at `:502-505`, which currently records the wrong meaning and would mislead the next reader into reproducing the same substitution.
4. Review the three unexamined consumers in the table above.
5. Re-examine `solver_tests.zig:569`/`:629` for passing on array staleness rather than on the physical condition.

**Not applied here** because it changes water-solver behaviour substantially -- it would switch on a boundary flux that is currently near-zero -- and `issue-091` makes production validation impossible. `run-013` in this session cost 280 frontier hours by landing unvalidatable science changes. Per `PROJECT_CONTRACT.md` this stays `unresolved`.

**Required before it lands**: `issue-091` cleared; a regression test that fails on the identically-false comparison (i.e. asserts discharge occurs for a wet layer with synchronised arrays); the three unreviewed consumers dispositioned; a full-suite run; and a production run compared against the oracle on `TILE_DRG`, `DISCHG`, `WTR_1`-`WTR_11` and `SURF_ELEV`.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/hour1.f  --lines 2278-2300  # PSISA/THETS assignment
uv run ecosys-audit/scripts/f77query.py show f77src/watsub.f --lines 5344-5378  # the IFLGD gate
uv run ecosys-audit/scripts/f77query.py grep 'PSISA\('                          # all readers
uv run ecosys-audit/scripts/f77query.py grep 'THETS\('
```

Then read, in order: `micropore_hydraulic_conductivity_classes.zig:1-17` (the retirement), `hydraulic_conductivity.zig:40-41` and `:74-95` (the orphaned producer), `solver_solve.zig:854` (`base`), `solver_flux.zig:85-95` (`state_update`), `solver_hydraulics.zig:301-321` (the two identical potential functions), `solver_residual.zig:478-480` (the comparison).

**Tool limitations, quoted as required.** `f77query.py` "does not compile the model, prove equivalence, or decide a gate" -- every claim here is a reading of source text on both sides. The one quantitative figure (3.91 mm against 213.51 mm) comes from `issue-094`'s `outcompare.py` comparison, which "does not prove either run reached its required end time" and covers 136 of the oracle's 286 available days. **No claim here is backed by a model run, and in particular the assertion that the gate is rarely satisfied is an inference from that drainage deficit, not a measured hit rate** -- instrumenting the gate remains the confirming experiment.
