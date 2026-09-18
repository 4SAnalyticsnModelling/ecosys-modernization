---
name: ecosys-release-verification
description: "Independently decide whether the audited ecosys-ng candidate meets v1.0.0 production criteria. Use only after source/test/production evidence exists; never infer readiness from compilation or one successful exit."
---


## Shared prerequisites

Locate the outer `ecosys_modernization` workspace containing all four authoritative directories. Read `ecosys-audit/PROJECT_CONTRACT.md` and `ecosys-audit/EVIDENCE_GUIDE.md` there before acting; these paths are relative to the workspace, not the skill directory. Read `ecosys-audit/SOURCES.md` when language/tool/method details need verification. Respect applicable higher-priority and existing repository instructions; surface material conflicts rather than silently replacing them.

Use current source/input hashes in evidence. Never claim a test, review, build or run that was not actually performed. Write assigned evidence under `audit/`, preserve references and user changes, and update the coordinator with a bounded next action.

# A release decision is an evidence review

Act as a reviewer separate from the change author/integrator for substantive checks. Inspect actual artifacts and source hashes, not only a coordinator summary. Use the fixed gate templates/checker for bookkeeping and manually verify the broader scientific contract. Missing, stale, skipped or unassessed evidence fails the release decision.

## Required release dossier
Verify complete legacy/Zig bidirectional traceability and dispositions, actual denominator, all state/call/output bindings, every replacement-feature dossier and all discovered unresolved issues. No hidden dormant/unmapped branch disappears from scope. Confirm any retired scope or legacy-defect correction has explicit review.

Verify focused tests, integration/edge cases, optimized-build safety/fault paths, independent conservation and solver boundedness/rollback. Inspect significant mismatches and their causal evidence. Check the final artifact is the exact compiled candidate and references the exact frozen input configuration.

Confirm the required `ecosys-ng-prod-examples` full run reached its expected final time, completed required outputs and has no unhandled errors, nonfinite accepted states or silent fallbacks producing invalid results. Recoverable bounded solver trials are not themselves fatal errors, but their acceptance and resource behavior must be documented. Exit code zero alone is insufficient.

Check **every** output file/column/key and its units/time/cumulative semantics. Review tolerance policy, missing-data treatment, raw parser tests, seasonal/cumulative drift and meaningful feature explanations. A significant unexplained difference blocks release. A justified feature departure outside the user's close-range target requires a separately agreed scope decision, not a rubber stamp.

Review fair optimized Fortran/Zig runtime comparisons, build time and peak memory; distinguish measured same-work results from algorithm changes. Check the agreed performance policy was met or report the unmet criterion without claiming completion. Verify reproducibility, restart equivalence, declared thread/platform scope and documentation.

## Decision and final action
Produce `audit/reviews/release-dossier.md` with candidate/source/input/toolchain/binary hashes, each criterion's PASS/FAIL/BLOCKED status and evidence, measured metrics, residual risks and validated scope. Run the gate checker against the reviewed release record and retain its output. The checker cannot substitute for this review or authenticate evidence.

Only mark the local candidate production-ready when all required criteria pass. Prepare version/changelog/run documentation as authorized, but do not create a Git tag, push or publish automatically. State the pack revision separately from the model version. When blocked, provide the exact cause and next minimal experiment, preserving useful completed work.
