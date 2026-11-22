# issue-130 — SoluteConcentrationExceedsWaterMolarity at wh 29422 (2001 d130 h22, scene 4)

## Registration (cycle 12, base dc6c8ab; found by v18 authority + lane v129c at wh 29422)
Terminal: `SOLUTE aqueous concentration exceeds water molarity: cell=1 packed_component=39
name=aqueous.nitrate_non_band concentration_mol_per_m3=5.563792700510589e4 water_mol=5.541803700441147e4`
(ratio 1.004, ONE warning), then reaction solver fails cell=0 layer=1
(`failure_report_bound=true` -> hourly science failed -> engine exits 1). Identical bits in
v129c lane and v18 authority. Guard = reaction_solver_numerics.validateAqueousMolarity
(conc > water_molarity AND zone fraction >= 1e-12): a hard physical bound (aqueous
concentration cannot exceed pure-water molarity); `dt_recoverable` has no solute entries,
so this class terminates by design.

## Forensics round 1 (lane v130a, P130 probes, in-place resume of deck-29184-snapshot)
Receipt: audit/runs/ottawa/cycle11-v130a-20261117/stderr.log (P130 series 771 lines / 238 h).
- NOT desiccation: water_mol ~5.542e4 nearly constant (full-hydration summer topsoil).
- cell=1 nitrate_non_band concentration is CHRONIC from resume (2.787e4 mol/m3 at wh 29184),
  oscillates 2.8e4..5.3e4 hourly, creeps over ~10 days to 5.49e4, then crosses in final hours.
- frac_nb fixed 9.999999999998899e-5 -> inventory ~2.8-5.6 mol N/m3 (~40-78 g N/m3 topsoil);
  normal aqueous range per tests ~1e-3..1e-5 mol/m3: this pool is 7-10 orders heavy.
- Earlier survival precedent: 'SOLUTE fixed-hour recovery attempt failed substeps=32
  DidNotConverge' survived at wh ~29185; the trip hour itself reports failure_report_bound=true.

## Hypotheses (UNVERIFIED)
(a) non-band (macropore/immobile) solute water flux bookkeeping leaves solute behind while
    water exchanges -> inventory ratchet;
(b) band<->non-band transport fraction switch double-counts nitrate into the 1e-4 non-band
    zone;
(c) legacy parity: SOLMOB/IONP legacy guard differs (f77 provenance check needed - f77query);
(d) 2001 scene-4 management event (manure/fertilizer) loads nitrate into non-band pool, then
    normal concentration dynamics are unphysical because the zone water volume is tiny.

## Assets
- Resume state: .tmp/cycle121/deck-29184-snapshot (1365 checkpoint bins = v129c final 29184).
- Probe recipe: fix130_p1 build line (ship + P130 dump per validate call when
  wmol<3e4 OR no3nb>0.5*wmol, cells all + frac_nb/frac_b); lane = kink-lane2 NAME +
  in-place journal truncation past horizon (fast-resume), SRC!=LANE guard in place.
- v130a death sequence shows NO recovery ladder for this class (by design).

## Forensics rounds 2-3 (2026-11-19..21, lanes v130b/c/d/e/f + scratch) - SUPERSEDE hypotheses (a)-(d)
- Geometry is legacy-faithful: the fertilizer band (2000-04-25 event, width 0.05 m depth 0.15 m)
  diffuses downward (DPNOX/DPNO3) and CLAMPS at legacy bounds (WDNOB<=ROWO hour1.f:5005,
  fraction AMIN1(0.9999) hour1.f:5050, downward width copy :5034) until frac_b = 0.9999 EXACT
  for ratcheted layers; sliver frac_nb = 1-0.9999 = 1e-4. Zig hourly_fertilizer_band_geometry.zig
  mirrors every statement. The clamp is a LEGIT legacy product, not a defect.
- Zone mass math is bit-faithful: transport face flux deposits conc_upstream x flux into the
  sliver (trnsfr.f:6347 == transport.zig:133-143); reload ulp-exact (P130R); reactions add ~0
  (P130C); irrigation adds 0 (P130I); sliver mass growth (+0.02108 mol over 238 h, layer 1) is
  transport import from L0 capillary flux, strictly conservative (P130D, requireLocalConservation).
- The sliver concentration 8.7e3 -> 5.56e4 mol/m3 is the 1/frac read-back of legitimate
  profile-wide summer 2001 N accumulation. Legacy computes the SAME absurd CNO1 (no molarity
  guard exists anywhere in f77src).

## Root cause + fix (2026-11-22, D-31, commit 34f2f49)
- THE GUARD fired on a zone LEGACY NEVER READS: legacy gates every zone concentration read on
  the zone WATER VOLUME, `IF(VOLWNO.GT.ZEROS2)` else CNO1=0.0 (solute.f:533/539; ZEROS2 =
  ZERO2*DH*DV = 1e-6*DH*DV, starts.f:94/:270; Ottawa f25si98 DH=DV=1.0 m). At the trip hour
  (v130d last P130D line) sliver zone water = 9.999999999998899e-5 * 3.7280625661375065e-3 m3
  = 3.728062566137096e-7 <= 1e-6 => legacy sets CNO1=0.0; the port guard evaluated the sliver as
  a solution because DEV-021 used a fraction proxy 1e-12 instead of the legacy ZERO2-scale
  zone-water predicate (wrong scale by 6 orders).
- Fix = producer-parity predicate (NOT a loosening): zoneHoldsLegacySolution compares
  fraction x carrier water against the area-scaled ZEROS2 (issue-061 helper
  core/legacy_water_negligible_floor.zig); ReactionParameters carries the hourly SOLUTE carrier
  (matrix_liquid_water_m3) + cell floor (canopy_cell_area_m2); default keeps all zones present;
  the molarity bound itself and non-finite validation are UNCHANGED for every zone legacy reads.
  Snapshot codec v3 (v1/v2 archives decode by version-aware parameter prefix + defaults).
- Discrimination: new test uses trip-shape numbers (skip at 3.73e-7 zone water; MUST still fire
  at 10x water; boundary GT semantics; inf-carrier strict). NEUTER (predicate -> always present)
  fails EXACTLY that test; restored rc=0. Suites green-shape (debug/RS/test-module RC=0;
  test-executable = exact issue-115 baseline).
- Behaviour receipt: fix131 lane (engine from 34f2f49 tree, resume of deck-29184-snapshot,
  audit/runs/ottawa/cycle12-fix131-20261122) PASSES wh 29422 clean and continues
  (zero SoluteConcentration failures; documented SOLUTE stagnation-recovery warnings survive
  per v130a precedent).
- Follow-up (UNVERIFIED, next cycles): sub-ZEROS2 zones still carry concentrations that feed
  port solver kinetics (legacy evaluates them as 0); chronic rates on such zones were ~0 in
  P130C (mass-rate-limited), but a zone-read parity audit is banked.
