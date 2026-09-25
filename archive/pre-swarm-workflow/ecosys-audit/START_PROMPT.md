Read `ecosys-audit/PROJECT_CONTRACT.md` and activate `ecosys-release-orchestrator`.

Work in my `ecosys_modernization` workspace. Treat `f77src` and `f77example` as preserved references, audit `ecosys-ng`, and use the prescribed `ecosys-ng-prod-examples` deck for final production validation. Discover actual commands, compiler versions and existing work before changing anything.

Audit the whole codebase equation by equation and binding by binding, except for individually documented and validated intentional improvements. Run focused tests while auditing. Do not enter repetitive full ReleaseFast build/run loops before the source-audit and production-entry gates pass. Any significant output difference must first be investigated for input, translation, binding, indexing, units, timing or convergence defects; an improvement label alone is not an explanation.

Use available independent agents for disjoint work and separate review, with one integration coordinator and bounded diagnosis attempts. Preserve the established fixed hourly step and approved Newton/Anderson architecture. Follow all project Zig safety, ownership, memory, maintainability and reproducibility rules.

Proceed autonomously on unblocked work within this scope. Use `ecosys-audit/WORKFLOW.md`:
resume from the small current `audit/handoff.md`, register one bounded task, retain raw logs
on disk, and exchange candidate-bound review artifacts rather than terminal transcripts.
Inside Herdr the lead runs `uv run ecosys-audit/scripts/herdr_cycle.py ensure` once and
yields, or, when it cannot idle (a `/goal` stop hook), uses lead-driven `herdr_cycle.py peer` /
`next` per WORKFLOW.md; the controller owns peer dispatch and automatic conversation rotation after
checkpointed task closure. Do not launch a second loop or repeat project-wide checks for
each patch. Resume from evidence instead of restarting. Finish with an independently reviewed local v1.0.0 candidate only when the prescribed full ReleaseFast run, every-output comparison, conservation, safety, reproducibility and agreed performance criteria pass for the same candidate. Otherwise preserve completed work and report precise blockers without claiming readiness. Do not tag, publish, push, weaken tests/tolerances or alter legacy references.
