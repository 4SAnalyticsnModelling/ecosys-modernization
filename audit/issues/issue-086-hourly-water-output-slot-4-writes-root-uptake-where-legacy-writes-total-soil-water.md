# Issue 086 -- hourly water output slot 4 carries root water uptake in ecosys-ng where the legacy writes total soil water content

Status: **PARTIALLY FIXED 2026-09-21. Slot 4 (the wrong binding) is OPEN; the slot 27/48 label defect is FIXED.**

- **Slot 27/48 -- FIXED.** The hourly catalog now publishes `surface_volumetric_liquid_water_fraction` / `surface_volumetric_ice_fraction` in `m3 m-3`, matching the values it already carried and the names the daily catalog already used. Label and unit only; no value changed. Tests: `output_catalog` 55/55, `soil.water.output` 55/55, `editor` 69/69, `output` 196/196, all exit 0. Two now-stale comments in `io/output/editor_layout.zig:882-889` were corrected in the same change.
- **Slot 4 -- STILL OPEN**, deliberately. It needs a faithful `UVOLW` analogue, and `UVOLW` spans the snowpack, canopy, surface litter **and** the soil column (`redist.f:5445`, accumulated at `:5475`, `:5635`, `:6682`), not just soil layers. The predecessor audit's F-10 records that the existing daily `soil_water_storage` tracks the legacy daily `WATER` only "to 22%", so reusing it blindly would ship a **second** wrong quantity into a production output -- the very defect this issue is about. Specified rather than rushed.

Triple corroboration for the slot-4 finding (below) stands unchanged.

Prior status line: **OPEN, CONFIRMED DEFECT (filed 2026-09-21, adversarial Claude/Pi session).** A deck-selected production output column carries a **different physical quantity** in ecosys-ng than in the oracle. Both the column name and the value are the wrong quantity for that slot, there is no recorded justification anywhere in the source, and the owning module's own header comment claims to be the OUTSH translation. Found while building the first real legacy-vs-ecosys-ng output comparison (`outcompare.py`); it would have silently produced a meaningless column comparison.

This is **not** the `issue-085` class (an accounted-for inventory difference). This is a wrong binding.

## The defect

Hourly soil water stream (`f25wh1`, `fouts.f` `N=22`). Slot 4 of 50:

| side | column name | value actually written | citation |
|---|---|---|---|
| legacy | `TTL_SWC` | `UVOLW(NY,NX)*1000.0/AREA(3,NU(NY,NX),NY,NX)` | heading `fouts.f:166`, value `outsh.f:121` |
| ecosys-ng | `root_water_uptake[mm]` | `inputs.root_water_uptake_m3 * 1000.0 / inputs.local_surface_area_m2` | name `soil/diagnostics/output_catalog.zig`, value `soil/water/output.zig:136` |

`UVOLW` is **not** an uptake term. `redist.f:5445` documents it in the legacy's own words: `VOLWSO,UVOLW=total landscape, grid cell water content (m3)`. It is zeroed once per hour (`hour1.f:2412`) and accumulated over the layers (`redist.f:5475`, `:5635`, `:6682`), i.e. it is the cell's **total water storage**, reported in mm. Root water uptake is an hourly **flux**. A storage term and a flux are not interchangeable, and they do not even share a plausible magnitude.

The daily stream has the same legacy binding (`outsd.f:117`, `1000.0*UVOLW(NY,NX)/AREA(...)`), so this is not an hourly-only quirk.

## The other five slots in that group are fine

Checked, so the finding is isolated to slot 4 and the surrounding columns are not shifted:

| slot | legacy heading | legacy value (`outsh.f`) | ecosys-ng name | verdict |
|---|---|---|---|---|
| 1 | `EVAPN` | `TEVPGH*1000/AREA` (`:118`) | `evapotranspiration` | consistent |
| 2 | `RUNOFF` | `-WQRH*1000/TAREA` (`:119`) | `runoff` | consistent |
| 3 | `SEDIMENT` | `USEDOU*1000/TAREA` (`:120`) | `sediment_discharge_water` | consistent |
| **4** | **`TTL_SWC`** | **`UVOLW*1000/AREA` (`:121`)** | **`root_water_uptake`** | **WRONG QUANTITY** |
| 5 | `DISCHG` | `HVOLO*1000/TAREA` (`:122`) | `external_water_outflow` | consistent |
| 6 | `SNOWPACK` | `(VOLSS+VOLIS*DENSI+VOLWS)*1000/AREA` (`:123-124`) | `surface_water_equivalent` | consistent |

There is **no root-uptake slot anywhere** in the legacy hourly water editor ladder (`fouts.f:163-168` for the six fixed slots; `:169` onward is `WTR_1..20`, then `SURF_WTR`, `ICE_1..20`, `SURF_ICE`, `ACTV_LYR`, `WTR_TBL`). So ecosys-ng did not relocate a legacy quantity -- it introduced a new one and placed it where `TTL_SWC` belongs.

## It is live in production, and deck-selected

Slot 4 is selected `YES` by **both** decks, and the two editor files agree on every slot:

```
ORACLE runottawa/f25wh1                                  1-18, 20-48, 51-55
ZIG    runottawa_input_files/write_output_options/f25wh1  1-18, 20-48, 51-55
```

(Slot 19 = `WTR_13` is unselected in both, which is why the oracle header reads `WTR_12 | WTR_14`; slots 51+ fall outside `fouts.f`'s `DO 1022 L=1,50` loop.) So input equivalence holds and the column is genuinely requested. The run-013 candidate deck emitted it, so the path is live, not dormant.

## No documented justification

`soil/water/output.zig` contains **no** reference to `outsh.f`, `UVOLW`, or `TTL_SWC` -- checked by direct grep. Its own header comment (`:3-4`) reads "Runtime-sized hourly soil-water diagnostics translated from OUTSH choices 1..50", which asserts the opposite of what slot 4 does. Contrast this with how carefully the same codebase documents its *deliberate* departures (for instance `MATRIX-ENTRY-OVERFILL-DOMAIN-001`, or `STARTE-010` in `soil/gas/inventory_initialization.zig:39-57`, which explicitly warns that a day-zero dissolved-gas comparison "will differ by construction"). The absence of any such note here is itself evidence that this is an oversight rather than an approved replacement.

## Why it matters

Directly against the "outputs comparable to the legacy oracle" release criterion. A comparison harness aligning on slot position -- which is the only thing the editor ladder gives it -- will compare a storage term in mm against a flux in mm, and report a large unexplained divergence in a column that is simply bound to the wrong thing. That is the `issue-014` failure mode in a new place: the number is wrong for a reason nobody recorded.

It also means `TTL_SWC`, a whole-cell water-storage diagnostic that the deck asks for, is **not available at all** in ecosys-ng's output, while an extra quantity nobody asked for occupies its slot.

## Recommended fix, not applied here

Bind slot 4 to the cell's total soil water content (the `UVOLW` analogue: sum of layer liquid water, consistent with `redist.f:5475`/`:5635`/`:6682`'s accumulation, converted `*1000/area` to mm) and name it accordingly. Then decide separately whether `root_water_uptake` deserves a slot of its own; if kept, it needs a feature-register entry as an addition, since the legacy ladder has no such slot.

**Not applied in this pass** because it changes a production output file's contents, which invalidates any prior comparison evidence for that column, and because the right move is to fix it together with a regression test that pins slot 4 against `outsh.f:121`'s expression -- best done as its own scoped change rather than appended to a comparison pass. Verify before fixing that ecosys-ng actually publishes a total-soil-water accumulator; if it does not, one has to be added, which widens the change.

## Second, DISTINCT finding in the same stream: slot 27 has the right value under a wrong name and wrong unit

Separated deliberately, because the severity is different and conflating them would overstate the defect.

| side | column | value | citation |
|---|---|---|---|
| legacy | `SURF_WTR` | `THETWZ(0,NY,NX)` -- surface/residue layer **volumetric** water content, dimensionless | `outsh.f:145` |
| ecosys-ng | `surface_excess_liquid_water_depth` declared in **`m`** | `inputs.surface_volumetric_liquid_water_fraction` -- dimensionless | name `soil/diagnostics/output_catalog.zig`, value `soil/water/output.zig:14`, `:53`, `:140` |

**The value is correct.** The internal field is literally named `surface_volumetric_liquid_water_fraction` and is the faithful `THETWZ(0)` analogue; `WTR_k`/`ICE_k` are likewise `THETWZ(k)`/`THETIZ(k)` (`outsh.f:125-135`, `:146-155`) and ecosys-ng's `volumetric_liquid_water_fraction_layer_k[m3 m-3]` / `volumetric_ice_fraction_layer_k[m3 m-3]` match in both quantity and unit. So this is **not** a binding defect.

What is wrong is the published **name and unit**: a dimensionless volumetric fraction is advertised as a depth in metres. Anyone reading the column by its declared unit is wrong by a factor of the layer depth, and a comparison harness that trusts declared units would mis-handle it. The paired `surface_excess_ice_water_depth[m]` entry has the same shape against `SURF_ICE`.

Disposition: **label/metadata defect, fix is cosmetic and safe** (rename to `surface_volumetric_liquid_water_fraction`, unit `m3 m-3`, matching the field it already carries, and the same for ice). Lower risk than the slot-4 fix because no value changes -- but it does change an output header, so it still invalidates header-keyed comparison evidence and belongs in the same scoped change.

**Methodological note worth keeping.** Slot 27 looked exactly like slot 4 from the headers alone -- different name, different unit, obviously suspicious. Only reading the value producer separated them: slot 4 is a genuinely wrong quantity, slot 27 is a correct quantity with a wrong label. Judging either from the header would have produced a wrong disposition, in opposite directions. This is the same "trace the value, not the name" rule this project has already learned three times over for stale comments.

## Reproduction

```
uv run ecosys-audit/scripts/f77query.py show f77src/fouts.f --lines 158-172   # headings
uv run ecosys-audit/scripts/f77query.py show f77src/outsh.f  --lines 112-125   # values
uv run ecosys-audit/scripts/f77query.py grep UVOLW                             # redist.f:5445 defines it
```

Then compare the first six data columns of the oracle's `01998f25wh1` header against ecosys-ng's `*_f25wh1.txt` header.
