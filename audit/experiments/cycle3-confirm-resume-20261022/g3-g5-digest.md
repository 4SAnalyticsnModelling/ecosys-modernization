# Cycle 00003 DEV-022 — gate evidence digest (2026-10-22)

Candidate: working tree at base ea78763 + dirty fix, ReleaseSafe reproducible rebuild
audit/runs/cycle3-confirm-build-ReleaseSafe-20261021234803 (EXITED 0, build_product
sha256 36c3784ae0e378d3193ea870050cf33ad659480e07fed0eec2b478caf0ed8556 — identical to
audit/runs/cycle-build-ReleaseSafe-20261021220322410232/build-product, the binary covered by both
module suites; G1/G2 same-hash chain).

## Confirmation run (current binary, durable h4320 checkpoint)
audit/runs/ottawa/cycle3-confirm-resume4320-20261022b: resume=true (stderr.log:5), restart.manifest
generation 4320 copied from evidence/runs/zig017-resume4320-dev021-20261021/deck and
canonical_root re-pointed (audit/runs/cycle3-confirm-manifest-patch-20261022b, fingerprint
control-checked). Engine EXITED 1 at hour 4855 (elapsed 33.9 s).
- Replay check PASS: zero OutputReplayRecordMismatch across parent records 4321-4555 — includes
  hour 4412, the 1-ulp event the pre-deadband binary produced
  (audit/runs/ottawa/zig017-resume4320-dev021-20261021/stderr.log:439 cap factor
  9.999999999999999e-1, stderr.log:444-445 record mismatch). The 64*eps deadband eliminates it:
  current binary replays bit-identically (G5).
- DEV-022 cap engaged exactly once, stderr.log:1125: layer=0 factor=9.996122280942202e-1
  requested_non_band_g_n=4.134932629096317e-6 requested_band_g_n=1.0309808654745636e-4 —
  byte-identical decision to the from-scratch verification
  (audit/runs/ottawa/zig017-verify-dev021-20261021/stderr.log:32213).
- Daily conservation ledgers accepted 22/22 days (4321-4854); values bit-identical to the
  from-scratch run on comparable days (day 181: water=1.7552121371181087e-13
  carbon=5.035720732634534e-14 nitrogen=7.103766980513197e-15; day 202:
  nitrogen=2.1551716670897477e-15; max nitrogen defect over the whole from-scratch run
  1.4114522004349987e-14) — independently assembled pools+flux ledger beyond solver residuals (G3).
- Terminal hour 4855 error=InsufficientSoilNitrite with identical diagnostics to the
  from-scratch run (pool_g=1.7758323953655115e-8, potential_reduction_g=5.6182661611343505e-9;
  this-confirm stderr.log:1125+/4823 vs verify stderr.log:35908-35911,35937). Distinct defect —
  issue-113, cycle 4; not a DEV-022 regression.

## G4/G7 provenance
Legacy-first derivation with reproduced decisive numbers: nitro.f 1682-1693 FMN-floored per-population
competition shares summed without <=1 cap; redist.f 6218-6220 applies the sum unclamped (legacy pools
dip slightly negative; DEV-019 precedent). Term/basis dumps reproducing pool 4.133382671876368e-6 g vs
demand 4.134932629096317e-6 g (+3.74e-4 rel): audit/runs/ottawa/zig017-replay-4320-terms-20261021 and
zig017-replay-4320-terms2-20261021 (stderr.log ~lines 32213-32216). Registry row DEV-022 in
audit/intentional-deviations.md. No legacy/reference edit (git status: f77src/, f77example/,
ecosys-ng-prod-examples/ clean); no tolerance/ceiling change in the fix.

## Retention
build-product/ecosys_ng binaries (10 MB each) stay repo-local under the respective receipt
directories and are not committed (repo convention: no tracked binaries); their identity is bound by
sha256 in the committed receipts above. Large logs are committed where cited.
