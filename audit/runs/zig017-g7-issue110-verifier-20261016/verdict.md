# G7 independent verification — issue-110 fix (worker-scratch whole-array write-back clamp)

**Provenance**
- Date: 2026-10-16 · Repo: ecosys-modernization · Tree: HEAD `77beb81` + uncommitted issue-110 fix (source-dirty digest `3cdcce5b…` vs `107aebb`, matching the G5 parity binding `51c03bda…`)
- Verifier: fresh-context READ-ONLY sub-agent (GLM-5.3-Flash, dsh), no write/commit/run rights. Scope per brief: C1 mechanism, C2 serial equivalence, C3 completeness sweep, C4 detector strength; C5 forbidden-pattern scan, C6 deck-diff receipt check.
- Verdict below is the verifier's final message, verbatim, unedited.

**Verifier-attempt trail (recorded honestly)**
1. `30d91c73` (first verifier, earlier 2026-10-16): reported PASS 6/6 in-conversation; verdict text was never persisted to disk before session compaction — receipt lost, hence this re-verification. Not citable as evidence by itself.
2. `f973caa2` (background retry): died mid-run ("plant_root claim verified (scratch→scratch); auditing other memcpy candidates for C3"). No verdict.
3. `cd3cf246` (background retry): died mid-run ("Diffs match the claim. Now reading full sources to verify loop ranges and workspace ownership."). No verdict.
4. Final verifier (foreground, 2026-10-16): completed all checks. **Verdict below.**

**Maintainer cross-checks after the verdict**: C5 covered by cycle gate G6 (re-recorded PASS with DEV-004 justification; see `audit/runs/cycle-runner/` receipts). C6: `audit/runs/zig017-deckdiff-20261016-1/diff.json` = 17/17 streams, 391,349 cells, 0 differing, max_abs 0.0, IDENTICAL — matches the verifier's parity citation.

---

## Verifier final message (verbatim)

⏵ C3 and C4 complete; composing final verdict.

**C3 classification complete.** The three remaining hits are all benign under the discriminator:
- `biological_climate_acclimation.zig:321–326`: `applyDaily` is a single-threaded whole-grid daily refresh (`ecosys_ng.zig:7602`, resume path `:591`; gated `source_hour == 1` at `biological_climate_acclimation.zig:254–256`). It allocates its own candidate buffers (`:272–283`), loops all cells internally (`:285`), and copies from function-local candidates into the full outputs arrays in one thread — no per-worker scratch, no concurrent write-back.
- `pool_transaction_replay.zig:229–237` (`copyState`, used at `:79`/`:93`): a single-caller two-phase transaction replay (docstring `:65–66` "caller-owned scratch, then atomically publishes"). `apply` has no production call site — the module is referenced only as a type (`plant_root_nutrient_uptake.zig:151`) and test index (`plant_test_index.zig:138`); invocations are the file's own tests. Not a worker-partitioned kernel.
- `harvest_adapter.zig:158–165`: destination slice is per-plant (`plant_litter_base = plant * (layer_count+1) * salt_count`, `:157`) — disjoint across workers, same class as the stalk per-plant publish; the whole-array memcpys into it use per-plant workspace sources.

**C4 verified non-vacuous.** `reproduction.zig:408–472`: serial `applyTile` baseline over 64 rounds (`:439–441`) vs two threads × 64 `applyOwnedCells` rounds on a shared `GridWorkspace` (`:460–466`), compared with `expectEqualSlices` on all three mutated arrays (`:469–471`). Linear accumulation is never reset, so any single lost update in any round persists to the final comparison — matching the pre-fix failure signature (`[6,6]` vs `[6,0]`, `first-captured-failure.log`). Detection probability per run ≈ 1 − 0.75⁶⁴.

---

VERDICT: PASS

**C1 — Concurrency safety.** The three operators run under production dispatch `runIndexedKernelAcrossSerialTiles(...applyOwnedCells)` (`src/stages/hourly_vegetation.zig:763`): tiles are traversed serially while owned cells execute concurrently across compute-pool workers (`tile_kernels.zig:60–73`; partitioning via `balancedPartition` in `compute.zig:779–818`, disjoint ranges per `compute.zig:1028–1039`). Both `@memcpy`s in each operator are now clamped to the worker-owned branch range `[inputs.first_branch..inputs.end_branch]`: `potential_seed_site_accumulation.zig:39,61`, `final_grain_number.zig:48,79`, `maximum_individual_grain_size.zig:35,56`, each annotated with an issue-110 comment. Scratch is per-worker disjoint memory via `GridWorkspace.workerScratch` (`reproduction.zig:61–121`), and branch indices are globally assigned (`plant = cell*species + species`), so owned ranges are disjoint across workers. Pre-fix, the whole-array write-back (`state.potential_seed_site_count[first..] ← workspace[0..count]`) reverted other workers' in-flight updates — a genuine lost update (issue-110 record, interleaving trace). Post-fix, every write touches only shared state owned by that worker. The full-array `@memset`s in `final_grain_number.zig:49–50` are deliberately retained: they operate on per-worker scratch, not shared state, and are serial-equivalent. The whole-array snapshot at `final_grain_number.zig:47–48` reads only (no hazard) and feeds only the owned-range loop.

**C2 — Serial bit-identical.** In the single-worker path (`compute.zig:789`: kernel invoked once with index 0 and the entire cell range), `first_branch = 0` and `end_branch = branch_count`, so the clamped copies are byte-for-byte the same copies as before. For every out-of-range scratch element, the pre-fix serial behavior was identity (scratch written then copied back unchanged); post-fix those elements are simply never read or written. All arithmetic, loop bounds, validation (`first_branch <= end_branch <= count` asserts), and error paths are untouched. No serial output can move; this is corroborated by the sealed-deck parity result `cells_differing = 0` (issue-110 validation record, `audit/runs/ottawa/zig017-parity-20261016-1/`).

**C3 — No fourth vulnerable copy site.** Audited all 66 `@memcpy` hits touching plant state in `src/plant` under the discriminator *worker-partitioned range over shared arrays + whole-array write-back feeding shared state*. Benign classes found: (a) structural per-plant/self copies (dormancy, phenology, growth_stages, `plant_root_system` `self.previous_X = self.X`, `litter_ingress.zig:77` state→state); (b) copies into function-local/per-plant locals (storage_remobilization, root gas/salt exchange, `stalk_layer_state_update.zig:52`, `harvest_adapter.zig:158–165` — per-plant destination slice at `:157`); (c) scratch→scratch within one worker (`plant_root_metabolism_state_update.zig:510–511`); (d) single-threaded whole-grid operators with no per-worker partitioning — `biological_climate_acclimation.applyDaily` (`:321–326`, driver call `ecosys_ng.zig:7602`, internally loops all cells `:285`) and `pool_transaction_replay.apply` (`:79/:93`, no production call site, single-caller two-phase replay); (e) `oxygen_constraint.zig:49` explicitly not called in parallel (A8a). The issue-110 record's own audit conclusion ("no fourth case") is confirmed.

**C4 — Strengthened test detects the pre-fix race non-vacuously.** `reproduction.zig:408–472` builds a serial `applyTile` baseline over 64 accumulation rounds (`:439–441`) and runs two threads × 64 rounds of `applyOwnedCells` with per-worker scratch on a shared `GridWorkspace` and shared canopy/plants state (`:443–466`), then asserts bitwise equality on all three mutated arrays (`:469–471`). Because seed-site accumulation is monotone and never reset, a single whole-array write-back reversion in any round shifts the final slice — detection probability per run ≈ 1 − 0.75⁶⁴, matching the captured pre-fix failure (`[6,6]` vs `[6,0]`, `audit/runs/zig017-repro-reproduction-test-20261015-1/first-captured-failure.log`). Not vacuous: the test failed before the fix and passes after, under 6× CPU load 12/12 (`loop12.log`).

**Coverage note (follow-up, non-blocking).** In the strengthened test, `anthesis_day` is never set, so `final_grain_number` and `maximum_individual_grain_size` gate-continue early on every round — the race paths of those two operators are not exercised by this test (their `expectEqualSlices` at `:470–471` are satisfied trivially). Their correctness rests on the C1 dispatch argument (identical fix shape, identical kernel dispatch) plus their existing unit tests. Recommend a follow-up that sets `anthesis_day`/grain-fill inputs so all three operators' race paths are live; this does not affect the present verdict.

---

**Post-verdict maintainer actions**: G7 recorded PASS in the cycle ledger from this file; coverage note copied to `.agent/backlog.md` as a non-blocking follow-up under issue-110.