const std = @import("std");

pub const ChargeClassTotals = struct {
    trivalent_cations_mol: f64,
    trivalent_anions_mol: f64,
    divalent_cations_mol: f64,
    divalent_anions_mol: f64,
    monovalent_cations_mol: f64,
    monovalent_anions_mol: f64,
    neutral_solutes_mol: f64,
};

pub const Result = struct {
    ionic_strength_mol_per_l: f64,
    monovalent_activity_coefficient: f64,
    divalent_activity_coefficient: f64,
    trivalent_activity_coefficient: f64,
    total_ion_activity_mol_per_m3: f64,
    electrical_conductivity_dS_per_m: f64,
};

/// Extended Debye-Huckel calculation used by HOUR1.F for both soil and litter.
pub fn calculate(totals: ChargeClassTotals, water_volume_m3: f64) !Result {
    var profile_scope = @import("reaction_diagnostic_control.zig").beginPhase(.activity_coefficients);
    defer profile_scope.end();
    inline for (@typeInfo(ChargeClassTotals).@"struct".fields) |field| {
        const value = @field(totals, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidChargeClassTotal;
    }
    if (!std.math.isFinite(water_volume_m3) or water_volume_m3 < 0) return error.InvalidWaterVolume;
    if (water_volume_m3 == 0) return .{
        .ionic_strength_mol_per_l = 0,
        .monovalent_activity_coefficient = 1,
        .divalent_activity_coefficient = 1,
        .trivalent_activity_coefficient = 1,
        .total_ion_activity_mol_per_m3 = 0,
        .electrical_conductivity_dS_per_m = 0,
    };
    const tri = totals.trivalent_cations_mol + totals.trivalent_anions_mol;
    const di = totals.divalent_cations_mol + totals.divalent_anions_mol;
    const mono = totals.monovalent_cations_mol + totals.monovalent_anions_mol;
    const ionic_strength = @max(0.0, 0.5e-3 * (9 * tri + 4 * di + mono) / water_volume_m3);
    const root = @sqrt(ionic_strength);
    const extended_term = root / (1 + root) - 0.20 * ionic_strength;
    const monovalent = @min(1.0, std.math.pow(f64, 10, -0.509 * extended_term));
    const divalent = @min(1.0, std.math.pow(f64, 10, -0.509 * 4 * extended_term));
    const trivalent = @min(1.0, std.math.pow(f64, 10, -0.509 * 9 * extended_term));
    const total_activity = @max(0.0, (tri * trivalent + di * divalent + mono * monovalent + totals.neutral_solutes_mol) / water_volume_m3);
    const conductivity = 0.06 * (3 * tri + 2 * di + mono) / water_volume_m3;
    if (!std.math.isFinite(monovalent) or !std.math.isFinite(divalent) or !std.math.isFinite(trivalent) or !std.math.isFinite(total_activity) or !std.math.isFinite(conductivity)) return error.NonFiniteActivityCoefficient;
    return .{
        .ionic_strength_mol_per_l = ionic_strength,
        .monovalent_activity_coefficient = monovalent,
        .divalent_activity_coefficient = divalent,
        .trivalent_activity_coefficient = trivalent,
        .total_ion_activity_mol_per_m3 = total_activity,
        .electrical_conductivity_dS_per_m = conductivity,
    };
}

test "extended Debye-Huckel coefficients match HOUR1 equations" {
    const totals = ChargeClassTotals{ .trivalent_cations_mol = 0.01, .trivalent_anions_mol = 0.02, .divalent_cations_mol = 0.03, .divalent_anions_mol = 0.04, .monovalent_cations_mol = 0.05, .monovalent_anions_mol = 0.06, .neutral_solutes_mol = 0.07 };
    const result = try calculate(totals, 0.5);
    const expected_strength = 0.5e-3 * (9 * 0.03 + 4 * 0.07 + 0.11) / 0.5;
    const root = @sqrt(expected_strength);
    const term = root / (1 + root) - 0.2 * expected_strength;
    try std.testing.expectApproxEqAbs(expected_strength, result.ionic_strength_mol_per_l, 1e-15);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, 10, -0.509 * term), result.monovalent_activity_coefficient, 1e-15);
    try std.testing.expect(result.trivalent_activity_coefficient < result.divalent_activity_coefficient);
    try std.testing.expect(result.divalent_activity_coefficient < result.monovalent_activity_coefficient);
}

test "dry chemistry has unit coefficients and zero activity" {
    const result = try calculate(.{ .trivalent_cations_mol = 0, .trivalent_anions_mol = 0, .divalent_cations_mol = 0, .divalent_anions_mol = 0, .monovalent_cations_mol = 0, .monovalent_anions_mol = 0, .neutral_solutes_mol = 0 }, 0);
    try std.testing.expectEqual(@as(f64, 1), result.monovalent_activity_coefficient);
    try std.testing.expectEqual(@as(f64, 0), result.total_ion_activity_mol_per_m3);
}
