# Cycle 00006 gate evidence digest — issue-116 planting seed boundary booking

Candidate: ReleaseSafe binary sha256 52aba77c13d37470480216e7b522402b99d9a8d8420d5b2a56357b6f86e77cea
(deck copy; see linker-nondeterminism disclosure below — identity is source+toolchain pinned; runtime
equivalence is proven output-level, not by file hash alone).
Fix (ledger-only): planting seed C/N/P injected into a living plant after the initial condition is booked as
cumulative external boundary input (Fluxes.planting_*_input appended; accumulateAcceptedPlanting follows the
organic-fertilizer precedent; audit identities subtract it for C/N/P; driver reseed site books exactly the
mass the hourly preflight admits; landscape mass-balance checkpoint v19->v20 with explicit legacy rejection).
No pool, solver, tolerance, or validator change: 1998 daily ledger lines d1..139 bit-identical to the cycle-5
canonical run (cmp of "daily conservation accepted" lines) => outputs untouched.

## G1 builds (Zig 0.17.0)
- suites: Debug audit/runs/cycle6-suite-debug-20261022-20261022101330 EXITED 0;
  ReleaseSafe audit/runs/cycle6-suite-releasesafe-20261022-20261022102227 EXITED 0;
  standalone ReleaseSafe test binary: 4404 passed; 1 skipped; 0 failed.
- superseded interim receipts (disclosed): cycle6-suite-debug-20261022095433 (failed only on the Totals-count
  ratchet pin 79->82, legitimately updated for the three new single-identity fields);
  ottawa/cycle6-verify-scratch-candidate-20261022095502 (bf2c8b56 pre-ratchet binary, killed ~d30).

## G2/G3 verification (from-scratch; checkpoint v20 invalidates all v19 resume decks)
- deck evidence/runs/cycle6-verify-scratch-20261022/deck (prod inputs diff-verified byte-identical).
- receipt audit/runs/ottawa/cycle6-verify-scratch-candidate-20261022101316 (pending final tallies):
  1999 d138 "daily conservation accepted" expected (previous candidate failed CarbonMassBalanceLost
  deviation 1.32 g C/m2 at h12073); zero-physics proof via cycle-5 ledger bit-equality through 1999 d137.

### Linker nondeterminism disclosure (G1)
Two fresh ReleaseSafe links of the identical source (same command/working tree) differ in exactly 81 bytes
(LC_UUID at file offset 1889 plus matching symtab entries near EOF; otool confirms Mach-O LC_UUID). Byte-for-byte
hash equality across links is therefore not a property of the macOS toolchain; earlier "identical sha" receipts
were no-op (non-relinking) installs. Identity of the candidate is pinned by source tree + Zig 0.17.0 toolchain;
runtime equivalence is proven at the output level (verification deck 52aba77c13d37470480216e7b522402b99d9a8d8420d5b2a56357b6f86e77cea
vs subsequent rebuild 415e999a2a0812b6... on identical inputs, ledger-line bit-comparison) rather than by file hash alone.

## G2 trajectory verdict
- 504 "daily conservation accepted" (1998 d1..1999 d139). 1999 d138 accepted carbon defect 8.754659807282035e-14
  (previously CarbonMassBalanceLost +1.32 g C/m2). First 502 ledger lines bit-identical to the cycle-5 canonical
  run (cmp /tmp ledger extracts) => zero physics change; the fix only books the boundary input.
- Event profile unchanged: DEV-022 x2, DEV-023 x3, InsufficientSoilNitrite 0, zone-fraction violations 0.
- Engine exit: distinct NEW defect 1999 d140 HourlyPlantConservationFailure -> issue-117 (registered with
  full diagnostic terms); trajectory record: accepted through h12096 (end d139), failed within d140.

## G4 suites/tests
- New tests: planting publish/identity closure (landscape_boundary_balance_test.zig), checkpoint v19 legacy
  rejection (landscape_mass_balance_checkpoint.zig), Totals ratchet pin updated 79->82 with both guards intact.

## G5 scope discipline
- Owned sources: validation/mass_balance_audit.zig, validation/landscape_boundary_balance.zig,
  validation/landscape_boundary_balance_test.zig, io/checkpoint/landscape_mass_balance_checkpoint.zig,
  ecosys_ng.zig (reseed-site booking block only). No tolerance/validator/physics edit anywhere.

## G6 disclosures
- Interim superseded receipts listed above (failed ratchet-pin suite; killed pre-ratchet scratch run).
- LC_UUID linker nondeterminism (see section above) - reproducibility evidence downgraded from file-hash to
  source-pinned + output-level identity, honestly recorded rather than claimed stronger than measured.

## G7/G9
- No secret/scenario data modified; read-only corpora untouched (f77src/f77example/ecosys-ng-prod-examples).
- Retention manifest: audit/experiments/cycle6-verify-scratch-20261022/retention.json (binary paths + sha256).

## G8 (remote equality)
- Derived at close: cycle commit pushed to main; HEAD == origin/main verified after push.
