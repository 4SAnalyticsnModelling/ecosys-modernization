# Worker orientation

Run `./scripts/project.sh pickup`; live ledgers and receipts override this orientation.
Cycle 7 (issue-117) CLOSED and pushed (close commit 42f5ce1; D-8: tillage host-root litter booked into
the plant-gate sink, verified from scratch — 1999 d140 accepted, 89,712-row bit parity vs cycle-6).
Cycle 8 (issue-118) CLOSED and pushed (D-9/D-10: retainBestBoundedIterate eligibility rejections are
non-retention, not a fatal hour abort; publish/accepted-substep tiers keep hard errors; root cause =
unchecked Anderson-extrapolation base advance, verified via replay census probes).
Cycle 9 (issue-119) CLOSED and pushed (D-11: 1-ulp double-rounding overshoot total*fl(w/total) on
full root-salt removal in salt/harvest.zig state_updateRootRemoval; kill-day litter_fraction==1 makes
litter==total; residue clamped to zero with the litterfall ledger charged the realized removal;
proven by deterministic probe ladder attempt3/4/5 down to bit-exact ulp arithmetic). Verification
from scratch: 1999 d286 accepted, 115,811-row bit parity vs cycle-8 through 1999 d285, suites both
configs 4407/1/0; frontier advanced to 1999 d361 where issue-120 (HourlyLayerConservationFailure,
subnormal oxygen pool 3.4e-313, one denormal ulp, layer_scope=17) is registered — cycle 00010 target.
Then issue-115 (test-fixture OOB, file absent from module gate root); DEV-022/DEV-023 leader-owned
edge-case testing (formerly "adversarial revalidation") remains backlog. Legacy oracle blocked beyond
h2173 (recorded).
Verified strict frontier stays 0 in frontier.json (promotion only via update_frontier.py under P0
binding); record-level strict trajectory now extends to h17400 accepted / 1999 d361 failed (issue-120).
Earlier orientation (cycles 3-8 era) is superseded by cycles/cycle_0000{3..9}.md records.

Numerical edge cases: [recovery playbook](playbooks/convergence-and-balance.md) — diagnose once in the
smallest state; never loosen gates, floors or validators; ledger closure is per-day and independent.
