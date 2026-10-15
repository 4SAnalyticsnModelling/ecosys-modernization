# issue-110 — worker-scratch operators write back the WHOLE branch array: lost update across compute-pool workers

**Status: OPEN — root cause located, fix designed, not yet implemented (session ended mid-fix).**
Found 2026-10-15 while closing the G2 cell of cycle 00002. Reproduced, deterministic mechanism, production-relevant
whenever the compute pool runs more than one worker over more than one cell.

## Symptom

`plant.lifecycle.reproduction.test.reproduction worker scratch is bitwise equivalent under disjoint grid concurrency`
(`ecosys-ng/src/plant/lifecycle/reproduction.zig:408`) fails intermittently:

```
38/52 plant.lifecycle.reproduction.test.reproduction worker scratch is bitwise equivalent under disjoint grid concurrency...slices differ. first difference occurs at index 1 (0x1)
============ expected this output: =============  len: 2
[0]: 6
[1]: 6
============= instead found this: ==============  len: 2
[0]: 6
[1]: 0
FAIL (TestExpectedEqual)  reproduction.zig:461 -> expectEqualSlices(f64, baseline_canopy.branch_potential_seed_site_count, worker_canopy...)
```

Not FP noise and not flakiness of the test: a whole branch's contribution (6.0) is replaced by its pre-hour value (0.0).

## Measured frequency (this session, all inside `audit/runs/zig017-repro-reproduction-test-20261015-1/`)

| probe | result |
|---|---|
| full `zig build test` (`zig017-test-20261015-1`) | FAIL |
| exact-name `--test-filter`, 15:26, under full-run load | FAIL (`51 passed; 1 failed`) |
| full `zig build test` repeat (`repro2.log`) | PASS (4518/4520, 1 skip, 1 crash, 0 fail) |
| exact-name filter, idle (`filtered-single-name.log`) | PASS (52/52) |
| 12x exact-name filter under 6x CPU load (`loop12.log`) | **10 PASS / 2 FAIL** |
| 40x under load until first failure (`first-captured-failure.log`) | FAIL at iteration 11 |

~4 failures in 16 bounded runs => ~25% under contention. A single full-suite run easily misses it, which is exactly why
`audit/runs/zig017-test-20261014-4` reported 4518/4520 with zero assertion failures. **The defect is not new**:
`git log` on the three operators below ends at `514dd68` (2026-09-18) and the test file's only later touch is `026c309`
(4 insertions / 3 deletions, pure `@typeInfo -> ti_compat.fieldViews` codemod, no behaviour change).

## Root cause — read-all / write-all against shared canopy state

Each reproduction operator snapshots the **entire** branch-indexed state array into its per-worker scratch, mutates only
its own cell's branch range, then copies the **entire** array back:

| file | snapshot | write-back |
|---|---|---|
| `ecosys-ng/src/plant/growth/potential_seed_site_accumulation.zig` | `:36 @memcpy(workspace_seed_sites[0..branch_count], state.potential_seed_site_count)` | `:58 @memcpy(state.potential_seed_site_count, workspace_seed_sites[0..branch_count])` |
| `ecosys-ng/src/plant/growth/final_grain_number.zig` | `:46 @memcpy(workspace.grain_count[0..count], state.grain_count)` | `:77 @memcpy(state.grain_count, workspace.grain_count[0..count])` |
| `ecosys-ng/src/plant/growth/maximum_individual_grain_size.zig` | `:33` | `:54` |

`reproduction.zig:106 workerScratch` correctly hands each `worker_index` a disjoint scratch partition, and the compute
pool correctly gives each worker disjoint *cells* — but the branches of *other* workers' cells live inside the array
each worker copies back. Interleaving worker A (cell 0) and worker B (cell 1):

```
A: memcpy-out  state=[0,0] -> A.scratch=[0,0]
B: loop        state  = [0,6]
A: memcpy-in   state  = A.scratch = [0,0]      # B's branch silently reverted
```

Which value survives is a race, so the same hour produces different branch seed sites depending on thread schedule.
The test at `reproduction.zig:408` exists precisely to catch this and does so ~25% of the time.
`plant/root/plant_root_metabolism_state_update.zig:510-511` looks similar but copies scratch->scratch (per-worker), so
it is **not** affected; the audit of `@memcpy(workspace` in `src/plant` found no fourth case.

## Fix (designed, not applied — src was held read-only for the 0.17 diagnostic investigation)

Clamp both copies in the three operators to the owned range, which is already validated
(`first_branch <= end_branch <= count`) and already the only range the loop touches:

```zig
@memcpy(workspace_seed_sites[first..end_], state.potential_seed_site_count[first..end_]);
// ... unchanged loop over first..end_ ...
@memcpy(state.potential_seed_site_count[first..end_], workspace_seed_sites[first..end_]);
```

No other semantics move: the range is disjoint across workers, scratch is per-worker, and single-worker decks take an
identical path. Expected effect on the Ottawa deck (single cell, worker pool degenerate): **bit-identical outputs** —
so the acceptance test is the deck diff, not just the unit test.

Validation plan for the next cycle:
1. apply the 6-line change to the three operators;
2. strengthen the test to repeat the 2-thread apply ~64 rounds (a single racy round is a weak detector);
3. `zig build test` — must return to 4518/4520 (1 skip, 1 crash, **0 failures**) — that closes G2 for cycle 00002;
4. rebuild ReleaseFast, rerun the sealed deck and `zig_run_diff.py` against
   `evidence/runs/zig017-frontier-20261015-1/deck/runottawa_output_files` — expect `cells_differing = 0`;
5. run the exact-name filter 12x under load (`audit/runs/zig017-repro-reproduction-test-20261015-1/loop12.log` is the
   template) and require 12/12 PASS.

## Also true, and why this is not the 0.17 divergence

The Ottawa deck is one grid cell, so its worker pool cannot trigger this; it does not explain the d57 aqueous or d113
conductive-flux diagnostics (issue-109). It is a separate, real concurrency defect for multi-cell production decks.
