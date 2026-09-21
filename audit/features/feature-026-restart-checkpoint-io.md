# feature-026 -- restart/checkpoint I/O: legacy `wouts.f`/`routs.f` + `woutp.f`/`routp.f` versus ecosys-ng's bundle checkpoint subsystem

Status: **PARTIALLY ASSESSED, 2026-09-21 (adversarial Claude/Pi session).** The **legacy side is now verified** by an independent, reproducible tool check (result below). The **ecosys-ng side is inventoried but its state coverage is NOT verified**, and that remains the open gap. Restart integrity is a named release criterion, so do not read the legacy result as clearing the criterion.

Closes the coverage hole `issue-081` named as the four largest uncovered blocks in the whole in-build legacy scope -- `routs.f:148-490` (343 statements), `wouts.f:122-464` (343), `routp.f:113-261` (149), `woutp.f:105-253` (149), ~980 statements with zero traceability coverage from any prior pass -- at the **structural** level. It does not close them at the per-variable level.

## Verified result: the legacy restart streams are self-consistent, 568/568

Every legacy restart write has a positionally-aligned read with an identical I/O-list item count, across all six logical units, with **zero divergences**:

| unit | writer | reader | statement pairs | divergences |
|---|---|---|---|---|
| 21 | `wouts.f` | `routs.f` | 275 | 0 |
| 22 | `wouts.f` | `routs.f` | 96 | 0 |
| 26 | `woutp.f` | `routp.f` | 33 | 0 |
| 27 | `woutp.f` | `routp.f` | 68 | 0 |
| 28 | `woutp.f` | `routp.f` | 26 | 0 |
| 29 | `woutp.f` | `routp.f` | 70 | 0 |
| **total** | | | **568** | **0** |

This matters because legacy restart I/O is **sequential unformatted** Fortran: records are consumed positionally, so a single extra or missing record would misalign every subsequent read and silently corrupt all downstream restored state. It does not, on either pair.

Reproduce with `ecosys-audit/scripts/restartalign.py` (added this pass), run from the project root:

```
uv run ecosys-audit/scripts/restartalign.py            # all six units
uv run ecosys-audit/scripts/restartalign.py --unit 21  # one unit, verbose
```

### What this check does and does not establish

**Limitations, quoted from the tool's own `limitations` field** -- report these alongside the 568 number, per `CLAUDE.md`:

- It compares **logical statements** (fixed-form continuations joined on column 6) and the **count of top-level I/O-list items** per statement. It does **not** verify that item *k* of a write is the same variable as item *k* of the matching read.
- Identifier names legitimately differ between the two routines, so names cannot be the invariant: the very first record writes `I,IDATA(3)` and reads back `IDATE,IYR`. Both are 26 items, positionally consistent.
- It does not evaluate implied-DO bounds, so a write/read pair whose loop *extent* differs while its item count matches would not be caught. `JZ`/`JS`/`JP` dimension agreement is assumed, not proven.
- It does not execute anything. No checkpoint was written or read back in a running model.

**Process note worth keeping.** A first count by a naive physical-line `Select-String` for `^\s{6,}WRITE\(21` versus `READ\(21` reported **275 versus 274** and looked like a real one-record asymmetry. It was an artifact of the regex, not a defect: parsing continuations properly gives 275 on both sides. The reviewer lane's original count was right and the editor's grep was wrong. Anyone counting Fortran I/O statements by line-prefix grep will reproduce the same false positive.

## ecosys-ng counterpart: present and substantial, coverage unverified

`ecosys-ng/src/io/checkpoint/` holds a 20-file, ~500 KB subsystem. A structurally different design from the legacy two-unit sequential streams: a versioned, magic-headed, checksummed bundle format with a manifest.

Files confirmed to exist on disk this pass: `checkpoint.zig` (coordinator, `writeCoupled`/`readCoupledInto`, `coupled_magic = "ECOSCPST"`), `manifest.zig`, `bundle_writer.zig`, `bundle_reader.zig`, `bundle_io.zig`, `checkpoint_resume.zig`, `schedule.zig`, plus per-domain members `soil_geometry_checkpoint.zig`, `soil_runtime_checkpoint.zig`, `soil_biogeochemistry_checkpoint.zig`, `soil_organic_checkpoint.zig`, `transport_state_checkpoint.zig`, `water_table_checkpoint.zig`, `surface_boundary_checkpoint.zig`, `landscape_mass_balance_checkpoint.zig`, `canopy_state_checkpoint.zig`, `plant_development_checkpoint.zig`, `plant_root_checkpoint.zig`, `plant_accounting_checkpoint.zig`, `plant_checkpoint_metadata.zig`.

Independent corroboration that the format is real and in use: `audit/issues/issue-002`'s correction established that `f77example`'s `NNN.*.bin` files carry the `ECOSCPST` magic and are misplaced **Zig** checkpoint artifacts, not Fortran output.

Disposition: **`replaced-by-approved-feature`** for the format itself (binary bundle with version/magic/checksum and runtime rather than fixed `JZ`/`JS`/`JP` dimensions, versus sequential unformatted Fortran records). The *format* change is a defensible improvement; the *state coverage* is the thing that must match, and it is unverified.

## Open gaps, stated precisely

1. **State-coverage equivalence is unverified.** The reviewer lane asserted the Zig subsystem "covers all 12 functional state families identified in the legacy routines." That claim is **recorded, not accepted**: no per-family mapping from the 568 legacy I/O items to Zig checkpoint fields has been built, and a sweeping completeness assertion is exactly what the contract's "all agents agree is not a release decision" rule targets. This is the next real piece of work here.
2. **No executed round-trip test.** Nothing in this pass wrote a checkpoint and read it back, in either implementation. `PROJECT_CONTRACT.md` requires reproducibility/restart testing for G4; a write-then-read-then-compare-state test is the obvious discriminating check and does not exist in this record.
3. **Per-variable positional identity** within each matched statement (see limitations above).
4. **`routs.f:46`'s `ITILL` reinitialization to 0 under `IMNG.EQ.0`** was noted by the reviewer lane while surveying this area. Verified present this pass. It interacts with `issue-080` (tillage dosing) because it governs whether management state survives a restart at all; not analyzed further here.

## Traceability

`TRC-368` through `TRC-373`, one per logical unit, disposition `replaced-by-approved-feature`, status `NOT_ASSESSED` (structural alignment verified; state coverage and round-trip behavior not).
