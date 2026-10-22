# Reviewer-policy consistency audit, 2026-10-22

No reviewer decision, approval or sign-off is required for scientific, architectural,
tolerance, DEV, cycle, release or publication decisions. The accountable leader makes
and records those decisions from evidence. Optional supporting sub-agents grant no permission.
Scientific evidence and tests remain required; their absence is work for the leader.

The complete document inventory includes tracked and newly added Markdown/RST/text files,
plus the intentionally ignored machine-local sync runbook. Each is classified as an active
document, historical dossier, retained evidence or protected reference. Raw retained artifacts
and protected references are preserved as data, never current operating instructions.
`inventory-before.json` and `inventory-after.json` record scope and findings.

The 114 historical dossiers containing retired role language now state the retirement at
the top of each file and link to the current protocol. Their original bodies are unchanged,
verified byte-for-byte through `historical-notices.json`; scientific statuses are not promoted.
The live DEV register's remaining "needs SAGE review" clause is replaced with leader-owned
evidence verification. Historical role-column headings are explicit provenance. The resolved
findings log and live CSV registers use verification-owner terminology. Five traceability
notes now assign pending disposition/materiality work to the leader, preserving every number.

Machine-readable mission metadata now explicitly names one leader, allows optional safe
helpers and disables reviewer decisions/approval. It no longer imposes a single-model count
that could conflict with optional helpers. Existing scientific acceptance gates remain intact.

`doc_consistency.py` now discovers new documents automatically, detects live reviewer gates,
requires retirement notices in historical dossiers, checks mission/release policy and scans
the live register cells. It preserves the existing resource/link, stage and skill-alias checks.
This is a static consistency check, not proof of arbitrary natural-language interpretation
or scientific correctness. It does not turn missing scientific evidence into a PASS.

Validation: 21 targeted tests passed, including rejection of new/untracked reviewer gates,
"do not continue without a reviewer" wording, reviewer gates hidden in register notes,
re-enabled machine-readable approval, missing release evidence and invalid output comparisons.
The final document/configuration check reports zero problems; skill aliases have zero drift.
No simulation or frontier promotion was performed by this documentation maintenance.
