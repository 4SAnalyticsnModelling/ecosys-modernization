# Single-leader workflow, 2026-10-22

One accountable leader now owns decisions, evidence verification, cycle/frontier/gate state
and publication. Safe, scoped supporting sub-agents or swarms are optional. Shared mutations
and run ownership stay coordinated by the leader; helper availability and sign-off are never
prerequisites. The leader takes over unavailable work or pursues another unblocked task.
There are no adversarial reviewer roles, reviewer approval queues or mandatory fresh contexts.

Updated the root instructions/prompt/readme, protocol, execution plan, continuous autonomy,
control-plane orientation, verification brief, cycle template and worker configuration;
the audit contract/evidence guide; all 17 canonical skills and their 17 Claude copies plus
discovery index. Backlog/current handoff/cycle next-actions and the DEV register describe
leader-owned edge-case revalidation. Revalidation remains a scientific evidence obligation.

RELEASE now requires `leader-release-verification` instead of `independent-release-review`.
All other checks remain. A single leader's `author` and `separate-derivation` records can
satisfy the full release-stage inventory. The normalized CSV comparator now accepts
`decision_owner`; historical `approved_by` remains a compatible decision-owner alias.
New templates use decision/verification-owner terminology. Blank decision ownership,
unjustified tolerances and invalid comparisons still fail. No numerical tolerance was changed.

Historical raw receipts and audit reports retain original observations and actor labels.
The protocol, root instructions and `audit/README.md` explicitly supersede their role and
approval instructions; they cannot revive a reviewer gate. Historical PASS/CONFIRMED labels
still establish no current scientific acceptance. DEV dispositions/numbers are not promoted
by replacing old actor/pending-review labels with leader-owned verification work.

Validation: `tests-fixed-import` records 101 passed with zero failed/skipped, including a
complete real RELEASE gate authored by one leader, rejection of missing/tampered evidence,
new and historical comparison-policy owner fields, output mismatch and NaN rejection, and
existing qualification/recovery regressions. `skills` records 34 valid skills using the
skill-creator validator; `skill_sync.py` reports zero drift. The first `tests` attempt retains
an import-order collection failure, fixed before the successful run. No science simulation,
threshold, frontier promotion or release qualification is claimed by this maintenance.

The existing HerdR pane's current DSH session receives the current policy and recovered
cycle-7 handoff after publication; `../notes-size-recovery-20261022/resume.json` records the
actual continuation evidence. The old session remains preserved and must not be launched
as a duplicate leader while that current worker owns the mission.
