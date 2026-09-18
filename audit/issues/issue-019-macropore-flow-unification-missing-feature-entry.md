# Issue 019 -- macropore/matrix water-flow unification has no feature-register entry

Status: **CLOSED (fix already correct and live), documentation gap only.** Same category as `issue-011`/`issue-016`: a real, correct, well-tested legacy-defect correction that simply never got its own formal record.

Owner: found by this session's audit fork, 2026-09-18, during a `watsub.f` solver-core deep-dive.

## What was found

`f77src/watsub.f:4934-5012`'s macropore water flow is gravity-plus-hydrostatic only (`PSISH1=PSISH+0.0098*DLYR*(theta_water/theta_air-0.5)`, `:4944-4947`, no matric-potential term) -- by construction, this legacy formula cannot drive upward macropore flow against gravity, a real physical limitation of the oracle.

`ecosys-ng/src/soil/water/flux.zig:108-115` deliberately has no dedicated macropore-face kernel, with an explicit comment: "The former gravity-plus-hydrostatic `calculateMacroporeFaceFlux` kernel is deliberately absent: it omitted the matric term and made vertical macropore flow downward-only, which contradicts that policy." Both matrix and macropore faces now route through the same `calculateMatrixFaceFlux` using the full Mualem-van Genuchten total potential (the already-registered `feature-002` replacement curve). Tested at `solver_tests.zig:249` ("vertical macropore face admits upward matric-driven flow"), and corroborated by a closed internal tag `SOIL-WATER-DEAD-MACROPORE-FACE-CONDUCTANCE-001` (`solver_tests.zig:993-994`, "(removed...)") documenting that a previously-flagged dead precomputed-conductance code path in this exact area has already been cleaned up.

## Why this is filed despite being correct

Unlike its close siblings -- the Mualem-van Genuchten retention/conductivity replacement (`feature-002`) and the Dall'Amico freeze-thaw replacement (`feature-001`), both of which have dedicated feature-register entries -- this macropore-flow unification has **no feature-register entry** anywhere in `audit/features/`. Per `PROJECT_CONTRACT.md`, "every intentional difference" requires an individual feature-register entry with scope/provenance/tests/acceptance sections, not just an in-code comment and test. This issue exists to flag that gap; `audit/features/feature-018-watsub-heat-water-solver-core.md` item 5 now carries the summary, but a dedicated top-level feature entry (parallel to feature-001/002) may still be warranted if the coordinator wants this treated with the same formality as its siblings.

## Disposition

`legacy-defect-corrected`, already fixed and live -- paperwork/traceability gap only. No further code action needed.

## Evidence

`D:\ecosys-modernization\f77src\watsub.f:4934-5012`; `D:\ecosys-modernization\ecosys-ng\src\soil\water\flux.zig:60-115`; `D:\ecosys-modernization\ecosys-ng\src\soil\water\solver_tests.zig:249,993-994`.
