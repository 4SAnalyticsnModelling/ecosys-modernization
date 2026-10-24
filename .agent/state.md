# Worker orientation

Run `./scripts/project.sh pickup`; live ledgers and receipts override this orientation.
Cycle 7 (issue-117) CLOSED and pushed (close commit 42f5ce1; D-8: tillage host-root litter booked into
the plant-gate sink, verified from scratch — 1999 d140 accepted, 89,712-row bit parity vs cycle-6).
Cycle 8 (issue-118) CLOSED and pushed (D-9/D-10: retainBestBoundedIterate eligibility rejections are
non-retention, not a fatal hour abort; publish/accepted-substep tiers keep hard errors; root cause =
unchecked Anderson-extrapolation base advance, verified via replay census probes). Verification from
scratch: 1999 d193 h2 accepted (zero conservation failures), 99,187-row bit parity vs cycle-7 through
1999 d192; frontier advanced to 1999 d286 where issue-119 (InvalidPlantInventory,
validation/landscape_mass_inventory_plant.zig:147/157) is registered — cycle 00009 target.
Then issue-115 (test-fixture OOB, file absent from module gate root); DEV-022/DEV-023 leader-owned
edge-case testing (formerly "adversarial revalidation") remains backlog. Legacy oracle blocked beyond
h2173 (recorded).
Verified strict frontier stays 0 in frontier.json (promotion only via update_frontier.py under P0
binding); record-level strict trajectory now extends to h15600 accepted / 1999 d286 failed (issue-119).
Earlier orientation (cycles 3-7 era) is superseded by cycles/cycle_0000{3..8}.md records.

Numerical edge cases: [recovery playbook](playbooks/convergence-and-balance.md) — diagnose once in the
smallest state; never loosen gates, floors or validators; ledger closure is per-day and independent.
