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
