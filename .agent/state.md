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
Cycle 10 (issue-120) CLOSED and pushed (D-13: writer = surface microbial oxygen batch on the litter
gas slot — scope 17 decoded as kind=SURFACE; soil/gas/oxygen_allocation.zig solveLayer returned
SUM_i round(shared*frac_i), a one-subnormal-ulp unbooked drift on denormal pools; trace-window
(<= floatMin) identity early-return keeps shared pools bit-exact; producer pinned via 45-s
restart-resume lane + TEMPDIAG120B/L/M/W brackets, discriminating test fails at HEAD).
Verification from scratch: cleared h17401 through h18938, 34-file/129,112-row bit parity vs cycle-9
through 1999 d360 h24; new distinct defect at 2000 d60 h3 registered as issue-121 (cycle 00011).
Then issue-115 (test-fixture OOB, file absent from module gate root); bounded-cap follow-ups leader-owned
edge-case testing (formerly "adversarial revalidation") remains backlog. Legacy oracle blocked beyond
h2173 (recorded).
Cycle 11 (issues 121-129) CLOSED: from-scratch v18 authority campaign (binary d429893e, source 8af954d)
passed the target hour 18939 (2000 d60 h3, issue-121 carbon) and every falsifier hour of issues 122-125
with ZERO hourly/accumulated conservation failures across 1225 days, terminating only at wh 29422 with
issue-130 (SoluteConcentrationExceedsWaterMolarity, 2001 d130 h22, next cycle). Fixes: D-26 producing-chain
ledger restore at bounded publications; D-27 carbon completion-residual provenance lane + census floor;
D-28 mineral texture census floors; D-30 topsoil vapor pore guard = exact producer tolerance (issue-129,
authority-received at v17 wh 17115). Frontier advanced past h18939 to h29421 accepted / h29422 failed
(issue-130); v129c lane proves the fixed engine clean to 29422 h; issue-130 forensics banked (lane v130a
P130 series: chronic non-band nitrate ~0.5-1.0 M, NOT desiccation; resume state .tmp/cycle121/deck-29184-snapshot).
Cycle 12 (issue-130) CLOSED: D-31 replaced the port-only molarity guard's the 2026-09-30 zone-presence fraction proxy with the legacy ZEROS2 zone-water predicate (zone water = fraction x
carrier VOLW <= 1e-6 x DH x DV -> legacy sets CNO1/CNOB = 0.0 there, solute.f:533/539,
starts.f:94/:270; no molarity bound exists anywhere in f77src). v19 from-scratch
authority (binary e522a1f6, source ec59c0a, __text 58e2c7a769ecf4308e75) passed the
trip hour 29422 - terminal for every pre-fix run (v129c, v18, scratch probe lane
2b1b563) - with ZERO solute/science/conservation failures and continued to 2001 d363
(day 1463, planned stop). Earlier milestones day 713 (17115, D-30) and day 789
(18939, cycle-11 target) clean on the same binary; boot + ladder-count bit parity vs
v18 prove no delta before the sliver regime. NO gate/tolerance/physics value moved.
Verified strict frontier stays 0 in frontier.json (promotion only via update_frontier.py under P0
binding); record-level strict trajectory now extends to h18938 accepted / 2000 d60 h3 failed (issue-121).
Earlier orientation (cycles 3-9 era) is superseded by cycles/cycle_0000{3..10}.md records.

Numerical edge cases: [recovery playbook](playbooks/convergence-and-balance.md) — diagnose once in the
smallest state; never loosen gates, floors or validators; ledger closure is per-day and independent.
