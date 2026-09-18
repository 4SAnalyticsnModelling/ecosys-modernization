# ecosys-ng production migration contract

Skill-pack revision: 1.0.0. This is the revision of these instructions, **not** a release certification of ecosys-ng.

## Mission and authoritative paths

Work from `ecosys_modernization/`. The user's current paths are authoritative:

| Relative path | Role | Protection |
|---|---|---|
| `f77src/` | Legacy Fortran source, includes, build references | Read-only scientific reference |
| `f77example/` | Legacy run deck and reference outputs | Preserve originals; run a staged copy |
| `ecosys-ng/` | Zig implementation, tests, build definition | Permitted source-fix workspace |
| `ecosys-ng-prod-examples/` | Required Zig production run deck | Preserve inputs; run a staged copy or a verified output-isolated invocation |

Discover nested Git repositories, applicable instruction files, actual build targets and compiler versions before work. Launch harnesses from the outer root. Do not substitute an older similarly named example directory. Existing trusted research documents may inform provenance; actual checked-in implementation, reference source and the user's current requirements settle scope. Do not presume this pack has inspected the repository.

Deliver an evidence-backed v1.0.0 candidate: complete source audit; functioning production `ReleaseFast` build; full prescribed example completion; complete, scientifically justified output comparison; conservation and safety validation; measured performance and reproducibility. No statement of absolute certainty is a substitute for evidence.

## What parity means

"Bit-by-bit" means an accountable correspondence for every legacy executable statement, equation, constant, branch, state transition, coupling and output definition. It does **not** demand identical floating-point bit patterns across different solvers, precisions, evaluation orders or compiler targets. Require exact agreement for discrete identities, mappings, dates, counters, formats and deliberately identical operations where justified. Set numerical tolerances per quantity, scale, precision and test level; never use one arbitrary whole-model percentage.

Assign every audited item one disposition: `preserved`, `replaced-by-approved-feature`, `legacy-defect-corrected`, `retired-with-explicit-scope-approval`, or `unresolved`. The last disposition blocks its gate. Dormant and non-production branches remain in the inventory and audit denominator. Test coverage and source-audit coverage are separate measurements. A discovered legacy defect needs evidence and review; do not silently change the reference or reproduce undefined behavior just to match it.

## Required working order

1. **G0 / baseline:** establish immutable references, actual commands, compiler/runtime settings, source hashes, input equivalence and a complete scope inventory. Do not run the full Zig deck here.
2. **G1 / source audit:** reconcile the whole legacy scope to Zig, including every variable and output binding; validate approved replacement boundaries. Small compilations, tests, extracted routines and short diagnostic replays are allowed throughout. Do not wait for an impossible claim of 100% certainty before testing.
3. **G2 / production entry:** pass affected component, coupling, safety and conservation tests plus a bounded short integration run. Verify the current evidence matches the current source. Only now start the expensive full production build/run campaign. A targeted optimized compilation needed to diagnose an optimizer/build defect is allowed earlier when its purpose and budget are recorded; it is not permission for repeated full-deck runs.
4. **G3 / production validation:** run the required full deck in `ReleaseFast`; verify actual final time, files, rows, fields, final state, process exit and physics. Diagnose the first divergence, not only the last failed hour.
5. **G4 / performance and release:** compare every output, independently review exceptions, benchmark fair workloads, test reproducibility/restarts and prepare the release dossier. A newer patch invalidates affected evidence; final integrated checks must concern one candidate revision.

Suggested gate checkpoints are supplied as unassessed templates. The checker validates evidence structure, hashes and freshness, not scientific truth. Agents remain responsible for obeying this contract; these files are not a security sandbox or automatic CLI hook.

## Existing numerical architecture constraints

Preserve the established fixed one-hour **external** model timestep. Inspect the current Newton-Raphson primary solver and Anderson-accelerated fallback. Do not introduce vanilla Picard as an alternative fallback, silent external timestep adaptation, or an unbounded 2/4/8/16/... retry cascade. Internal iterations/substeps already belonging to an approved method must be documented and bounded, must conserve the external step, and must not change this policy silently. Do not replace an established solver architecture merely because a different method seems attractive.

Dall'Amico freeze-thaw (called "Dal Amico" in the request), Mualem-van Genuchten hydraulics, Newton/Anderson and every other intentional difference require individual entries in the feature register. The existence of a feature name does not prove its correct implementation or explain any particular discrepancy. Use the exact variant and primary references actually implemented; do not retrofit an assumed textbook variant without evidence.

Accept an advance only when the configured residual criteria, finite-state checks, physical bounds and independently calculated balances all pass. A small update or stagnation is not convergence. Trial states must be transactional: rejected trials cannot alter persistent pools, exchanged fluxes, counters, daily/cumulative totals, timestamps or output buffers. Restore the complete pre-step state on failure. Bounded failed attempts must end in a diagnostic error rather than fabricated success.

## Scientific integrity and significant differences

Maintain per-process ledgers for water, energy, carbon, nitrogen, phosphorus and every other represented element, ion/species or conserved pool, including gases and vegetation. Identify actual modeled pools from the code; do not invent missing modules. Reconcile internal transfers with equal-and-opposite bookkeeping and include all external inputs/outputs. Conservation tolerances have units and scale, cover both local and global drift, and are never loosened solely to finish a run.

Investigate differences in this order: unequal inputs/initialization; parsing or output semantics; missing/incorrect bindings and update order; translation/units/indexing/precision defects; convergence, timestep and compiler/threading behavior; **then** approved physical changes. Demonstrate attribution with matched-state kernel tests, controlled feature variants where safe, limiting cases, independent analytical/reference tests and causal tracing. Lack of a convenient legacy-physics switch does not justify either adding a second permanent engine or declaring unexplained drift acceptable.

Maintain two comparisons: (a) unchanged/compatible equations at matched states, with tight justified tolerances; (b) improved production physics, with quantity-specific scientific envelopes and invariants. A large but explained change still needs scientific acceptance and a documented scope decision if it violates the agreed close-range goal. Do not relabel a failed close-range goal as passed just because it is intentional.

## Zig engineering policy

Apply the user's principles as project requirements, not formatting slogans:

| Principle | Required behavior |
|---|---|
| Edge cases matter. | Exercise dry/saturated/frozen states, zero and tiny pools, absent vegetation, extreme forcing, empty/malformed input and allocation/I/O failure. |
| Favor reading code over writing code. | Read callers, callees and legacy equations before patching; reuse verified implementations. |
| Only one obvious way to do things. | One authoritative state representation and one production path per operation; isolate temporary diagnostic variants. |
| Runtime crashes are better than bugs. | Fail explicitly with context rather than emitting plausible wrong science; controlled nonzero exits are preferable to arbitrary crashes. |
| Compile errors are better than runtime crashes. | Encode static shape, ownership and configuration constraints where practical; validate runtime data explicitly. |
| Incremental improvements. | Small reversible changes with a reproducer, regression test and evidence. |
| Avoid local maximums. | Profile whole-model bottlenecks; do not trade global correctness or maintainability for a local microbenchmark. |
| Reduce the amount one must remember. | Explicit units, owners, time levels, defaults, contracts and centralized verified constants. |
| Focus on code rather than style. | Prioritize semantics, tests and architecture; use the pinned formatter without unrelated rewrites. |
| Resource allocation may fail; resource deallocation must succeed. | Propagate allocation failures; pair ownership with guaranteed cleanup; avoid allocation-dependent cleanup. |
| Memory is a resource. | Measure peak/live memory and per-thread workspaces, bound allocations, reuse owned scratch, avoid oversized stack frames and hidden copies. |

Use explicit model state, immutable parameters, step-local workspace and narrow process interfaces. Do not add mutable global model state. Immutable compile-time constants are appropriate. Validate input, dimensions, indexing and numerical domains before unchecked hot paths. Audit `undefined`, `unreachable`, pointer casts, aliasing, narrowing casts, wrapping arithmetic and blanket catches. For recoverable failures, prefer explicit error propagation with coordinates/time/process context. `defer`/`errdefer` and testing allocators must match the pinned Zig version.

`ReleaseFast` is not a safety proof. Keep required domain/finite/balance checks effective in production; debug-only assertions are not a substitute. Inspect floating-point mode separately from optimization mode. Preserve strict numerical semantics unless an explicitly tested change justifies otherwise. Do not globally enable fast-math or disable validation for a speed claim. Verify exact syntax against the installed/pinned Zig documentation, not an assumed latest version. See `SOURCES.md`.

## Agent collaboration and bounded work

One coordinator owns integration, gate decisions and expensive runs. Parallelize independent source reading, subsystem audits and isolated patches. Use separate worktrees of the actual Git repository, disjoint ownership and individual run/cache directories; do not assume the outer folder itself is a Git repository. No concurrent edits to shared state definitions, build files or evidence indexes without the coordinator's assignment. Independent review is a separate pass with evidence, not multiple agents agreeing on a summary.

For each issue: identify failure signature, hypothesis, minimal reproducer, bounded experiment, result and next action. Default diagnosis budget: three distinct hypothesis-driven experiments before a fresh reviewer/reframing, not three blind retries. A second identical expensive failure without new evidence blocks another equivalent run. A rerun for repeatability must be explicitly labeled. Work on other unblocked issues while a blocker is documented; do not abandon the project or pretend a blocked gate passed.

Do not discard pre-existing user changes, use destructive reset/clean, rewrite unrelated files, alter legacy reference outputs, delete evidence, weaken tolerances or suppress failing tests to manufacture green status. Do not publish, push, tag, upload source, install privileged tools or use unapproved external services as a side effect of an audit. Prepare a local release candidate; publication/tagging needs explicit authorization.

## Completion and honest status

Required evidence includes: source and build manifests; statement/equation/state/output traceability; feature register; unit and integration results; conservation ledgers; safety/fault-injection results; raw and normalized complete comparisons; first-divergence diagnoses; full production completion proof; matched performance measurements; independent review and reproducibility instructions.

Statuses are `PASS`, `FAIL`, `BLOCKED` and `NOT_ASSESSED`. Missing evidence is never a pass. "Compiles", "exit code 0", "high correlation", "looks close" and "all agents agree" are not release decisions. Report runtime/compile-time/memory targets separately. A single production example passing supports that example, not untested climates, platforms or management regimes. State the validated v1.0.0 scope and remaining limitations precisely.
