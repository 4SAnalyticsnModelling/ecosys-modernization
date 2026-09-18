---
name: ecosys-process-science-parity
description: "Review physical and biogeochemical process equations against legacy ecosys and approved replacements. Use for scientific source audits across water, heat, vegetation, carbon, nutrients, gases and other implemented processes."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Audit equations in their coupled context

Partition the actual model into its implemented scientific processes. Typical review areas include soil/surface water, snow and heat, freeze-thaw, canopy radiation and energy, plant hydraulics and phenology, photosynthesis/respiration/allocation, soil organic matter and microbes, nutrient transformations/uptake, dissolved/advective/diffusive gas transport, ion chemistry and management. Include only processes actually present, but do not omit unfamiliar modules.

For each process, enumerate governing equations, empirical terms, coefficients, domains, units, signs, boundary conditions, discretization and state/flux definitions. Compare every term with legacy source and identify precisely the approved replacement boundary. Inspect temperature/moisture/stress modifiers, limiting factors, competition rules, thresholds and saturation caps. Do not substitute familiar ecological equations for the actual ecosys formulation.

## Coupling and scheduling
Draw a textual dependency map of production/consumption and execution phases. Verify process order, lagged/current states, operator splitting, shared pool competition and cell-interface exchange. Conservation cannot repair an incorrect allocation rule, and matching a local equation is insufficient when its forcing or time level is wrong. Follow the consequences into plant growth, nutrient availability and output variables.

## Edge cases and independent evidence
Test zero/small pools, absent vegetation, drought, saturation, freezing transitions, extreme permitted temperature, abrupt management events and zero forcing. Distinguish legal degenerate states from invalid inputs. Check limiting behavior, dimensions and monotonicity only where the actual governing equations warrant them. Do not impose a plausible-sounding invariant that the model does not possess.

For unchanged science, compare matched-state kernel evaluations with the reference and inspect first differences. For improved processes, read the primary formulation and prove correct integration with unchanged neighbors. Use analytical/limiting/manufactured cases when valid, and record their assumptions. Real-world accuracy claims require appropriate independent observations or benchmarks; legacy closeness alone proves neither physical improvement nor general predictive validity.

## Outputs and done
Produce equation/process dossiers, branch-boundary tests, reviewed coupling contracts and links to conservation evidence. Each material scientific difference must be either a corrected defect or an approved and validated feature, never an unexplained residual attributed to modernization.
