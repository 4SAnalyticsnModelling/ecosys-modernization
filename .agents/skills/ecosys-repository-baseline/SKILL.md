---
name: ecosys-repository-baseline
description: "Establish immutable legacy references, equivalent decks, actual toolchains and commands before auditing or benchmarking ecosys-ng. Use when starting, restoring a baseline, or discovering source/input drift."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Establish the reference experiment

## Inspect without running the full Zig deck
Resolve the four authoritative directories. Read applicable root/nested instructions, build files, include paths, scripts and existing manifests. Identify the Git root of each code tree, dirty files and untracked user work. Record compiler versions and pinned dependencies. Do not upgrade Zig, change Fortran flags or initialize a new repository as a convenience.

Inventory all legacy compilation units, include/COMMON/BLOCK DATA definitions, generated sources, entry points, alternative branches and link inputs. Inventory all Zig production modules, tests, build paths and generated bindings. The provided snapshot helper hashes files; it does not discover call graphs or guarantee executable coverage.

## Freeze and verify
Create a read-only-reference policy and hash legacy sources, original decks and existing reference outputs. Use staged run directories for new outputs. Record symlink targets, external forcing files and any data outside the four roots explicitly; the helper refuses unresolved symlinks instead of silently ignoring them. Excluded generated/cache directories are listed in the snapshot. Verify no scientific source was placed in an excluded directory.

Compare both run configurations: site/grid/layer geometry, dates, spinup, initial pools, weather, atmospheric drivers, management, vegetation, soils, irrigation, output intervals, units, calendars and seeds. Identify defaults introduced by either reader. An identical filename does not prove identical inputs. Record every meaningful difference before numerical comparisons.

Read the proven legacy command and its compiler behavior. Check fixed-form line width, continuations, implicit types, floating-point precision, local persistence/static storage, COMMON layout, link order and any compatibility flags. Preserve the historical build as an oracle, and use a separately named diagnostic build when needed. Record warnings; do not silently suppress them. If legacy behavior depends on uninitialized state, expose and document that uncertainty rather than trusting unstable golden values.

## Commands and staged execution
Register exact working directories, command argument arrays, environment requirements, executable paths, expected outputs and completion conditions. Discover build help and scripts before assuming `zig build` targets or runtime flags. One baseline Fortran run may be appropriate to regenerate verified reference evidence; preserve prior results and label its provenance. Do not count a stale prebuilt executable as a source-verified baseline.

## Outputs and done
Produce scope inventory, source/input manifests, command registry, compiler/flag record, configuration-equivalence report and output inventory. Gate G0 passes only when the reference is reproducible and all unresolved baseline differences are identified and either resolved or explicitly block the dependent comparison.
