# Issue 022 -- Grazing demand cascade: documented "exact" helper is dead code; live path uses a different, non-equivalent allocation algorithm

Status: OPEN (needs reviewer disposition decision; not a mass-balance violation, but a real relative-split divergence)
Owner: unassigned
Candidate/input hashes: audit/manifest/candidate-001-snapshot.json sha256 79eef4efcf97dd130fa1d342d36a09cef6c0cf9053ce6f27f037d2237f770979

Failure signature and first bad time/location/process:
`f77src/grosub.f:8758-8802` implements a sequential unmet-demand cascade for grazing removal across five organs (leaf -> sheath -> husk -> ear -> grain). Line-by-line tracing shows an internal Fortran asymmetry: the leaf/sheath/husk steps update running unmet demand as `WHVXXX = WHVXXX_prev - removed` (`:8770,8774`), correctly carrying forward any leftover not consumed by that organ's proportional share, but the ear/grain steps instead compute `WHVXXX = request - removed` (`:8778` `WHVEAX-WHVEAY`, `:8782` `WHVGRX-WHVGRY`), silently dropping the untouched leftover from the prior organ's request rather than propagating the true remaining demand.

`ecosys-ng/src/canopy/photosynthesis/photosynthesis_grazing.zig:67-81` (`sourceOrderAdditionalGrazingRemoval`) is explicitly documented in its own header comment as "Exact GROSUB 8758-8783 redistribution operand for one nonfoliar organ. Source caps the additional removal by the original pool, not its remainder." -- i.e. a past audit pass correctly identified and intentionally preserved this exact legacy quirk. However, this function is **only referenced from its own test** (`canopy_photosynthesis_test_part3.zig:288`) -- grep across `ecosys-ng/src` for all call sites found no production caller.

The live production grazing-removal path is `plant_harvest_runtime_apply.zig:1172`, which calls `allocateGrazingDemand` (`photosynthesis_grazing.zig:83-166`) instead -- a structurally different algorithm: nonfoliar organs share a fixed `requested_nonfoliar` pool (proportional to pool mass) with unmet amounts additively carried forward (`request = share + unmet_incoming`; `unmet = request - removed`), plus a second corrective pass (`:136-163`) that re-offers unmet demand back to under-consumed leaf/sheath/husk/ear/grain pools. This has no Fortran counterpart in this line range and, by construction, always preserves the full remaining-demand leftover at every step -- it does **not** reproduce the ear/grain-step truncation quirk found in the legacy cascade.

Legacy/Zig source anchors: `f77src/grosub.f:8758-8802` (5-organ cascade) <-> `ecosys-ng/src/canopy/photosynthesis/photosynthesis_grazing.zig:67-81` (unused, faithful helper) and `:83-166` (`allocateGrazingDemand`, live, non-equivalent).

Scientific/output impact: total carbon removed under grazing remains bounded by `total_demand_g_c` in both implementations -- **no mass-conservation violation**. However, the **relative split of removal among husk/ear/grain organs under partial-demand grazing differs** between the two algorithms, because the live Zig path never truncates carried-forward unmet demand the way the Fortran ear/grain steps do. This is a genuine, currently undocumented science/behavior divergence in grazing-driven organ-level carbon partitioning, not merely a citation gap.

## Minimal reproducer and hypothesis
Exact command/cwd/environment: static code trace only (dispatched audit fork, 2026-09-18); no runtime reproduction executed yet.
Input/state provenance: n/a (static analysis).
Hypothesis: `allocateGrazingDemand` is the intended/approved replacement algorithm (a design improvement over the Fortran cascade's leftover-dropping quirk in ear/grain), and `sourceOrderAdditionalGrazingRemoval` is leftover scaffolding from an earlier translation pass that was superseded but never removed nor formally dispositioned.
Stop/resource budget: not yet diagnosed against this budget; this is a first-pass finding, not a diagnosis loop with failed experiments.

## Experiments
(none yet -- freshly opened; needs an explicit reviewer decision, not further mechanical experiментation)

## Resolution
Cause and focused patch: not yet decided. Two valid dispositions:
  1. `replaced-by-approved-feature` -- keep `allocateGrazingDemand` as the corrected live algorithm, retire the unused `sourceOrderAdditionalGrazingRemoval` helper (delete it and its test), and document the deliberate departure from the Fortran ear/grain leftover-dropping quirk as an approved improvement.
  2. Restore literal-cascade fidelity -- if bit-for-bit reproduction of the legacy ear/grain truncation quirk is required for this release, `allocateGrazingDemand` needs a targeted fix to stop carrying forward unmet ear/grain demand past those two steps.
Before/after results: n/a -- no patch applied yet.
Regression added and actually executed: none yet.
Invalidated evidence and rerun dependencies: none.
Independent reviewer: not yet done.
Remaining limitation or final disposition: **OPEN, needs human/reviewer design decision** (same shape as issue-015 -- this is a design-intent question, not a mechanical bug fix). Per PROJECT_CONTRACT.md, never revert `allocateGrazingDemand`'s corrective-pass improvement merely to match the legacy leftover-dropping defect without explicit scope approval.

## Traceability gap noted
No traceability row existed for `grosub.f` lines >= 8748 before this issue; see TRC-168..TRC-170 added to `audit/traceability/traceability.csv` in the same commit as this file (renumbered from an original TRC-032..TRC-034 after a numbering collision with pre-existing rows was discovered and fixed later in the session -- see the traceability CSV's own history). No prior `issue-0NN` tag existed anywhere under `ecosys-ng/src` for this grazing-cascade range.
