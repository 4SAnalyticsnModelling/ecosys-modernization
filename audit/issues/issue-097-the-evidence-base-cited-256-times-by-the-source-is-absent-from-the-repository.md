# Issue 097 -- the evidence base the source cites 256 times is absent from the repository under audit, and this session rediscovered documented findings because of it

Status: **OPEN, CONFIRMED, PROCESS BLOCKER. Highest-priority systemic finding of round 26 (filed 2026-09-22, adversarial Claude/Pi session). Recommendation stated; the bulk import deliberately NOT performed -- see "Why I did not just copy it".**

This is not a science defect. It is the reason a large part of this session was wasted, and it would waste any reviewer's time identically.

## The finding

`ecosys-ng/src` contains **256 citations to `docs/` paths, across 67 distinct documents, in 168 source files**. Examples, by citation count:

| citations | path |
|---|---|
| 32 | `docs/discrepancy_register.md` |
| 25 | `docs/model_changes.md` |
| 16 | `docs/traceability/redistribution_tillage_unbound_family_disposition.md` |
| 16 | `docs/traceability/a8a_index_dispositions.md` |
| 13 | `docs/traceability/erosion_unbound_family_disposition.md` |
| 12 | `docs/validation.md` |
| 9 | `docs/agent_workflow.md` |

**There is no `docs/` directory anywhere in this repository.** It was never tracked -- `git log --all -- 'ecosys-ng/docs/*'` returns zero commits -- and it is not gitignored.

The tree **does** exist, with **615 files**, in the read-only reference location the user authorized for this project (`.../OneDrive - Government of Alberta/ProjectsSymon/ecosys_modernization/ecosys-ng/docs`).

So the evidence was written. It simply is not in the repository being audited.

## Why this is a first-order problem, not housekeeping

The missing documents are exactly the artifacts `PROJECT_CONTRACT.md` depends on:

- **`docs/discrepancy_register.md`** (49,801 lines) is the register of every measured legacy-versus-modern difference and its disposition.
- **`docs/model_changes.md`** is what source comments cite as the authority for each `replaced-by-approved-feature` decision.
- **`docs/traceability/*_disposition.md`** are the per-family disposition records.

A `replaced-by-approved-feature` disposition whose justification is a dangling path is not a disposition. Any reviewer of this repository -- human or agent -- can read the code's claim that a deviation was approved and **cannot check it**. Criterion 2 ("no science gap") is unevidenceable from the repository alone, and G1's feature-boundary review and G4's release dossier both rest on documents that are not here.

## The cost, measured on this session

This is the concrete harm, and it is the reason the issue is filed at this priority. Round 26 produced findings that are, in the reference documentation, already recorded -- in two cases with a **deeper and more accurate** diagnosis than mine:

| my finding | actual status in the reference docs |
|---|---|
| `issue-096`: the `IFLGD` discharge gate compares a value against itself, breaking micropore tile drainage | **The DEFECT was already documented**, `production_status_2026-09-10.md:307`: "layer 10 sits at saturation so its two matric potentials are equal, which breaks the `IFLGD` chain (`solver_residual.zig:432,458-471` = `watsub.f:5352-5378`) and makes micropore tile drainage identically zero", traced upstream to initial over-saturation (271.9 mm, split at `DTBLZ = 1.0 m`). **But that cause is ALREADY FIXED** in the audited tree (`model_initialization.zig:230-231`'s `ISOIL` guard, present since `514dd68` on 2026-09-18, i.e. before `run019` was built) **and the symptom persists undiminished**. So the prior causal chain is incomplete and `issue-096`'s saturation-independent mechanism is a **genuine new contribution** -- see its second correction. |
| `issue-096`: retiring the HCND table left a dangling dependency the feature-boundary review should have caught | **WRONG ACCUSATION.** `legacy_conductivity_class_table_removal_and_air_fraction_threshold_reconciliation.md:44-61` enumerates all three former consumers of the air-entry pair and states "the air-entry fields are dead by **three independent intentional replacements**, not by oversight." The review did catch them. |
| `issue-095`: `SOL_RADN` differs on 1,447 of 3,275 hours, "systematic, not noise", undiagnosed | **EXPLAINED AND BENIGN.** `discrepancy_register.md:8707` records `SOL_RADN` at 2.4e-7 relative as agreeing "to the writer's **seven-digit floor**" -- it is the `E16.7E3` output format's precision, not a physical difference. My concern should be withdrawn. |
| `issue-095`: no output slot publishes the legacy-comparable precipitation quantity | **WRONG.** `discrepancy_register.md:40163-40165`: daily-heat `PRECN` (`= TRAI`, daily reset, `day.f:74`) matches modern `total_precipitation` to **rel 3.35e-16**, and the register concludes "the precipitation science is exact and the divergence was 100% output semantics." A comparable column exists and agrees to machine precision. |
| `issue-095`: the hourly `PREC` deficit | **ALREADY REGISTERED**, and characterised more sharply: `discrepancy_register.md:8699-8712` gives earliest divergence 1998 day 1 hour 16 and the isolating evidence that the column "agrees **exactly** on all 16 dry hours and fails on all 8 wet hours, **always with modern at zero**", classified as a weather-ingestion or hour-alignment defect. My "omits snowfall" hypothesis does not fit "modern at zero on wet hours" and is probably wrong. |
| `issue-092`: daily flux columns are annual-cumulative | **ALREADY REGISTERED WITH A FIX**, `discrepancy_register.md:40158-40176`: `Conversion` gained an `accumulation` field, windows not starting at the reset are refused (`AccumulationWindowNotFromYearStart`), measured `PRECN` max relative 0.99999 -> 0.029642. My `--cumulate-candidate` reimplements this, including the same reset-window precondition. |
| `issue-093`: `RC0` per-pool composition (pool 4 receives `OSC` only) | **appears GENUINELY NEW** -- `RC0` returns **0 hits** in the 49,801-line register, and `DLYR(3,0)` likewise. |

So of round 26's substantive findings, **two are new** (`issue-093`'s `RC0` composition, and `issue-096`'s saturation-independent gate mechanism -- the latter only established as new *because* checking the reference docs showed its documented cause had already been fixed while the symptom remained), one was a wrong accusation, two were already registered with better characterisations, and one was already fixed. I also built a tool feature (`--cumulate-candidate`) that duplicates an existing, better-guarded implementation.

**Note the asymmetry this illustrates.** Reading the reference documentation cost one session-hour and it both *demolished* three of my claims and *promoted* a fourth from "rediscovery" to "the remaining cause after the known fix". Without it I would have filed four overstated findings and understated the one that matters. That is the argument for recommendation 2 below, more than the wasted effort is.

**None of that was avoidable from inside this repository.** The information needed to avoid it was cited 256 times by the very files I was reading and was not present.

## What survives from round 26 as a genuine contribution

Stated narrowly, because the above requires it:

1. **`issue-093`'s `RC0` per-pool composition mismatch** -- no register hit; the only apparently novel defect.
2. **An independent, oracle-anchored measurement of the `IFLGD` consequence.** The prior work diagnosed the mechanism from initialization; `issue-094` measures it from the outputs: artificial drainage **3.91 mm against 213.51 mm** and storage **+411.58 mm against +225.37 mm** over 136 shared days. Different direction of attack, same defect.
3. **Independent corroboration of the `DTBLZ = 1.0 m` split.** The prior work says "layers 10/11/12 are at porosity from hour 1"; I measured, without knowing that, a `WTR_k` bias that attenuates with depth and **vanishes exactly there** -- `WTR_10` +0.016, **`WTR_11` -0.0003**. Two independent observations agreeing on the same 1 m boundary is worth more than either alone.
4. **The reduction of `run-014`'s five surface readouts to one cause**, with the melt-locked step structure in `SURF_ELEV` as the discriminating evidence.
5. `outcompare.py --trace`, and the `read_lines()` MAX_PATH fix (the scratchpad paths are 284 characters, which CPython `open()` cannot resolve).

## Why I did not just copy the 615 files in

Deliberate. Importing 615 unreviewed documents into a git-synced repository is not trivially reversible -- it enters history -- and it would change the audit's provenance in a way that is the user's call, not mine. The user's grant was **read-only access to the reference location for experience**, which does not obviously extend to bulk-importing it as this repository's evidence base. I also have not reviewed the contents for anything that should not be committed.

## Recommendation

1. **Bring `docs/` into the repository** (or make it a submodule/linked artifact with a recorded commit), so that every one of the 256 citations resolves. Until then no reviewer can verify any disposition and `PROJECT_CONTRACT.md`'s disposition classes are unusable in practice.
2. **Until it is imported, treat the reference `docs/` as required reading before any new source finding is filed.** Concretely, `discrepancy_register.md` (49,801 lines) and `production_status_2026-09-10.md` should be searched for the relevant legacy symbol *first*. Round 26 is the evidence for this: a single `grep RC0`-style check against the register would have correctly separated my one new finding from the four that were not.
3. **Reconcile the open items the prior work flagged.** `production_status_2026-09-10.md:301-305` states that register entries `HOUR1-006`, `SOIL-INITSAT-001` and `EXEC-INITSAT-EXTENT-001` "must be **reopened as 'the fix was wrong, not missing'**" -- that reopening is the actual next action on the drainage cluster, and it is upstream of everything `issue-094` and `issue-096` describe.

## Reproduction

```
# in D:\ecosys-modernization
Test-Path ecosys-ng/docs                      # False
git log --all --oneline -- 'ecosys-ng/docs/*' # zero commits
Select-String -Path ecosys-ng/src/**/*.zig -Pattern 'docs/[A-Za-z0-9_./-]+' -AllMatches
# 256 matches, 67 distinct paths, 168 files
```

**Limitations.** The 256/67/168 counts come from a glob four levels deep under `ecosys-ng/src`; deeper paths are not counted, so these are **lower bounds**. The 615-file count is of the reference tree as it stands today and I have not verified it is complete, current, or consistent with this repository's source. The "appears genuinely new" claim for `issue-093` rests on `RC0` and `DLYR(3,0)` returning zero register hits, which is a keyword search, not proof of novelty -- the register may describe the same defect in other terms.
