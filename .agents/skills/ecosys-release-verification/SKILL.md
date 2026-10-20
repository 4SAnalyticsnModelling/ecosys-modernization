---
name: ecosys-release-verification
description: "Decide final Ottawa readiness from one integrated evidence set; use only after source/test/campaign evidence exists."
---

Authority: `.agent/protocol.md`; read it once per session. Use `./scripts/project.sh pickup`
for current state and `exec` for logged heavy commands. One model decides; no human approval.

Re-derive from raw artifacts in a separate pass of the same model; never trust only summaries.
Check F1–F7: strict 262920-hour binding, independent hourly ledgers, every output, complete
source/binding/feature inventory, DEV disposition, build/restart/performance and pushed main.
`check_gate.py` validates stage structure/hashes; it does not prove scientific correctness.
Reject missing/stale/skipped/unassessed evidence. Final time and complete inventory are separate
from exit 0. Verify synthetic validators detect truncation, corrupt restart and missing fields.
Write schema-2 finish evidence with structured F2–F6 reports and hash-bound F1–F7 checks to `.agent/finish.json`; `completion.py` must validate before
supervision stops. If anything fails, choose the next falsifiable repair and continue autonomously.

Apply [numerical recovery](../../../.agent/playbooks/convergence-and-balance.md): verify prompt
benign near-zero completion, bounded recovery, signed/cumulative closure and production finite/
domain checks. Require explicit failure before invalid state/output/checkpoint commitment.
Inspect finite spike/reversal hours and local admissibility; net balance and legacy agreement
cannot excuse physically invalid states. Retain and scientifically resolve broken oracle coverage.
For an actual invalid legacy reference, enforce the
[versioned evidence-contract prerequisite](../../../ecosys-audit/qualification-evidence.md#invalid-legacy-reference);
current F3 has no DEV-only exemption. Do not claim future schema support already exists.

For report/dependency schemas, readiness and suite accounting, use
[qualification evidence](../../../ecosys-audit/qualification-evidence.md) when recording or reusing verdicts.
