# Worker orientation

Run `./scripts/project.sh pickup`; live ledgers and receipts override this orientation.
Cycle 6 (issue-116) CLOSED and pushed (close commit ec2d159; D-7: ledger-only planting-seed booking,
verified from scratch — 1999 d138 accepted, 502-line bit parity vs cycle-5 canonical). Cycle 7 is open
(PLANNING) on issue-117: 1999 d140 tillage HourlyPlantConservationFailure. REFINED diagnosis (supersedes
the initial "missing output leg" framing): the hourly gate identity is correct; the tillage seed leg books
10% of an entry-snapshot storage/standing value while live pools receive intra-transaction updates, leaving
a booked-vs-actual gap of exactly 0.1×(D=2.328e-5)=2.0104e-6 g C at d140 (N/P same class). Probe evidence
evidence/runs/cycle7-{probe,control}-d140-20261022; the restored-state path cannot reproduce the in-memory
d140 trajectory (restart fidelity) — verification must be from-scratch like cycles 3-6.
Then issue-115 (test-fixture OOB, file absent from module gate root); DEV-022/DEV-023 leader-owned
edge-case testing (formerly "adversarial revalidation") remains backlog. Legacy oracle blocked beyond
h2173 (recorded).
Verified strict frontier stays 0 in frontier.json (promotion only via update_frontier.py under P0
binding); record-level strict trajectory now extends to h12096 accepted / h12097 failed (issue-117).
Earlier orientation (cycles 3-6 era) is superseded by cycles/cycle_0000{3,4,5,6}.md records.

Numerical edge cases: [recovery playbook](playbooks/convergence-and-balance.md) — diagnose once in the
smallest state; never loosen gates, floors or validators; ledger closure is per-day and independent.
