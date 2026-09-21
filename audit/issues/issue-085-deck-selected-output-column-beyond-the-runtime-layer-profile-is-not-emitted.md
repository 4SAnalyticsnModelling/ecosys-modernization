# Issue 085 -- a deck-selected output column for a soil layer beyond the runtime profile is emitted by the oracle as a structural zero and not emitted at all by ecosys-ng

Status: **OPEN, needs an approved-intentional-difference record before G3 output comparison (filed 2026-09-21, adversarial Claude/Pi session).** Not a translation defect, not a binding error, and not a deck-input mismatch -- all three were checked and ruled out. It is a real, reproducible difference in the **emitted column inventory**, and the reason `issue-014`'s lesson applies: an unrecorded intentional difference gets misdiagnosed as a translation bug the first time someone runs a column-by-column comparison.

## The finding

For the Ottawa production deck's hourly carbon stream (`f25ch1`):

- the legacy oracle emits **18** data columns: `SOIL_CO2_FLUX ECO_CO2_FLUX CH4_FLUX O2_FLUX CO2_1..CO2_4 CH4_15 O2_1..O2_9`
- ecosys-ng emits **17**: the same set **without `CH4_15`**

`CH4_15` is the concentration in soil **layer 15**. This deck has **12** active soil layers (`layer_count=12`, from the run's own `STARTE chemistry beginning: cell_count=1 layer_count=12` line). Legacy's fixed `JZ=20` arrays therefore hold an untouched element for layer 15 and write it out as an exact structural zero -- confirmed in the raw bytes, the first data row's `CH4_15` field is `0.0000000E+000`, while its `O2_9` field (layer 9, inside the profile) is a real `0.1142405E+002`. ecosys-ng dimensions its profile at runtime, has no layer 15 to report, and so emits no column.

## What was ruled out, and how

**Not a deck/input mismatch.** The two decks' output-editor files select **byte-identical slots**. Parsed from each file's own `YES`/`NO` ladder:

```
oracle  runottawa/f25ch1                                    slots 1-8, 34-43, 51-53, 56-58
zig     runottawa_input_files/write_output_options/f25ch1    slots 1-8, 34-43, 51-53, 56-58
```

(Slots 51-58 fall outside `fouts.f`'s `DO 1021 L=1,50` heading loop and are ignored by both, which is why 24 selected slots yield 18 data columns.)

**Not an off-by-one in the layer mapping**, which was the more serious alternative and was checked first. `fouts.f:135-144` fixes the slot names exactly: `L=34` is `CH4_15`, `L=35..43` are `O2_1..O2_9`. ecosys-ng emits nine oxygen columns named `dissolved_oxygen_concentration_layer_1..9`, so slots 35-43 land on layers 1-9 correctly. Only slot 34 is dropped; the surrounding columns are not shifted.

**Not a missing layout entry either.** `io/output/editor_layout.zig:148` correctly declares the block as `.{ .layers = .{ .source_slot = 20, .source_layers = 15 } }`, i.e. slots 20-34 are `CH4_1..CH4_15`, and its own comment at `:142` reproduces `fouts.f`'s ladder faithfully. The layout knows about slot 34. The column is absent because the **runtime profile has no layer 15**, not because the mapping forgot it.

## Why it matters, stated without inflation

The lost value is an exact zero for this deck, so **no science is lost here** and no number changes. Two reasons to record it anyway:

1. **Release criterion "outputs comparable to the legacy oracle" is evaluated per column.** A legacy column with no candidate counterpart cannot be compared, and a comparison harness must account for it deliberately rather than silently dropping it -- the comparison skill's own rule is that every discovered output file and column must be accounted for.
2. **It generalizes beyond a zero.** The behavior is triggered by *any* editor selection naming a layer past the runtime profile. On a deck with more than 15 layers, `CH4_15` is a real value and both implementations would emit it; on this deck it is structurally zero. So the difference is a property of the **editor-selection-versus-runtime-profile** relationship, not of methane, and any stream with the same shape will show it (the same `.layers` runs exist for water, nitrogen and heat in `editor_layout.zig:152-186`).

## Recommended disposition

`replaced-by-approved-feature`, paired with the already-recorded runtime-dimension improvement (ecosys-ng replaces legacy's fixed `JZ`/`JS`/`JP` extents with runtime `grid.soil_layer_capacity`; see `feature-026` for the same design showing up in the checkpoint format). The scope note that makes it approvable: *for a selected layer outside the runtime profile the oracle emits an exact structural zero and ecosys-ng emits nothing; no modelled quantity differs.*

That disposition needs a reviewer, not just this record. Until it has one, a column-level comparison of `f25ch1` should report `CH4_15` as **accounted-for-and-excluded with a citation**, never as a pass and never silently.

## Open question not resolved here

Whether ecosys-ng should instead emit a zero column to keep the legacy column inventory byte-comparable is a **deliberate design choice**, and this record does not make it. Emitting a structural zero would maximize comparability; omitting it is arguably more honest about what the model represents. Whoever decides should note that the legacy value is not merely zero but *uninitialized-then-zeroed* array space (`starts.f` initializes the full fixed extent), so reproducing it is reproducing an artifact of fixed dimensioning, which `PROJECT_CONTRACT.md` warns against doing merely to match outputs.

## Reproduction

```
# oracle column set
Get-Content <oracle>/ottawa_run/01998f25ch1 -TotalCount 1

# zig column set
Get-Content <deck>/runottawa_output_files/modelled_outputs/carbon/*soil_or_eco*f25ch1.txt -TotalCount 1

# slot selections, which are identical
Get-Content <oracle>/ottawa_run/f25ch1
Get-Content "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa_input_files/write_output_options/f25ch1"

# the authoritative slot-to-name ladder
uv run ecosys-audit/scripts/f77query.py show f77src/fouts.f --lines 99-152
```

Oracle artifact provenance and its own limitations: `issue-084`.
