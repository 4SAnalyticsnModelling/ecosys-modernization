# Adversarial Round: {{ROUND_ID}}

- **Worker**: {{WORKER}} (DEEPSEEK — local Qwen3.5-35B-A3B; does all the work)
- **Judge**: {{JUDGE}} (CLAUDE — Claude Opus 5.5; escalations, final scientific review, final ruling)
- **Focus / Milestone**: Ottawa 30-year run milestone (current frontier / target subsystem)
- **Status**: {{STATUS}} (PLANNING / IN_PROGRESS / ESCALATED / AWAITING_RULING / RULED)

---

## 0. Plan (DEEPSEEK)
- **Source of target** (CLAUDE's last next target / state.md frontier / execution plan):
- **Target** (one bounded, falsifiable question):
- **Hypotheses**:
- **Legacy ranges to read** (`f77src/<file>.f:<lines>`):
- **Done condition**:

## 1. Work Report (DEEPSEEK)
- **Subsystem & Problem**:
- **Legacy Fortran Ground Truth** (`f77src/<file>.f:<lines>`):
- **Zig Change** (`ecosys-ng/src/<file>.zig:<lines>`):
- **Pokes acknowledged** (`Poke K acknowledged: ...`; none if no poke):

## 2. Evidence & Self-Check (DEEPSEEK)
- **Files Modified**:
- **Test Commands**:
- **Receipts & Key Numbers** (`audit/runs/.../receipt.json`):
- **Self-check**: regressions pass / conservation (water, heat, C, N, P) closes / no tolerance or clamp change / traced to legacy lines / output comparison:
- **Ledgers updated** (state.md, unresolved-gaps, provenance, invariants):
- **Not run / failed**:

## 3. Escalation & Guidance (only when needed)
- **DEEPSEEK escalation** (deep diagnosis / cross-language / architecture / DEV; or one objection to a ruling):
- **CLAUDE guidance**:

## 4. Final Scientific Review & Ruling (CLAUDE — final)
- **Pokes sent this round** (`.agent/pokes/poke_{{ROUND_ID}}_K.md`; none / list):
- **Scientific review** (physics vs legacy, conservation, tolerance softening, traceability):
- **Decisions** (architecture / DEV-NNN / legacy-inconsistency; none if not applicable):
- **Final Ruling (CLAUDE)**: <!-- APPROVED | REVISE | REJECTED -->
- **Reasons**:
- **Required revisions / revert instructions**:
- **Next target / guidance**:
