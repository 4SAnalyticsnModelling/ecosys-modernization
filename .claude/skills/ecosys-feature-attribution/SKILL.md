---
name: ecosys-feature-attribution
description: "Validate intentional numerical/physical changes and causally attribute output differences. Use for Newton/Anderson, Dall’Amico freeze-thaw, Mualem-van Genuchten, or any claim that drift is an improvement rather than a translation defect."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# Separate an approved method from an unexplained discrepancy

Create one dossier per intentional feature. Record feature ID/status, legacy equations/interfaces, new equations and variant, exact source locations/hashes, primary references, purpose, affected variables/processes, unchanged contracts, expected direction/regime of effects, validation cases, numerical accuracy and performance tradeoffs. A feature listed by the user is in scope to preserve and audit, not automatically proven correct.

## Proof obligations
Prove unchanged inputs, interfaces, units, boundary conditions and output semantics across the replacement boundary. Demonstrate the new implementation follows its stated equations and supports admissible edge cases. Validate its Jacobian/derivatives or iterative formulation where used. Check independently calculated mass/energy budgets and coupling to neighboring unchanged processes.

A solver change is normally a numerical-method change; a constitutive relation may be a physical-model change. Separate them so truncation/iteration error is not confused with changed science. Precision, scheduling, compiler math mode and threading are separate changes too.

## Controlled attribution
Start from a reproducing discrepancy with matched inputs. Trace its earliest changed process state. Where supported safely, compare one feature at a time with matched configurations; do not turn an unsafe legacy toggle into production architecture. Alternatively use isolated legacy-versus-new kernels, captured common states, limiting cases, trusted reference solutions or test-only adapters. Record why an unavailable control limits the attribution.

Test both local causes and downstream effects. For interacting features, document interactions rather than assuming effects add independently. Show that the discrepancy occurs in regimes the change should affect and that unaffected interfaces remain within their strict checks. A narrative such as "Newton is more accurate" or "freeze-thaw improved" is insufficient.

## Acceptance
Define a quantity-specific improved-physics envelope before using results as acceptance evidence. Keep the tight unchanged-equation tests separate. If a significant departure remains beyond the agreed close-range goal, leave that output/release criterion failed or blocked until scientific review approves a justified scope change. Do not widen tolerance solely to enclose observed differences; rerun independent or held-out cases after any legitimate policy revision.

## Done
An independent reviewer can follow primary formulation -> implementation -> controlled experiment -> affected outputs -> accepted bounds. Unknown mechanism, untested replacement boundary or missing causal evidence leaves the feature/discrepancy unapproved.
