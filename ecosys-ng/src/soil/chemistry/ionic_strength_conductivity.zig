//! **A5 DISPOSITION: never production bound.**
//!
//! Legacy source: `ecosys_f77/hour1.f` lines 4013--4078. This module is an exact,
//! tested, source-order translation of that range and is imported only by
//! `src/module_index.zig`, so it is reachable by `zig build test` and unreachable
//! from `executeHourlyScience`. That is intentional and must stay that way.
//!
//! Classification: architecturally superseded. Production stores the same physics in a
//! different representation, deliberately, with the deviation recorded in
//! `docs/model_changes.md`. Binding this kernel would reintroduce the
//! formulation the project chose to leave behind, as a second writer.
//!
//! Superseded by: `solute_activity_coefficients` / `solute_ion_activities`, reached through `solute_chemistry_state.activityCoefficients`, which production already calls at `ecosys_ng.zig:7823`.
//!
//! The legacy form is a three-charge Debye-Huckel shortcut over a fixed
//! species list. The solute activity network resolves activities over the full
//! runtime species set, so binding this would publish a second, coarser set of
//! activity coefficients into state the network already owns.
//!
//! Do not bind this module, and do not delete it: the tests are a source-order
//! comparison oracle for the range above. Full argument and the census behind
//! it: `docs/traceability/hour1_2039_5200_binding_survey.md`.
const std = @import("std");

/// Each slice is ordered exactly as the corresponding HOUR1 expression in
/// lines 4014-4031. Amounts are mol except the explicitly named g N/P slices.
pub const ChargeInputs = struct {
    trivalent_cations_mol: []const f64, // ZAL, ZFE
    trivalent_anions_mol: []const f64, // H0PO4, H0POB
    divalent_cations_mol: []const f64, // ZCA..ZFE2PB
    divalent_anions_mol: []const f64, // ZSO4, ZCO3
    divalent_anion_phosphorus_g_p: []const f64, // H1PO4, H1POB
    monovalent_cation_nitrogen_g_n: []const f64, // ZNH4S, ZNH4B
    monovalent_cations_mol: []const f64, // ZHY..ZCA2PB
    monovalent_anion_nitrogen_g_n: []const f64, // ZNO3S, ZNO3B
    monovalent_anions_mol: []const f64, // ZOH..ZKAS
    monovalent_anion_phosphorus_g_p: []const f64, // H2PO4, H2POB
    monovalent_calcium_phosphates_mol: []const f64, // ZCA0P, ZCA0PB
    neutral_species_mol: []const f64, // ZALOH3..ZMG1PB
};

pub const ActivityCoefficients = struct {
    monovalent: f64,
    divalent: f64,
    trivalent: f64,
};

pub const Result = struct {
    ionic_strength: f64,
    activity_expression: f64,
    activity_coefficients: ActivityCoefficients,
    total_ion_activity_mol_m3: f64,
    electrical_conductivity_ds_m: f64,
};

pub const CalculationError = error{
    DimensionMismatch,
    NonFiniteInput,
    NegativeInput,
    InvalidWaterVolume,
    NonFiniteResult,
};

/// Translates `hour1.f` lines 4013--4078.
pub fn calculate(
    water_volume_m3: f64,
    water_volume_threshold_m3: f64,
    inputs: ChargeInputs,
) CalculationError!Result {
    if (!std.math.isFinite(water_volume_m3) or
        !std.math.isFinite(water_volume_threshold_m3))
    {
        return error.NonFiniteInput;
    }
    if (water_volume_m3 < 0.0 or water_volume_threshold_m3 < 0.0) {
        return error.InvalidWaterVolume;
    }
    try validateDimensions(inputs);
    inline for (std.meta.fields(ChargeInputs)) |field| {
        for (@field(inputs, field.name)) |amount| {
            if (!std.math.isFinite(amount)) return error.NonFiniteInput;
            if (amount < 0.0) return error.NegativeInput;
        }
    }
    if (water_volume_m3 <= water_volume_threshold_m3) {
        return .{
            .ionic_strength = 0.0,
            .activity_expression = 0.0,
            .activity_coefficients = .{
                .monovalent = 1.0,
                .divalent = 1.0,
                .trivalent = 1.0,
            },
            .total_ion_activity_mol_m3 = 0.0,
            .electrical_conductivity_ds_m = 0.0,
        };
    }

    const trivalent_cations_mol = orderedSum(inputs.trivalent_cations_mol);
    const trivalent_anions_mol = orderedSum(inputs.trivalent_anions_mol);
    const divalent_cations_mol = orderedSum(inputs.divalent_cations_mol);
    var divalent_anions_mol = orderedSum(inputs.divalent_anions_mol);
    divalent_anions_mol = divalent_anions_mol +
        orderedSum(inputs.divalent_anion_phosphorus_g_p) / 31.0;
    var monovalent_cations_mol =
        orderedSum(inputs.monovalent_cation_nitrogen_g_n) / 14.0;
    monovalent_cations_mol =
        monovalent_cations_mol + orderedSum(inputs.monovalent_cations_mol);
    var monovalent_anions_mol =
        orderedSum(inputs.monovalent_anion_nitrogen_g_n) / 14.0;
    monovalent_anions_mol =
        monovalent_anions_mol + orderedSum(inputs.monovalent_anions_mol);
    monovalent_anions_mol = monovalent_anions_mol +
        orderedSum(inputs.monovalent_anion_phosphorus_g_p) / 31.0;
    monovalent_anions_mol = monovalent_anions_mol +
        orderedSum(inputs.monovalent_calcium_phosphates_mol);
    const neutral_species_mol = orderedSum(inputs.neutral_species_mol);

    const ionic_strength = @max(
        0.0,
        0.5e-3 *
            (9.0 * (trivalent_cations_mol + trivalent_anions_mol) +
                4.0 * (divalent_cations_mol + divalent_anions_mol) +
                monovalent_cations_mol +
                monovalent_anions_mol) /
            water_volume_m3,
    );
    const ionic_strength_root = @sqrt(ionic_strength);
    const activity_expression =
        ionic_strength_root / (1.0 + ionic_strength_root) - 0.20 * ionic_strength;
    const coefficients = ActivityCoefficients{
        .monovalent = @min(
            1.0,
            std.math.pow(f64, 10.0, -0.509 * 1.0 * activity_expression),
        ),
        .divalent = @min(
            1.0,
            std.math.pow(f64, 10.0, -0.509 * 4.0 * activity_expression),
        ),
        .trivalent = @min(
            1.0,
            std.math.pow(f64, 10.0, -0.509 * 9.0 * activity_expression),
        ),
    };
    const total_ion_activity_mol_m3 = @max(
        0.0,
        ((trivalent_cations_mol + trivalent_anions_mol) * coefficients.trivalent +
            (divalent_cations_mol + divalent_anions_mol) * coefficients.divalent +
            (monovalent_cations_mol + monovalent_anions_mol) * coefficients.monovalent +
            neutral_species_mol) /
            water_volume_m3,
    );
    const electrical_conductivity_ds_m = 0.06 *
        (3.0 * (trivalent_cations_mol + trivalent_anions_mol) +
            2.0 * (divalent_cations_mol + divalent_anions_mol) +
            monovalent_cations_mol +
            monovalent_anions_mol) /
        water_volume_m3;

    const result = Result{
        .ionic_strength = ionic_strength,
        .activity_expression = activity_expression,
        .activity_coefficients = coefficients,
        .total_ion_activity_mol_m3 = total_ion_activity_mol_m3,
        .electrical_conductivity_ds_m = electrical_conductivity_ds_m,
    };
    if (!std.math.isFinite(result.ionic_strength) or
        !std.math.isFinite(result.activity_expression) or
        !std.math.isFinite(result.total_ion_activity_mol_m3) or
        !std.math.isFinite(result.electrical_conductivity_ds_m) or
        !std.math.isFinite(coefficients.monovalent) or
        !std.math.isFinite(coefficients.divalent) or
        !std.math.isFinite(coefficients.trivalent))
    {
        return error.NonFiniteResult;
    }
    return result;
}

fn validateDimensions(inputs: ChargeInputs) CalculationError!void {
    if (inputs.trivalent_cations_mol.len != 2 or
        inputs.trivalent_anions_mol.len != 2 or
        inputs.divalent_cations_mol.len != 6 or
        inputs.divalent_anions_mol.len != 2 or
        inputs.divalent_anion_phosphorus_g_p.len != 2 or
        inputs.monovalent_cation_nitrogen_g_n.len != 2 or
        inputs.monovalent_cations_mol.len != 15 or
        inputs.monovalent_anion_nitrogen_g_n.len != 2 or
        inputs.monovalent_anions_mol.len != 8 or
        inputs.monovalent_anion_phosphorus_g_p.len != 2 or
        inputs.monovalent_calcium_phosphates_mol.len != 2 or
        inputs.neutral_species_mol.len != 12)
    {
        return error.DimensionMismatch;
    }
}

fn orderedSum(values: []const f64) f64 {
    var total: f64 = 0.0;
    for (values) |value| total = total + value;
    return total;
}

test "monovalent ions determine strength activity and conductivity" {
    const zeros2 = [_]f64{ 0.0, 0.0 };
    const zeros6 = [_]f64{0.0} ** 6;
    const zeros8 = [_]f64{0.0} ** 8;
    const zeros12 = [_]f64{0.0} ** 12;
    var cations15 = [_]f64{0.0} ** 15;
    cations15[0] = 1.0;
    var anions8 = zeros8;
    anions8[0] = 1.0;
    const result = try calculate(1.0, 0.0, .{
        .trivalent_cations_mol = &zeros2,
        .trivalent_anions_mol = &zeros2,
        .divalent_cations_mol = &zeros6,
        .divalent_anions_mol = &zeros2,
        .divalent_anion_phosphorus_g_p = &zeros2,
        .monovalent_cation_nitrogen_g_n = &zeros2,
        .monovalent_cations_mol = &cations15,
        .monovalent_anion_nitrogen_g_n = &zeros2,
        .monovalent_anions_mol = &anions8,
        .monovalent_anion_phosphorus_g_p = &zeros2,
        .monovalent_calcium_phosphates_mol = &zeros2,
        .neutral_species_mol = &zeros12,
    });
    try std.testing.expectEqual(@as(f64, 0.001), result.ionic_strength);
    try std.testing.expectEqual(@as(f64, 0.12), result.electrical_conductivity_ds_m);
}

test "dry layer uses unit activity coefficients" {
    const zeros2 = [_]f64{ 0.0, 0.0 };
    const zeros6 = [_]f64{0.0} ** 6;
    const zeros8 = [_]f64{0.0} ** 8;
    const zeros12 = [_]f64{0.0} ** 12;
    const zeros15 = [_]f64{0.0} ** 15;
    const result = try calculate(0.0, 0.0, .{
        .trivalent_cations_mol = &zeros2,
        .trivalent_anions_mol = &zeros2,
        .divalent_cations_mol = &zeros6,
        .divalent_anions_mol = &zeros2,
        .divalent_anion_phosphorus_g_p = &zeros2,
        .monovalent_cation_nitrogen_g_n = &zeros2,
        .monovalent_cations_mol = &zeros15,
        .monovalent_anion_nitrogen_g_n = &zeros2,
        .monovalent_anions_mol = &zeros8,
        .monovalent_anion_phosphorus_g_p = &zeros2,
        .monovalent_calcium_phosphates_mol = &zeros2,
        .neutral_species_mol = &zeros12,
    });
    try std.testing.expectEqual(@as(f64, 1.0), result.activity_coefficients.monovalent);
    try std.testing.expectEqual(@as(f64, 0.0), result.electrical_conductivity_ds_m);
}
