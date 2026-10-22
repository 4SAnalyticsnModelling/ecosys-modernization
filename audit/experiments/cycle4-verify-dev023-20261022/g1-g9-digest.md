# Cycle 00004 gate evidence digest — DEV-023 nitrite supply admissibility (issue-113)

Candidate: ReleaseSafe binary sha256 9021865ea89deff4e7eb8f4f63f2268472290b6ed47df32b7a949715df6586ae
(audit/runs/cycle4-build-candidate-20261022013832/build-product/ecosys_ng; retention manifest
audit/experiments/cycle4-verify-dev023-20261022/retention.json; reproducible rebuild
audit/runs/cycle4-rebuild-candidate-20261022021702 EXITED 0 -> identical sha).

## G1 builds (Zig 0.17.0)

- Debug: audit/runs/cycle4-build-Debug-20261022021610 EXITED 0 (build-product sha256 9b283fa789bd77d913aa26295244e404584573d3f76061423d97c6e23b3c9307).
- ReleaseSafe: cycle4-build-candidate-20261022013832 EXITED 0 (9021865e…); rebuild cycle4-rebuild-candidate-20261022021702 EXITED 0 identical.
- ReleaseFast (production): cycle4-build-ReleaseFast-20261022021333 EXITED 0 (70a4393e32ebc8f738d210306ea0b12b0f924239e1326f483a071aeda5e8152f).

## G2 suites (gate suite = tests-module, cycle-3 precedent)

- Debug fresh: audit/runs/cycle4-suite-tests-module-Debug-rerun-20261022020031 EXITED 0;
  `zig build test-module --summary all` (cached, same artifacts): 4401 pass / 1 pre-existing skip /
  0 fail of 4402 (= cycle-3's 4401 total + the new DEV-023 cap test).
- ReleaseSafe: audit/runs/cycle4-suite-tests-module-ReleaseSafe-20261022015221 EXITED 0 (4401/1 skip,
  1m cached summary re-confirm job receipt).
- Disclosure: the smaller executable test root (`zig build test`) crashes deterministically at
  src/stages/hourly_heat_water_solute.zig:10686 (`self.schedules[self.attempts]`, index 4 len 4) in
  test "fixed external hour recovery escalates through the full chain and stops on hard defects" —
  reproduced with cycle-4 edits STASHED at base 9368a7b => pre-existing, registered as issue-115;
  receipts audit/runs/cycle4-suite-tests-Debug-20261022014533, cycle4-suite-tests-ReleaseSafe-20261022015221.
- Concurrent first Debug-module receipt cycle4-suite-tests-module-Debug-20261022014534 (EXITED 0) was
  run alongside the ReleaseSafe suite; superseded by the serial rerun above to eliminate any doubt.

## G3 conservation (independent of solver residuals)

audit/runs/ottawa/cycle4-verify-dev023-20261022014415/stderr.log — 311 `daily conservation accepted`
lines (engine's independent pool+flux ledger over all elements/ions) from day 181 (1998) through
day 126 (1999); zero ledger rejections; run exits at h11806 issue-114 (distinct defect) with no
invalid hour published.

## G4 legacy semantics (file:line)

- nitro.f 1781-1782 (non-band denitrifier), 1970-1971 (band), 2943-2944 (chemodenitrification):
  `FNO2=AMAX1(FMN,RVMX2(N,K,L,NY,NX)/RNO2Y(L,NY,NX))` — FMN-floored per-population share, summed
  across populations with no <=1 cap.
- redist.f 6221-6222: `ZNO2S=ZNO2S+TNXFLS+XNO2S+TRNO2+XNXFXS` — NO2 balance applied unclamped =>
  legacy NO2 can dip negative (DEV-019/DEV-022 precedent; legacy warn-and-rebase is not acceptance).
- Zig translation: denitrification.zig 113-116 per-unit NO2 limiter = (pool rate + own NO3->NO2) *
  share — the sum over populations inherits the >1 share defect; gate applyZone
  nitrogen_state_update.zig 1594-1639. Fix keeps the legacy production term exact and only enforces
  withdrawal <= supply at the modern commit boundary (DEV-023 row in audit/intentional-deviations.md).

## G5 parity

- Replay territory bit-identity: days 181-191 ledger lines bit-identical vs
  audit/runs/ottawa/cycle3-confirm-resume4320-20261022b/stderr.log (diff of lines 1..11 empty), and
  days 201-202 bit-identical vs the drifted-deck interim run — non-engagement of the cap is bit-safe.
- h4556 DEV-022 cap re-fires with bit-identical factor 9.996122280942202e-1 (verify run stderr);
  second new-territory DEV-022 fire identical across binaries (9.992880535533826e-1).
- h4855 decisive numbers identical end-to-end: dump requested NO2 1.6231499047096993e-7
  (audit/runs/ottawa/cycle4-diag-no2-20261022005737) == cap input (both runs);
  DEV-023 factor 9.999037288974819e-1 in both 48097cc1 and 9021865e runs.
- Legacy oracle comparison beyond h2173 remains blocked (recorded); parity here is cross-run
  determinism, explicitly NOT claiming full legacy output parity (that gate belongs to F2/F3 work).

## G6 no forbidden workarounds

DEV-023 registered (PROPOSED, adversarial revalidation scheduled). No post-solve clamp, no
tolerance/ceiling change (nonnegativeCandidate 64*eps identical to DEV-022's allowance), no legacy
edit, no unregistered physics change; failure diagnostics added are log-only (no state effect).

## G7 separate legacy-first derivation + reproduced decisive result

Legacy evidence (G4 lines) was located and recorded in durable notes BEFORE writing the cap.
Decisive result reproduced twice: interim binary 48097cc10385df701b9c345e8fa51903a44a068b38e867916760b0d8767f9dd9
(drifted-deck resume from d200) and candidate 9021865e (clean deck rebuilt from pristine gen-4320
parent evidence/runs/zig017-resume4320-dev021-20261021/deck via build_resume_deck.py) — identical
factors, identical conservation ledgers through overlapping days, identical issue-114 exit hour.

## G9 repo-local

All heavy commands via `./scripts/project.sh exec` (TMPDIR/.cache/.uv-cache/.zig-cache injected
repo-local, see any receipt.json environment). Deck (76M, gitignored evidence/*), decks' manifests
and checkpoints repo-local. Retention manifest binds 5 build-product binaries (verified sha256).
