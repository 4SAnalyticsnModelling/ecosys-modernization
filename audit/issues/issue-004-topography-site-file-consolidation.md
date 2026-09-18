# Issue 004 -- Legacy f25top98 (topography) appears merged into the Zig deck's f25si98; per-cell mapping not yet verified

Status: NOT_ASSESSED (input/binding equivalence question, not yet shown to be a defect)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979

Failure signature and first bad time/location/process:
Legacy `runottawa` (bash/stdin control script) reads two distinct files per run: `f25si98` (site descriptor, read as stdin line "f25si98") and `f25top98` (per-grid-cell topography, read as stdin line "f25top98"); see `f77example/Cool Temperate Maize-Soybean ON/runottawa` lines 6-7. `f25top98` has one row per grid cell (33 rows, matching the site count "33" on `f25si98` line 3), each row referencing a soil file name (`f25sol98`) in a trailing column.

The Zig production deck (`ecosys-ng-prod-examples/.../runottawa_input_files/landscape/`) has only `f25si98` and `f25sol98` -- no `f25top98`-equivalent file. Comparing headers: legacy `f25si98` line 1 is `45.3 92 5.4 3` (lat, then 3 more fields); legacy `f25top98` line 1 is `1 1 1 1 94.6 0.23 0.010 0.00 \n f25sol98` (grid row/col indices, then elevation=94.6, slope=0.23, two more topographic fields, then a soil-file reference). The Zig-side `f25si98` line 1 reads `92 5.4 3 94.6 0.23 0.00` -- i.e. it looks like the legacy site descriptor's fields 2-4 (`92 5.4 3`, latitude 45.3 dropped/relocated) were concatenated with the legacy topography row's elevation/slope/one trailing field (`94.6 0.23 0.00`, one of the four topography numeric fields from `f25top98` -- either `0.010` or the last `0.00` -- appears dropped or the two were merged into one). The per-row `f25sol98` soil-file reference from `f25top98` is not repeated in the Zig file, presumably because the Zig deck already names the soil file once via the separate `f25sol98` at the same directory level and does not need a per-row pointer.

Legacy/Zig source anchors: `f77example/Cool Temperate Maize-Soybean ON/f25top98` (whole file, per-cell rows); `f77example/Cool Temperate Maize-Soybean ON/f25si98` (site header); `ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON/runottawa_input_files/landscape/f25si98`; `ecosys-ng-prod-examples/.../landscape/f25sol98`; likely Zig readers `ecosys-ng/src/state/site.zig` and `ecosys-ng/src/state/topography.zig` (not yet read in this session) and legacy readers likely in `f77src/readi.f`/`f77src/reads.f`/`f77src/starte.f` (not yet located precisely).

Scientific/output impact: unknown/NOT_ASSESSED. If the field mapping is wrong (e.g. one topography field silently dropped, or the wrong legacy field renamed), every downstream slope/elevation-dependent process (radiation geometry, runoff, erosion, drainage) would be silently offset for this deck. This has NOT been shown to be a defect -- it may be an intentional, correct format consolidation. It is flagged because "an identical filename does not prove identical inputs" (EVIDENCE_GUIDE.md) and a topography file present in the legacy deck has no obviously corresponding file in the Zig deck.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: `Get-Content` head (15 lines) of all four files above, 2026-09-17, from `D:\ecosys_modernization`.
Input/state provenance: both decks as shipped/preserved; no edits made.
Hypothesis: `ecosys-ng`'s site-file parser (`state/site.zig`, expected) reads a superset schema that folds the legacy `f25top98` per-cell topography fields directly into the per-cell `f25si98` record, eliminating the need for a separate topography file and its per-row soil-file back-reference (soil association instead coming from the single sibling `f25sol98`). This would be a deliberate, documented format simplification, not a defect -- but it is not yet confirmed which of the four legacy topography numeric fields (elevation, slope, and two more -- aspect? drainage class?) survived, in what order, or whether any were dropped.
Stop/resource budget: this issue records the discrepancy; resolution requires reading `state/site.zig`/`state/topography.zig` field-by-field against the legacy reader (`f77src/readi.f` or equivalent) and the full multi-row `f25top98`/`f25si98` files (33 rows each, not just the head shown here) -- assign to `ecosys-state-io-bindings`.

## Experiments
1. Read file heads of legacy `f25si98`/`f25top98` and Zig-deck `f25si98`/`f25sol98`; observed the apparent field concatenation described above. Result: consolidation confirmed at the byte level; exact field-by-field mapping not yet confirmed against source. Next action: read `ecosys-ng/src/state/site.zig` parser and the legacy Fortran site/topography reader side by side against all 33 rows, not just row 1.

## Resolution
Cause and focused patch: not yet determined -- open.
Before/after results: n/a
Regression added and actually executed: n/a
Invalidated evidence and rerun dependencies: none
Independent reviewer: none yet
Remaining limitation or final disposition: UNRESOLVED, assigned to state/IO binding audit. Note for the record: the weather-file year-recycling behavior in the same control file (legacy `runottawa` reuses `gbf97h` for simulated year 2003 because no `gbf03h` exists) WAS checked and IS correctly reproduced by the Zig deck's `weather_grid_2003.txt` (also points to `gbf97h`; `gbf03h` confirmed absent from both decks by design, not a bug) -- recorded here so this specific equivalence question is not reopened without new evidence.
