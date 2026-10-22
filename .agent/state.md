# Worker orientation

Run `./scripts/project.sh pickup`; live ledgers and receipts override this orientation.
Cycle 6 (issue-116) in verification: planting seed C/N/P injected after the initial condition is now booked
as cumulative external boundary input (Fluxes.planting_* + accumulateAcceptedPlanting + identity terms;
driver reseed site books exactly the preflight-admitted mass; landscape ledger checkpoint v19->v20 with
explicit legacy rejection). Ledger-only fix — 1998 daily ledgers d1..139 bit-identical to the cycle-5
canonical run. Candidate ReleaseSafe 52aba77c...; suites Debug+ReleaseSafe EXITED 0 (standalone 4404/1skip/0fail);
canonical from-scratch verification running (audit/runs/ottawa/cycle6-verify-scratch-candidate-20261022101316;
acceptance = 1999 d138 ledger accepted, run advances past h12073). macOS linker embeds random LC_UUID —
binary-hash reproducibility replaced by source-pinned identity + output-level equivalence (cycle6 digest).
Then issue-115 (test-fixture OOB, file absent from module gate root); DEV-022/DEV-023 adversarial
revalidation remains backlog. Legacy oracle blocked beyond h2173 (recorded).
Verified strict frontier stays 0 in frontier.json (promotion only via update_frontier.py under P0
binding); record-level strict trajectory now extends to h12072 accepted / h12073 failed (pre-fix).
Earlier orientation (cycles 3-5 era) is superseded by cycles/cycle_0000{3,4,5,6}.md records.

Numerical edge cases: [recovery playbook](playbooks/convergence-and-balance.md) — diagnose once in the
smallest state; never loosen gates, floors or validators; ledger closure is per-day and independent.
