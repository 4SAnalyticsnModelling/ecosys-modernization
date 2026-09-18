---
name: ecosys-conservation-audit
description: "Build and independently verify local and global conservation budgets for ecosys-ng. Use for mass/energy drift, unexplained pool changes, coupling transfers, solver acceptance and release physics gates."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Independent conservation, not a solver self-report

Inventory the actual stored pools, tracked species and all external/internal fluxes. Construct dimensional ledgers for water, energy, carbon, nitrogen, phosphorus and every additional represented conserved quantity. Track gases and vegetation in the appropriate elemental budgets; species transformations need not conserve each individual species, but elemental totals must account for reaction stoichiometry.

For each quantity and control volume, use an independently assembled budget of the form storage change minus integrated net external input/source, with documented signs and units. Expand inputs/outputs and internal transfers explicitly. Verify interface flux cancellation with consistent orientation, area, timestep and cell support. Avoid summing internal transfers twice. Do not reuse only the solver's own residual expression as the independent check; the same omission can make both appear correct.

## Spatial and temporal scales
Check process/kernel, layer/cell, tile, whole grid/domain, hourly step, daily aggregation, annual and full-run drift. Store worst local violation and location, not just aggregate cancellation. Track absolute imbalance and scale-aware imbalance with a documented floor. Define tolerances per quantity/control volume from numerical scale and accepted accuracy; no arbitrary universal 1e-3 or 1e-11 threshold.

Audit latent/sensible heat and phase-partition definitions in freeze-thaw. Verify water mass versus volume/density conversions, latent heat conventions and any enthalpy reference. Account for drainage/runoff/evapotranspiration, gases, harvest and management or other external terms actually present. Ensure two processes do not consume the same pool independently.

## Acceptance and rejection
A state update passes only with finite states, valid physical bounds and its balance criteria. If clamping or redistribution is part of an approved method, ledger its transfer and prove it does not create/destroy conserved quantities. Never silently clip negative pools or renormalize a budget to zero. Rejected nonlinear trials must not leak fluxes into committed accumulators. Failure diagnostics name time, location, process, pools, flux terms and residual scales.

## Tests and completion
Use closed-system zero-forcing cases, isolated transport/exchange cases, known sources/sinks and reset/restart tests. Verify budget tests detect an omitted interface transfer, sign error or double integration through isolated synthetic perturbations. Produce reviewed local/global ledgers and drift summaries for the final production candidate. Apparent output similarity does not waive a conservation failure.
