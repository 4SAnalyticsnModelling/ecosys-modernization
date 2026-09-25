# Ottawa execution-plan review — R2

Planning review only. D1–D8 remain fixed; no commands, builds, or tests were run.

## R1 resolution check

1. **RESOLVED — P2.4/P3:** validates statement attribution, audits mapped pathways semantically, includes bindings/coupling and replacements, and requires reviewed dispositions.
2. **PARTIAL — P5.3–5:** strict hour-zero campaigns prevent stale replay from promoting the frontier, but extended replay before the next campaign remains absent; checkpoint eligibility also contradicts post-fix replay (N1).
3. **PARTIAL — P4/P5/§5:** readiness now precedes full Zig runs and campaigns have caps, but elapsed-time and survey-count caps are missing; five locally tested fixes still trigger a full campaign without extended validation.
4. **RESOLVED — P0.1–4:** discovers Git state and adjudicates D6 before collecting accepted reference evidence.
5. **PARTIAL — P2.1/8:** composite keys, bundle comparison, boundaries, and negative tests are added; completeness is still assumed from existing bundle sections rather than checked against all material live state, and isolated output-tree resume handling is unspecified.
6. **RESOLVED — P2.5–7/P7:** adds complete raw adapters, horizon/key validation, independent balances including salts, positive controls, and scientific comparison rules.
7. **PARTIAL — P0.4/P6/P7:** three timings per side and final candidate freeze resolve the main defects; warmup/cache policy remains unstated, and serializing only full runs permits competing builds/profiles unless the quiet-machine rule is enforced across all jobs.
8. **RESOLVED — P1.5–6/§2:** migration inventory, adversarial wrapper tests, review invalidation, and targeted SAGE evidence access are explicit.
9. **PARTIAL — §0/P0.5/§3:** tracecov behavior and gate CLI are corrected; unsupported commit/frontier statistics and the claimed complete legacy artifact remain presented as facts rather than provisional baseline checks.
10. **RESOLVED — §2/§6/§7:** adds role budgets, cost reporting, storage admission checks, and evidence-preserving retention; no further minor points raised.

## New BLOCKER / MAJOR findings

### N1 — BLOCKER: Post-fix replay is prohibited by its own binding rule
**Section:** §4 preamble; P5.3.

Every source change changes the binding, but P5.3 forbids checkpoints from other bindings. Thus FORGE cannot perform the required post-fix diagnostic replay using the preceding campaign’s checkpoint, and cannot start another campaign until that replay passes.

**Fix:** allow explicitly approved cross-revision *diagnostic* replay with checkpoint-parent and patched-candidate hashes, schema compatibility, and provisional status. Keep strict same-candidate evidence mandatory for promotion.

### N2 — MAJOR: New performance gate can reject a D4-compliant candidate
**Section:** P6 exit GP.

An extrapolated one-year result beating legacy by 15% is now mandatory before P7. Seasonal and late-run costs need not scale uniformly; a candidate satisfying the fixed full-horizon median target can fail this proxy.

**Fix:** make the extrapolation advisory for scheduling the benchmark, not an additional acceptance threshold; let the full-horizon D4 measurement decide.

### N3 — MAJOR: Required initialization evidence cannot be produced
**Section:** P2.1–2; P4.

The oracle specifies only end-of-hour dumps, while G2 requires a divcheck at hour zero. No shared pre-step initialization snapshot is specified.

**Fix:** add a keyed initialization dump on both sides after equivalent initialization and before the first advance, with its comparison included in GP2 self-tests.

REVISE
