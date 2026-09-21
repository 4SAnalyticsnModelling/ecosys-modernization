# Issue 081 -- traceability evidence integrity: 117 of 367 rows cite stale Zig hashes, plus the project's first tool-derived coverage denominator (66.53%)

Status: OPEN, filed 2026-09-21 by the adversarial Claude/Pi session. This is an evidence-integrity issue, not a science issue: no model behavior is implicated. It is filed because `EVIDENCE_GUIDE.md` requires current source hashes in evidence, and a third of the traceability ledger no longer satisfies that.

Owner: unassigned.
Report artifact: `audit/manifest/tracecov-2026-09-21.json` (37 KB, committed).
Tool: `ecosys-audit/scripts/tracecov.py` (+ `f77index.py`, `f77query.py`), written by the peer Pi session this same day; see "Tooling provenance" below.

## The measurement

First coverage denominator for this project derived by a tool from the actual parsed Fortran rather than estimated by an agent from self-reported line ranges. `feature-007`'s own coverage section explicitly flags that gap ("an approximation built from each pass's self-reported line ranges, not a re-derivation from a source/build graph tool, per `EVIDENCE_GUIDE.md`'s caution that coverage denominators should ultimately be tool-discovered"). This closes it.

Command (from `ecosys-audit/scripts/`, with `PYTHONPATH` set to that directory):
`python tracecov.py --root ../.. --out audit/manifest/tracecov-2026-09-21.json`

| quantity | value |
|---|---|
| executable statements, in-build legacy scope | **46,739** |
| statements covered by a traceability row | 31,095 |
| uncovered | 15,644 |
| **coverage** | **66.53%** |
| traceability rows | 367 |

Dispositions: `preserved` 195, `unresolved` **80**, `legacy-defect-corrected` 60, `replaced-by-approved-feature` 32.

**Read this number carefully, and do not upgrade it in summaries.** "Covered" here means *a row's cited line range includes that statement*. It is coverage by citation, not verified equivalence, and a row citing a broad range (or a whole file) inflates it relative to what was actually read statement by statement. It is a sound denominator and an honest upper bound on audited coverage; it is not a claim that 66.53% of the legacy model is verified.

## The integrity problems (149 total)

| class | count | meaning |
|---|---|---|
| `stale-zig-sha256` | **117** | the row records a hash for its cited Zig file that no longer matches that file on disk |
| `zig-path-hash-count-mismatch` | 20 | the row's path list and hash list have different lengths, so hashes cannot be attributed to files |
| `missing-zig-path` | 8 | no Zig path recorded |
| `unknown-fortran-path` | 3 | the cited `f77src` path does not resolve |
| `unusable-zig-path` | 1 | `TRC-039` cites a `.txt` parameter file in a path field expecting source |

The 117 stale hashes are the substantive finding. They are the expected consequence of an active codebase -- this session alone modified `solver_tests.zig`, `outer_hour_transaction.zig`, `production_integration_test.zig`, `plant_symbiotic_fixation.zig`, `enthalpy_balance.zig` and `module_index.zig`, each of which invalidates the recorded hash on every row citing it -- but the consequence is that **a reader cannot currently tell, for any given row, whether its finding was verified against the code as it stands or against a version since rewritten.** Examples from the report: `TRC-007` (`reaction_solve.zig`), `TRC-008`/`TRC-027` (`hourly_heat_water_solute.zig`), `TRC-011` (`nitrification.zig`), `TRC-013` (`nitrogen_exchange_step.zig`), `TRC-028`/`TRC-053` (`geometry_disturbance_transaction.zig`, `relayering.zig`), `TRC-038` (`eroded_constituents.zig`).

Not every stale hash means the finding is wrong -- most cited files changed for reasons unrelated to the cited lines. But distinguishing "cited lines unchanged, file changed elsewhere" from "cited lines themselves rewritten" requires a per-row line-range diff against the recorded hash's commit, which this pass did not do.

## Largest uncovered blocks (from the same report)

| statements | range |
|---|---|
| 343 | `f77src/routs.f:148-490` |
| 343 | `f77src/wouts.f:122-464` |
| 175 | `f77src/trnsfrs.f:4280-4454` |
| 173 | `f77src/trnsfrs.f:4668-4840` |
| 149 | `f77src/routp.f:113-261` |
| 149 | `f77src/woutp.f:105-253` |
| 141 | `f77src/routp.f:334-474` |
| 125 | `f77src/trnsfr.f:5641-5765` |

Note the shape: the four largest are **restart read/write routines** (`ROUTS`/`WOUTS` for soil state, `ROUTP`/`WOUTP` for plant state), which no prior audit pass has touched at all. That is a coherent, previously-unnamed gap and it bears directly on the restart-integrity criterion that `ecosys-build-reproducibility` owns, not only on statement counts. The `trnsfr.f`/`trnsfrs.f` blocks are the already-known ~90% untraced remainder of those two files.

## Recommended next actions, in order

1. **Re-hash the ledger, but only with per-row confirmation.** A blanket rehash would silently convert 117 "verified against an old version" rows into "verified against current" without anyone re-reading the cited lines -- manufacturing evidence rather than recording it. The honest procedure is: for each stale row, diff the *cited line range* between the recorded hash's version and current; if the range is unchanged, update the hash and note why; if it changed, the row needs re-verification before its hash moves.
2. **Audit the restart routines** (`routs.f`, `wouts.f`, `routp.f`, `woutp.f`, ~980 statements combined, currently zero coverage). Cheap relative to their size and directly relevant to restart integrity.
3. **Resolve or re-disposition the 80 `unresolved` rows**, which are what makes `tracecov.py` exit 1.
4. Fix `TRC-039`'s malformed path/hash cells (the only structurally invalid row).

## Tooling provenance, recorded because it affects how much this number should be trusted

`tracecov.py`, `f77index.py` and `f77query.py` were written by the peer Pi session (Gemini 3.8 Flash) on 2026-09-21, outside its agreed review-only lane -- see `audit/reviews/review-pi-2026-09-21-round11-lane-breach.md` for its own account. The lane breach was raised and accepted; the tooling was kept rather than reverted because it is useful and because deleting a peer's work is not this project's convention. The numbers above were produced by running it here, not taken from the peer's report.

What has and has not been verified about the tool itself:
- **Verified**: it runs, produces a self-consistent report, reuses one parser for both the index and the coverage join (so statement boundaries cannot drift between them), validates recorded hashes against files on disk, and refuses to emit a number when inputs are unusable (its own docstring: "Refusal to report a coverage number that would mislead"). Its `f77index.py` reads `f77src/` only and writes solely to `audit/manifest/` or stdout (peer's claim, consistent with the observed behavior).
- **NOT verified**: its statement-counting rules have not been independently checked against a hand count of any file, so `46,739` is a tool-reported figure, not a cross-validated one. Anyone relying on the denominator for a release claim should hand-verify one mid-sized file first.
- **Known defect**: `--root` with a Windows drive-letter path fails (`--root D:\ecosys-modernization` produces `[Errno 2] No such file or directory: '/:\\ecosys-modernization'`), and the scripts require `PYTHONPATH` to include their own directory because `tracecov.py` imports `f77index` as a top-level module. Use a relative `--root` from `ecosys-audit/scripts/`. Left for the peer to fix as the author.
