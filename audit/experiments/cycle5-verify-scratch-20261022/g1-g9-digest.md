# Cycle 00005 gate evidence digest — issue-114 zone-fraction complement closure

Candidate: ReleaseSafe binary sha256 a1510febb6cf53b3a448b5373db7bf75bf9552771fd74d21f0ac6722ed7efe5b
(audit/runs/cycle5-build-candidate-20261022040240/build-product/ecosys_ng; retention manifest
audit/experiments/cycle5-verify-scratch-20261022/retention.json; reproducible rebuild
audit/runs/cycle5-rebuild-ReleaseSafe-20261022040742 EXITED 0 -> identical sha).
Fix: fertilizer_band_state.scienceZoneFractions — stored pre-prepare band authoritative, non_band = 1 - band
(legacy hour1.f 374/5054 `VLNO3 = 1.0 - VLNOB`); validator plant_root_gas_transport.zig:181-196 untouched
(16*eps intact); permanent violation diagnostic added at the raise site.

## G1 builds (Zig 0.17.0)

- ReleaseSafe candidate + reproducible rebuild (above), EXITED 0 both.
- ReleaseFast audit/runs/cycle5-build-releasefast-20261022040509 EXITED 0
  (build-product sha256 ff0a759f9a904fe9c6c11a644bd910ac84272539ef5ba34f1582b0e7f77bd29e); optimization
  campaign deferred per plan (F6 after F1-F5).
- Instrumented diagnostic audit/runs/cycle5-build-diag-20261022022758 EXITED 0 (fdcffd43...).

## G2 tests

- tests-module Debug audit/runs/cycle5-suite-tests-module-Debug-20261022033849 EXITED 0; standalone binary
  verdict "4402 passed; 1 skipped; 0 failed" (pre-existing skip only).
- tests-module ReleaseSafe audit/runs/cycle5-suite-tests-module-ReleaseSafe-20261022034747 EXITED 0;
  standalone verdict identical.
- Builder stderr contains one "failed command:" sub-step noise line in both receipts; builder summary
  "3/3 steps succeeded" plus the standalone runs above decide (disclosed, benign).
- Superseded interim receipts (started before the issue-114 unit test was added):
  cycle5-suite-tests-module-Debug-20261022025641, cycle5-suite-tests-module-ReleaseSafe-20261022033221.
- New discriminating test "science fractions on a band-expansion hour stay exact complements" passes in both
  modes (stored-band authority + exact closure on an open expansion hour).

## G3 conservation ledgers

Canonical from-scratch verification audit/runs/ottawa/cycle5-verify-scratch-candidate-20261022040928
(candidate binary; deck byte-identical copy of ecosys-ng-prod-examples, diff-verified): 502 accepted daily
conservation ledgers 1998 d1 .. 1999 d137 (defects ~1e-14 class), ZERO zone-fraction violations through
h11806; DEV-022 cap engaged 2x (day 190/1998 factor 9.99612228086011e-1 — same event class as cycle-4
h4556, ulp-shifted by the intentional fix divergence from h4354), DEV-023 nitrite cap 3x (first at
day 203/1998 = h4855 class, factor 9.999037289011135e-1); InsufficientSoilNitrite gate fired 0 times.
Engine exit is a NEW defect at h12073 (1999 d138) CarbonMassBalanceLost deviation 1.32 g C/m2 vs tolerance
4.2e-8, on the 1999 tillage day — registered audit/issues/issue-116-1999d138-carbonmassbalancelost.md;
strict frontier extended from h11806 to h12073 (record-level; frontier.json promotion stays under
update_frontier.py/P0 binding).

## G4 legacy provenance

hour1.f:369-374 and :5049-5055 — band volume fraction VLNOB computed, then `VLNO3(L,NY,NX)=1.0-VLNOB(...)`
(band authoritative, exact complement) at both application entries. Captured defect evidence
audit/runs/ottawa/cycle5-diag-h11806-20261022023043/stderr.log: soil=1 non_band=9.402985596461554e-2
band=9.059701440353886e-1 sum_deviation=3.9968028886505635e-15 (~18 ulp > 16*eps).

## G5 replay / output parity

- Fix-attribution @11640 audit/runs/ottawa/cycle5-fix-h11806-20261022024755: d121-126 replayed bit-clean,
  first OutputReplayRecordMismatch at generation 11804 (1999 d127 h19) = first fix-affected application hour.
- Fix-attribution @4320 audit/runs/ottawa/cycle5-replay-4320-20261022025737: first mismatch at generation
  4354 (1998 d182 h9) = first 1998 band-expansion hour; day 181 identical. Divergence is minimal and exactly
  the expansion-hour outputs.
- Binary parity 028ff86e vs a1510feb (sibling 11640 decks):
  audit/runs/ottawa/cycle5-parity-p28-20261022053138 vs cycle5-parity-p15-20261022053536 — ledgers
  bit-identical and byte-identical mismatch context at generation 11804 => test-code-only binary difference,
  runtime-equivalent candidates.
- Legacy oracle comparison beyond h2173 remains excluded (recorded legacy solver stall); no new parity
  claims made against it.

## G6 verification (new decisive result)

From-scratch re-derivation on byte-identical inputs reproduces every downstream event class (DEV-022/023
caps, deadband hours, tillage h7452, year rollover) and clears the previously fatal h11806 hour while all
ledgers close; run terminated only at the new issue-116 boundary. Corroboration run on 028ff86e
audit/runs/ottawa/cycle5-verify-scratch-20261022025641 terminated by decision at d146 to reclaim CPU
(interim, receipt left RUNNING and superseded; logs retained as evidence of identical behavior to d146).

## G7 issue / registry coherence

issue-114 RESOLVED (audit/issues/issue-114-h11806-invalidrootgastransportsettings.md with full resolution
section). No DEV row: fix restores the legacy invariant in Zig (translational correction, not deviation);
DEV-022/DEV-023 registry rows unchanged. issue-115 root cause pinned (test fixture array under-sized at
hourly_heat_water_solute.zig:10680-10686; file absent from module gate root) — fix next cycle. issue-116
registered (new frontier).

## G9 repo-local

All heavy commands via `./scripts/project.sh exec` (repo-local TMPDIR/.cache/.uv-cache/.zig-cache per
receipt environment). Decks under evidence/runs (gitignored); retention manifest
audit/experiments/cycle5-verify-scratch-20261022/retention.json binds 4 binaries (sha256 verified).
