# issue-120 fix draft (leader, 2026-10-25) — NOT YET APPLIED, pending probe receipt

## Mechanism (static convergence, UNVERIFIED until TEMPDIAG120P/T receipt)
`oxygen_allocation.solveLayer` splits the layer O2 pool across microbial populations:
per-population solver inputs `shared.gaseous*frac_i`, `shared.aqueous*frac_i`,
`flux*frac_i` (each rounded); the writeback is `final = SUM_i result_i`.
When the layer total is subnormal (<= 2.2e-308 g), every per-population `oxygen_solver.solve`
takes its trace guard (`:88-92`, "Preserve that finite trace exactly") and returns its inputs
verbatim, so the committed pool = `SUM_i round(x*frac_i)` != x on the 5e-324 denormal grid
(python-verified: 3-way split of 3.395e-313 drifts exactly -1 ulp). Flux is folded via
`gas_before = allocated + flux` (another rounded add). Ledger books only per-population uptake
(0 on the trace path) => hourly layer check sees pool change with ALL FOUR ledgers 0e0; the
relative tolerance `3.4e-313 * 1e-12` underflows to 0 => effective_limit 0e0 => fatal.

## Fix (bounded, legacy-parity, gate-untouched)
In `solveLayer` ONLY, add a trace-window branch guarded by
`(g + gflux) + (a + aflux) <= std.math.floatMin(f64)` — the exact magnitude class the solver
already declares "must be preserved exactly":
- fold flux into phase totals `gt = g + gflux`, `at = a + aflux` (left-to-right, once);
- sequential remainder split over ACTIVE populations (fraction != 0, same loop order):
  `share = min(round(gt*frac_i), rem_g)` for every population except the last active, which
  takes `rem_g` exactly (and symmetric for `at`);
- solver inputs become `allocated_gaseous = share_g_i, allocated_gaseous_flux = 0` (the solver
  folds `gas_before = share + 0` bit-exactly; flux was already zero-valued in trace hours).
Total is exactly preserved by construction (telescoping remainder), uptake stays 0 on the trace
path, per-population allocation_fraction/demand/iterations arrays unchanged. Non-trace hours are
bit-identical (branch never taken) => parity through 1999 d360 h24 must hold structurally; proof =
from-scratch verification run + bit-parity vs cycle-9 verify deck through total_hour 17400.

## Rejected alternatives
- Widening validator limits / adding a subnormal floor: NEVER (gate tampering).
- Remainder split everywhere: changes normal-scale outputs (each population's share by +-ulp) =>
  parity break; scope discipline says trace window only.
- Skipping solveLayer when pool is trace: would leave allocation_fraction stale (nonzero) while
  uptake zeroes — inconsistent bookkeeping.

## Discriminating unit test (plan)
subnormal pool g=3.39519326554e-313 (runtime-opaque cells via allocator, cycle-9 lesson), 3 active
populations with equal demand => raw fractions 1/3; pre-fix: `SUM result != before` (expect drift
+-1 ulp; assert the guard), post-fix: `new_g + new_a == old_g + old_a` EXACTLY, phases >= 0,
uptake all zero. Test must fail against pre-fix code (verify by temporarily reverting guard).
