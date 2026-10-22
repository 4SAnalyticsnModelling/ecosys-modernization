# Priorities

1. Cycle 3 (2026-10-21): cause ESTABLISHED by instrumented replays — h4556 nitrate overdraw from
   summed FMN-floored NO3 reduction shares exceeding zone supply (+3.74e-4 relative; basis equality
   proven; nitro.f 1682-1693 / redist.f 6218-6220 unclamped legacy semantics). Fix = DEV-022 supply
    cap with 64-eps deadband + discriminating test. Verification run
    audit/runs/ottawa/zig017-verify-dev021-20261021 cleared hour 4556 (cap factor 9.996122280942202e-1;
    hours 4557-4854 clean; 202 daily conservation ledgers accepted, max N defect 1.41e-14); cycle 3
    closed 2026-10-22. Next failure boundary h4855 (1998 d203 h7) InsufficientSoilNitrite, zone_non_band
    layer 0, candidate -1.3670655422748992e-11 g vs operation_scale 3.246187603319597e-7
    (verify stderr.log:35908-35911) — cycle 4 owns it per the playbook (term-by-term legacy comparison
    before any cap). Also: adversarial revalidation of DEV-022.
2. Build a matched-state mineral-N oracle; map producer/exchange/consumer terms and floors.
   For affected implicit paths, audit fixed scales, ZERO units, both signed defects, shared
   supply, prompt zero/trace success and bounded recovery. Reconcile DEV-010 concentration-to-
   inventory conversion and runtime/F2 normalization before claiming near-zero qualification.
   Audit nonfinite/domain hazards and finite spike/reversal behavior on that path, then shared
   and dormant analogues. Require production guard tests and local per-interval admissibility;
   retain invalid legacy evidence and repair Zig causes with attributed differences.
3. Keep the active tooling suite green; address remaining Zig science-test failures and
   issue-110 follow-up branch coverage. Recheck recorded results; do not treat stale lists as facts.
4. Regenerate the complete legacy baseline with current compiler/input hashes; preserved manifest
   is partial. Complete raw-output adapters and `audit/output-provenance.csv` field by field.
   Populate mineral-N bindings during items 1–2; build the remaining dictionary/rules during
   unblocked waits. ENTRY requires `readiness.py` against the reviewed complete output inventory.
   If the actual legacy baseline contains a proved invalid value, resolve the
   [F3 reference-contract gap](../ecosys-audit/qualification-evidence.md#invalid-legacy-reference)
   before affected qualification; do not rerun unchanged comparisons or treat a DEV as a bypass.
5. Audit state bindings and process interfaces; retire unclosed/best-bounded DEV debt. Investigate
   snow, drainage, gas fluxes, frost heave and root-C discrepancies from their issue evidence.
6. Complete strict Ottawa and F1–F5: no science/translation/binding gaps and justified comparable
   complete outputs. Correctness comes before runtime optimization.
7. Then profile and optimize equivalent accepted work; revalidate F1–F5 and demonstrate full-run
   ReleaseFast faster than optimized Fortran before final release.

For each blocked item record exact condition and automatic recheck; take the next unblocked
prerequisite. Retry external outages with backoff. Never request a human scientific decision.
Scientific history: `audit/issues/` and receipts, not old
role/workflow files. Every cycle names one next experiment and records rejected hypotheses.
