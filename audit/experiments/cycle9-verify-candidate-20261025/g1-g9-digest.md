# Cycle 9 verification digest — issue-119 InvalidPlantInventory 1999 d286

G1 identity — base b6640f6 (cycle-8 close). Candidate: ecosys-ng/src/plant/salt/harvest.zig
   (per-root removal clamp + realized litter booking) + discriminating unit test; probes reverted.
   ReleaseSafe zig 0.17.0 binary 23057c94f9435ec840926991074ca0c2bc7aabaf9ae538849978d96efd1d0038
   (deck copy == install copy; LC_UUID policy inherited from cycle 6).

G2 diagnosis receipts (audit/runs/ottawa/):
   - cycle9-probe-d286-20261024-attempt3-ABORT-DATA: deterministic re-abort; first bad value ever
     = roots.salt_content_mol[104] (plant 0, domain 1, layer 1, Al) = -2.465190328815662e-32.
   - attempt4-WRITER-PINNED: TEMPDIAG119W -> writer=harvest_adapter (daily GROSUB 12655-12890 salt
     block, ecosys_ng.zig:3971), same hour 6851; no other salt writer tagged.
   - attempt5-X-PINNED: TEMPDIAG119X exact birth arithmetic: layer=1 root=3 salt=Al
     prev=1.9066168787981847e-16 total=1.4148265068566469e-12 litter==total (lf_c==sumC==
     3.0413572522379505e-4 -> litter_fraction==1e0), root_fraction=1.3475976521207255e-4,
     new=-2.465190328815662e-32. Verified in IEEE double: total*fl(w/total) - w = +2^-105 = ulp(w).

G3 fix — salt/harvest.zig state_updateRootRemoval: removal = litter*root_fraction computed; when
   next < 0 (only possible 1-ulp double-rounding overshoot at full removal), pool := 0 and the
   litterfall output is charged the realized removal (ledger closes exactly). Non-negative path
   keeps the identical arithmetic sequence => bit-safe. Legacy parity: ZEROP-to-zero cascade
   hazard class (AGENTS.md "fix legacy hazards in Zig"). Unit test uses runtime-opaque pool cell
   (comptime folding of the overshoot expression defeated deliberately).

G4 suites (direct test-binary receipts in audit/experiments/cycle9-diagnose-119-20261024/logs/):
   tests-module Debug AND ReleaseSafe: 4407 passed / 1 skipped / 0 failed (includes new test).
   Executable-root both configs: 71/120 then the documented pre-existing issue-115 fixture OOB
   crash (hourly_heat_water_solute.zig:10686) = baseline at base commit; file not in module_index.

G5 from-scratch verification — audit/runs/ottawa/cycle9-verify-candidate-20261025 (deck
   evidence/runs/cycle9-verify-candidate-20261025/deck built from pristine
   "Cool Temperate Maize-Soybean ON"): 1999 d286 kill morning ACCEPTED (identical kill diagnostic
   litter_c=3.0413572522379505e-4 byte-for-byte vs the cycle-8 abort line); zero
   InvalidPlantInventory occurrences in the whole 17400-hour run; trajectory ran ~1900 hours of
   new clean territory to 1999 d360 h24.

G6 bit-parity — 34 files / 115,811 rows = every row of the cycle-8 verified deck (through 1999
   d285) BIT-IDENTICAL in the cycle-9 deck (python row-compare, .tmp/cycle9_parity.py).
   Cycle-9 deck now holds 129,112 rows (13,301 new rows = new accepted territory d286..d360).

G7 gates untouched — validator (landscape_mass_inventory_plant.zig) and every tolerance remain as
   at base; the fix changes engine state only at hours that previously ABORTED.

G9 frontier — last accepted hour = 1999 d360 h24 (scene 2 hour 8640; total_hour 17400; daily
   conservation accepted stderr.log:86005). Run exit_code=1 at total_hour 17401 with a NEW defect
   class, registered as issue-120: HourlyLayerConservationFailure quantity=oxygen layer_scope=17
   before=3.39519326554e-313 after=3.3951932656e-313 residual=5e-324 (subnormal pool, 1 denormal
   ulp; stderr.log:86007) preceded by soil phase-enthalpy Newton-Picard stagnation warnings.
