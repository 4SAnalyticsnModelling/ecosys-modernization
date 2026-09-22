#!/usr/bin/env python3
"""outcompare.py -- compare a legacy ECOSYS hourly output stream against the
corresponding ecosys-ng stream, aligned on calendar keys rather than row order.

Usage (from the project root):

    uv run ecosys-audit/scripts/outcompare.py \
        --oracle <dir>/01998f25ch1 \
        --candidate <deck>/runottawa_output_files/modelled_outputs/carbon/...f25ch1.txt \
        --stream carbon_hourly \
        [--atol 1e-12] [--rtol 1e-6] [--json report.json] [--max-rows N]

WHAT IT DOES

  * Parses both RAW formats as they actually are, with no rewriting of either
    file. The legacy stream is whitespace-separated with a leading row tag that
    is absent from its own header line (22 data fields against 21 header
    names); the candidate stream is tab-separated with a units suffix in each
    heading.
  * Aligns on the cumulative 1-based HOUR OF THE SIMULATED YEAR, derived from
    the legacy `DOY` column (DOY*24) and from the candidate's
    (day_of_year-1)*24 + hour + 1. Row order is never used as the key. The
    legacy `DATE` column is NOT used as a key because it is DDMMYYYY, not
    MMDDYYYY -- elapsed day 2 prints as `02011998`, and reading that as MMDD
    silently mismatches most of the year. It is cross-checked instead: for
    every matched key both sides must agree on (year, month, day, hour), and
    any disagreement is reported as a calendar inconsistency.
  * Reports, per mapped column: matched pair count, max absolute error and the
    exact key where it occurs, MAE, RMSE, bias (mean signed error), the count
    of pairs exceeding the rule, and the FIRST key that exceeds it.
  * Reports unmatched keys on both sides and every column it could not map,
    so nothing is silently dropped.

THE COMPARISON RULE

    abs(candidate - oracle) <= atol + rtol * abs(oracle)

This is a project comparison rule for triage, NOT a scientific acceptance
threshold, and the defaults here are deliberately tight so that real
differences surface rather than being absorbed. Per-quantity reviewed
thresholds are required before any acceptance claim; see
ecosys-audit/PROJECT_CONTRACT.md and the ecosys-output-comparison skill.

WHAT IT DOES NOT DO -- quote these with any number it prints:

  * It does not prove either run is COMPLETE. Completion is a separate
    mandatory proof and neither side currently has it: the preserved oracle
    stops at hour 6,875 on issue-023, and ecosys-ng stops at its solver
    frontier (issue-078). A comparison over the overlap is diagnostic only.
  * It applies NO unit conversion. It assumes the mapping table below has
    already been verified to be unit-compatible, column by column, against the
    legacy value producer. For the carbon hourly stream that check was done:
    outsh.f:54-57 multiplies by 23.14815 = 1e6/(12*3600) for the carbon fluxes
    and 8.68056 = 1e6/(32*3600) for oxygen, i.e. g m-2 h-1 -> umol m-2 s-1,
    which matches the candidate's declared umol m-2 s-1. Layer concentrations
    are written raw (outsh.f:58-61 CCO2S, and the oxygen block likewise).
  * It does not smooth, interpolate, clip, drop outliers, or reset cumulative
    values. A column it cannot map is reported, never skipped quietly.
  * Good agreement on the columns it can map says nothing about columns it
    cannot, nor about state that never reaches an output file.

KNOWN ACCOUNTED-FOR EXCLUSION

  carbon_hourly: the legacy `CH4_15` column has no candidate counterpart. Both
  decks select that slot identically; the deck has 12 runtime layers, so the
  oracle emits a structural zero for layer 15 and ecosys-ng emits no column at
  all. Recorded as issue-085 and reported here as an explicit exclusion with
  that citation, never as a pass.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

LIMITATIONS = [
    "does not prove either run reached its required end time; completion is a separate mandatory proof and neither side has it",
    "applies no unit conversion; the column mapping must be verified unit-compatible against the legacy value producer first",
    "the default atol/rtol is a triage rule, not a reviewed scientific acceptance threshold",
    "no smoothing, interpolation, clipping, outlier removal or cumulative resetting is performed",
    "columns it cannot map are reported as unmapped, and agreement on mapped columns says nothing about them",
]

# stream -> (oracle column name -> candidate column name prefix).
# Candidate headings carry a "[units]" suffix, so matching is by prefix.
STREAM_MAPS = {
    "carbon_hourly": {
        "SOIL_CO2_FLUX": "carbon_dioxide_emission",
        "ECO_CO2_FLUX": "net_carbon_exchange",
        "CH4_FLUX": "methane_emission",
        "O2_FLUX": "oxygen_exchange",
        **{f"CO2_{k}": f"dissolved_carbon_dioxide_carbon_concentration_layer_{k}" for k in range(1, 15)},
        **{f"O2_{k}": f"dissolved_oxygen_concentration_layer_{k}" for k in range(1, 16)},
    },
    # Hourly water, fouts.f N=22. Headings fouts.f:163-214, values outsh.f:118-169.
    # WTR_k is THETWZ(k) and ICE_k is THETIZ(k), both dimensionless volumetric
    # contents (outsh.f:125-135, :146-155), matching the candidate's declared
    # m3 m-3. Slot 4 and the two surface entries are excluded below with
    # citations rather than mapped.
    "water_hourly": {
        "EVAPN": "evapotranspiration",
        "RUNOFF": "runoff",
        "SEDIMENT": "sediment_discharge_water",
        "DISCHG": "external_water_outflow",
        "SNOWPACK": "surface_water_equivalent",
        **{f"WTR_{k}": f"volumetric_liquid_water_fraction_layer_{k}" for k in range(1, 21)},
        **{f"ICE_{k}": f"volumetric_ice_fraction_layer_{k}" for k in range(1, 21)},
    },
    # Hourly heat/energy, fouts.f N=25. Values outsh.f:250-288. Units verified:
    # 277.8 = 1e6/3600 converts MJ m-2 h-1 -> W m-2 (slots 1, 6-13); TCA and
    # TCS(k) are CELSIUS (the TC prefix, versus TK for kelvin); UA/3600 is
    # m s-1; (PRECR+PRECW)*1000/AREA is mm; VPK is kPa. All match the
    # candidate's declared units, so no conversion is applied.
    #
    # The first five columns are WEATHER FORCING, so they double as a direct
    # input-equivalence test: they should agree to near round-off if the two
    # decks really drive the models with the same weather.
    "heat_hourly": {
        "SOL_RADN": "incoming_shortwave_radiation",
        "AIR_TEMP": "air_temperature",
        "HUM": "atmospheric_vapor_pressure",
        "WIND": "wind_speed",
        "PREC": "rain_and_irrigation",
        "SOIL_RN": "ground_surface_net_radiation",
        "SOIL_LE": "ground_surface_latent_heat_flux",
        "SOIL_H": "ground_surface_sensible_heat_flux",
        "SOIL_G": "ground_surface_storage_heat_flux",
        "ECO_RN": "ecosystem_net_radiation",
        "ECO_LE": "ecosystem_latent_heat_flux",
        "ECO_H": "ecosystem_sensible_heat_flux",
        "ECO_G": "ecosystem_storage_heat_flux",
        "TEMP_LITTER": "surface_soil_temperature",
        **{f"TEMP_{k}": f"soil_temperature_layer_{k}" for k in range(1, 21)},
    },
}

# Legacy columns with a recorded, cited reason for having no counterpart.
ACCOUNTED_EXCLUSIONS = {
    "carbon_hourly": {
        "CH4_15": "issue-085: deck selects soil layer 15 but the runtime profile has 12 layers; "
                  "the oracle emits a structural zero, ecosys-ng emits no column",
    },
    "water_hourly": {
        "TTL_SWC": "issue-086: WRONG BINDING, not merely absent. The oracle writes total cell water "
                   "storage (UVOLW*1000/AREA, outsh.f:121); ecosys-ng writes root water uptake in "
                   "the same slot (soil/water/output.zig:136). Comparing them would compare a "
                   "storage term against a flux, so the column is excluded until the binding is fixed",
        "SURF_WTR": "issue-086 second finding: the candidate's value is the correct THETWZ(0) analogue "
                    "but it is published as surface_excess_liquid_water_depth in m rather than a "
                    "dimensionless fraction, so the column cannot be matched by name/unit until renamed",
        "SURF_ICE": "issue-086 second finding: same label/unit defect as SURF_WTR, for THETIZ(0)",
        **{f"WTR_{k}": f"issue-085 class: deck selects soil layer {k} but the runtime profile has 12 "
                       "layers; the oracle emits a structural zero, ecosys-ng emits no column"
           for k in range(13, 21)},
        **{f"ICE_{k}": f"issue-085 class: deck selects soil layer {k} but the runtime profile has 12 "
                       "layers; the oracle emits a structural zero, ecosys-ng emits no column"
           for k in range(13, 21)},
    },
    "heat_hourly": {
        **{f"TEMP_{k}": f"issue-085 class: deck selects soil layer {k} but the runtime profile has 12 "
                        "layers; the oracle emits a structural value for an absent layer, ecosys-ng "
                        "emits no column"
           for k in range(12, 21)},
    },
}


def parse_oracle(path: Path, max_rows: int | None):
    """Legacy stream: whitespace-separated, with a leading row tag absent from the header."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines:
        raise SystemExit(f"empty oracle file: {path}")
    names = lines[0].split()
    rows = {}
    duplicates = []
    calendar = {}
    for line in lines[1:]:
        fields = line.split()
        if not fields:
            continue
        # The tag column is present in data rows only.
        offset = len(fields) - len(names)
        if offset not in (0, 1):
            raise SystemExit(
                f"{path}: data row has {len(fields)} fields against {len(names)} header names; "
                "unexpected layout, refusing to guess"
            )
        values = fields[offset:]
        # Key on DOY, which is unambiguous: it is elapsed days, so DOY*24 is the
        # cumulative 1-based hour of the simulated year (row 1 is 0.042 = 1/24,
        # the 24th row is exactly 1.000). Printed to three decimals, which is
        # far inside the 0.5-hour rounding margin even at the file's last row
        # (286.458*24 = 6875).
        #
        # DATE is deliberately NOT the key: it is DDMMYYYY, not MMDDYYYY --
        # elapsed day 2 of 1998 prints as `02011998`, which a MMDD reading
        # silently turns into 1 February and which then matches almost nothing.
        # It is retained below purely as a cross-check on the DOY key.
        doy = float(values[names.index("DOY")])
        key = int(round(doy * 24.0))
        date = values[names.index("DATE")]
        calendar[key] = (int(date[4:8]), int(date[2:4]), int(date[0:2]),
                         int(float(values[names.index("HOUR")])))
        record = {}
        for name, raw in zip(names, values):
            if name in ("DOY", "DATE", "HOUR"):
                continue
            try:
                record[name] = float(raw.replace("E+0", "E+").replace("E-0", "E-"))
            except ValueError:
                record[name] = math.nan
        if key in rows:
            duplicates.append(key)
        rows[key] = record
        if max_rows and len(rows) >= max_rows:
            break
    return names, rows, duplicates, calendar


def parse_candidate(path: Path, max_rows: int | None):
    """ecosys-ng stream: tab-separated, hour is 0-based for the same instant."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines:
        raise SystemExit(f"empty candidate file: {path}")
    names = lines[0].split("\t")
    index = {n: i for i, n in enumerate(names)}
    calendar = {}
    for required in ("year", "day_of_year", "month", "day", "hour"):
        if required not in index:
            raise SystemExit(f"{path}: candidate header lacks '{required}'")
    rows = {}
    duplicates = []
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != len(names):
            continue
        # +1 converts the candidate's 0-based hour to the legacy 1-based hour.
        # Same cumulative 1-based hour-of-year as the oracle key. The candidate
        # hour is 0-based for the instant the oracle labels 1-based, so the +1
        # is a convention shift, not an off-by-one.
        key = (int(float(fields[index["day_of_year"]])) - 1) * 24 + int(float(fields[index["hour"]])) + 1
        calendar[key] = (
            int(float(fields[index["year"]])),
            int(float(fields[index["month"]])),
            int(float(fields[index["day"]])),
            int(float(fields[index["hour"]])) + 1,
        )
        record = {}
        for name, raw in zip(names, fields):
            if name in ("year", "day_of_year", "month", "day", "hour"):
                continue
            try:
                record[name] = float(raw)
            except ValueError:
                record[name] = math.nan
        if key in rows:
            duplicates.append(key)
        rows[key] = record
        if max_rows and len(rows) >= max_rows:
            break
    return names, rows, duplicates, calendar


def resolve(candidate_names, prefix):
    """Candidate headings carry a '[units]' suffix; match on the bare prefix."""
    for name in candidate_names:
        if name == prefix or name.startswith(prefix + "["):
            return name
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--stream", default="carbon_hourly", choices=sorted(STREAM_MAPS))
    ap.add_argument("--atol", type=float, default=1e-12)
    ap.add_argument("--rtol", type=float, default=1e-6)
    ap.add_argument("--max-rows", type=int, default=None)
    ap.add_argument("--json")
    args = ap.parse_args()

    oracle_path, candidate_path = Path(args.oracle), Path(args.candidate)
    onames, orows, odup, ocal = parse_oracle(oracle_path, args.max_rows)
    cnames, crows, cdup, ccal = parse_candidate(candidate_path, args.max_rows)

    mapping = STREAM_MAPS[args.stream]
    exclusions = ACCOUNTED_EXCLUSIONS.get(args.stream, {})

    shared = sorted(set(orows) & set(crows))
    # Validate the DOY-derived key rather than trusting it: the independently
    # printed calendar fields on both sides must agree for every matched key.
    calendar_mismatches = []
    for key in shared:
        if ocal.get(key) != ccal.get(key):
            calendar_mismatches.append({"key": key, "oracle": ocal.get(key), "candidate": ccal.get(key)})
    oracle_only = sorted(set(orows) - set(crows))
    candidate_only = sorted(set(crows) - set(orows))

    oracle_data_cols = [n for n in onames if n not in ("DOY", "DATE", "HOUR")]
    results, unmapped, excluded = [], [], []
    for col in oracle_data_cols:
        if col in exclusions:
            excluded.append({"column": col, "reason": exclusions[col]})
            continue
        prefix = mapping.get(col)
        target = resolve(cnames, prefix) if prefix else None
        if target is None:
            unmapped.append(col)
            continue
        n = 0
        max_abs, max_key = 0.0, None
        total_abs = total_sq = total_signed = 0.0
        exceed = 0
        first_exceed = None
        for key in shared:
            a, b = orows[key].get(col), crows[key].get(target)
            if a is None or b is None or math.isnan(a) or math.isnan(b):
                continue
            n += 1
            err = b - a
            abs_err = abs(err)
            total_abs += abs_err
            total_sq += err * err
            total_signed += err
            if abs_err > max_abs:
                max_abs, max_key = abs_err, key
            if abs_err > args.atol + args.rtol * abs(a):
                exceed += 1
                if first_exceed is None:
                    first_exceed = {"key": key, "oracle": a, "candidate": b, "abs_error": abs_err}
        results.append({
            "oracle_column": col,
            "candidate_column": target,
            "pairs": n,
            "max_abs_error": max_abs,
            "max_abs_error_key": max_key,
            "mae": (total_abs / n) if n else None,
            "rmse": math.sqrt(total_sq / n) if n else None,
            "bias": (total_signed / n) if n else None,
            "exceedances": exceed,
            "exceedance_fraction": (exceed / n) if n else None,
            "first_exceedance": first_exceed,
        })

    report = {
        "oracle_file": str(oracle_path),
        "candidate_file": str(candidate_path),
        "stream": args.stream,
        "rule": f"abs(candidate-oracle) <= {args.atol} + {args.rtol}*abs(oracle)",
        "oracle_rows": len(orows),
        "candidate_rows": len(crows),
        "matched_keys": len(shared),
        "oracle_only_keys": len(oracle_only),
        "candidate_only_keys": len(candidate_only),
        "first_matched_key": shared[0] if shared else None,
        "last_matched_key": shared[-1] if shared else None,
        "calendar_mismatches": len(calendar_mismatches),
        "calendar_mismatch_examples": calendar_mismatches[:5],
        "duplicate_oracle_keys": len(odup),
        "duplicate_candidate_keys": len(cdup),
        "columns": results,
        "accounted_exclusions": excluded,
        "unmapped_oracle_columns": unmapped,
        "completion_proof": "ABSENT on both sides; see limitations",
        "limitations": LIMITATIONS,
    }

    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"oracle    : {oracle_path}  rows={len(orows)}")
    print(f"candidate : {candidate_path}  rows={len(crows)}")
    print(f"rule      : {report['rule']}")
    print(f"keys      : matched={len(shared)} oracle_only={len(oracle_only)} candidate_only={len(candidate_only)}")
    if shared:
        print(f"            first_hour={shared[0]} last_hour={shared[-1]}  (cumulative hour of year, 1-based)")
        print(f"            calendar cross-check: {len(shared) - len(calendar_mismatches)}/{len(shared)} agree"
              + (f"  MISMATCHES={len(calendar_mismatches)}" if calendar_mismatches else ""))
        for m in calendar_mismatches[:3]:
            print(f"              key={m['key']} oracle={m['oracle']} candidate={m['candidate']}")
    if odup or cdup:
        print(f"DUPLICATE KEYS: oracle={len(odup)} candidate={len(cdup)}")
    print()
    header = f"{'column':<34}{'pairs':>7}{'max_abs_err':>14}{'MAE':>13}{'RMSE':>13}{'bias':>13}{'exceed':>8}"
    print(header)
    print("-" * len(header))
    for r in results:
        print(f"{r['oracle_column']:<34}{r['pairs']:>7}{r['max_abs_error']:>14.6e}"
              f"{(r['mae'] or 0):>13.5e}{(r['rmse'] or 0):>13.5e}{(r['bias'] or 0):>13.5e}"
              f"{r['exceedances']:>8}")
    for r in results:
        if r["first_exceedance"]:
            fe = r["first_exceedance"]
            print(f"\nfirst exceedance, {r['oracle_column']}: key={fe['key']} "
                  f"oracle={fe['oracle']:.8e} candidate={fe['candidate']:.8e} abs_err={fe['abs_error']:.3e}")
            break
    if excluded:
        print("\naccounted-for exclusions (reported, never passed):")
        for e in excluded:
            print(f"  {e['column']}: {e['reason']}")
    if unmapped:
        print(f"\nUNMAPPED oracle columns (no candidate counterpart, no recorded reason): {', '.join(unmapped)}")
    print("\ncompletion proof: ABSENT on both sides.")
    print("limitations (report these with every number above):")
    for item in LIMITATIONS:
        print(f"  - {item}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
