# issue-111 — 48 pre-existing pytest failures in ecosys-audit/tests (main, commit 107aebb)

**Status: OPEN — pre-existing debt, NOT introduced by cycle 00002 (stash-verified).**

Found 2026-10-16 while closing cycle 00002: `uv run pytest ecosys-audit/tests -q` =
**48 failed / 104 passed / 1 skipped** both on the committed baseline (working-tree changes stashed,
`audit/runs/cycle-runner/pytest-baseline-107aebb-20261016.log`) and on the post-fix tree
(`audit/runs/cycle-runner/pytest-20261016T201424Z.log`) — zero new failures from the cycle's edits.

## Failure groups (from the two logs)

| group | count | first-glance cause |
|---|---|---|
| `test_swarm_wrapper.py` | 37 | retired 2026-10-08 two-model workflow harness (fixtures/roles/sentinel no longer present) |
| `test_swarm_wrapper_campaign_exempt.py` | 6 | same retired harness |
| `test_traceability_patch.py` | 3 | patch-generation constraints reference ranges that drifted |
| `test_stage_ottawa_deck.py` | 1 | stale expected deck blob: asserts `9ec1bf4e…` (DEV-004 deck half, f6=200), protected deck is `ecf5e61ab453288b1763f81f841729bee34e8426` (f6=100) |
| `test_run_ottawa.py` | 1 | same stale `PROTECTED_EXPECTED_HASH` constant (`9ec1bf4e…` vs actual `ecf5e61a…`) |

## Why it matters

- G2's pytest leg has been silently red on `main`; the cycle 00002 close can only honestly claim
  "no *new* failures vs baseline", which is what its G6/G2 evidence records do.
- The two deck-hash constants are a real trap: any future edit to `stage_ottawa_deck.py`'s target blob
  must update them together (they pin the DEV-004 deck half `f6=100`, blob `ecf5e61a…`).

## Fix plan (bounded, next cycles)

1. Update the two stale hash constants to `ecf5e61a…` (they describe the CURRENT protected deck) or make
   them read the blob from `stage_ottawa_deck.TARGET_BLOB` so they cannot drift again. 2 tests green.
2. `test_traceability_patch.py`: re-derive the expected ranges from the current `f77index` output; if the
   tool changed legitimately, update expectations; if the CSV drifted, that is a defect, not a test update.
3. Retired-harness tests (43): delete `test_swarm_wrapper*.py` with the retired-workflow note, or gate them
   behind an explicit `@pytest.mark.retired_workflow` skip with a pointer to `.agent/adversarial/` history.
   No silent deletion — record it in the cycle that does it.