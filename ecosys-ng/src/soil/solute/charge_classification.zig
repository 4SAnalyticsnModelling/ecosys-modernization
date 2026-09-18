const std = @import("std");
const activity = @import("activity_coefficients.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");

pub const ZoneFractions = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    nitrate_non_band: f64,
    nitrate_band: f64,
    phosphate_non_band: f64,
    phosphate_band: f64,
};

/// Maps runtime chemistry concentrations into the exact charge classes used in
/// HOUR1.F. Returned values are mol/m3; pass a reference water volume of 1 m3
/// to `solute_activity_coefficients.calculate`.
pub fn classify(aqueous: aqueous_network.State, non_band: phosphate_network.State, band: phosphate_network.State, fractions: ZoneFractions) !activity.ChargeClassTotals {
    try validate(aqueous, non_band, band, fractions);
    const p0 = weighted(non_band.dissolved_po4_mol_p_per_m3, band.dissolved_po4_mol_p_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const p1 = weighted(non_band.dissolved_hpo4_mol_p_per_m3, band.dissolved_hpo4_mol_p_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const p2 = weighted(non_band.dissolved_h2po4_mol_p_per_m3, band.dissolved_h2po4_mol_p_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const fe_hpo4 = weighted(non_band.iron_hpo4_pair_mol_per_m3, band.iron_hpo4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const fe_h2po4 = weighted(non_band.iron_h2po4_pair_mol_per_m3, band.iron_h2po4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const ca_po4 = weighted(non_band.calcium_po4_pair_mol_per_m3, band.calcium_po4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const ca_hpo4 = weighted(non_band.calcium_hpo4_pair_mol_per_m3, band.calcium_hpo4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const ca_h2po4 = weighted(non_band.calcium_h2po4_pair_mol_per_m3, band.calcium_h2po4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const megagrams_hpo4 = weighted(non_band.magnesium_hpo4_pair_mol_per_m3, band.magnesium_hpo4_pair_mol_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    const h3po4 = weighted(non_band.dissolved_h3po4_mol_p_per_m3, band.dissolved_h3po4_mol_p_per_m3, fractions.phosphate_non_band, fractions.phosphate_band);
    return .{
        .trivalent_cations_mol = aqueous.aluminum + aqueous.iron,
        .trivalent_anions_mol = p0,
        .divalent_cations_mol = aqueous.calcium + aqueous.magnesium + aqueous.aluminum_hydroxide_1 + aqueous.iron_hydroxide_1 + fe_h2po4,
        .divalent_anions_mol = aqueous.sulfate + aqueous.carbonate + p1,
        .monovalent_cations_mol = aqueous.ammonium_non_band * fractions.ammonium_non_band + aqueous.ammonium_band * fractions.ammonium_band + aqueous.hydrogen + aqueous.sodium + aqueous.potassium + aqueous.aluminum_hydroxide_2 + aqueous.iron_hydroxide_2 + aqueous.aluminum_sulfate + aqueous.iron_sulfate + aqueous.calcium_hydroxide + aqueous.calcium_bicarbonate + aqueous.magnesium_hydroxide + aqueous.magnesium_bicarbonate + fe_hpo4 + ca_h2po4,
        .monovalent_anions_mol = aqueous.nitrate_non_band * fractions.nitrate_non_band + aqueous.nitrate_band * fractions.nitrate_band + aqueous.hydroxide + aqueous.bicarbonate + aqueous.chloride + aqueous.aluminum_hydroxide_4 + aqueous.iron_hydroxide_4 + aqueous.sodium_carbonate + aqueous.sodium_sulfate + aqueous.potassium_sulfate + p2 + ca_po4,
        .neutral_solutes_mol = aqueous.aluminum_hydroxide_3 + aqueous.iron_hydroxide_3 + aqueous.calcium_carbonate + aqueous.calcium_sulfate + aqueous.magnesium_carbonate + aqueous.magnesium_sulfate + h3po4 + ca_hpo4 + megagrams_hpo4,
    };
}

fn weighted(non_band: f64, band: f64, non_band_fraction: f64, band_fraction: f64) f64 {
    return non_band * non_band_fraction + band * band_fraction;
}

fn validate(aqueous: aqueous_network.State, non_band: phosphate_network.State, band: phosphate_network.State, fractions: ZoneFractions) !void {
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| if (!std.math.isFinite(@field(aqueous, field.name)) or @field(aqueous, field.name) < 0) return error.InvalidAqueousChargeState;
    inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(non_band, field.name)) or @field(non_band, field.name) < 0 or !std.math.isFinite(@field(band, field.name)) or @field(band, field.name) < 0) return error.InvalidPhosphateChargeState;
    }
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidChargeZoneFraction;
    }
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

test "charge classifier applies runtime band fractions" {
    var aqueous = filled(aqueous_network.State, 0);
    var non_band = filled(phosphate_network.State, 0);
    var band = filled(phosphate_network.State, 0);
    aqueous.aluminum = 1;
    aqueous.ammonium_non_band = 2;
    aqueous.ammonium_band = 4;
    non_band.dissolved_hpo4_mol_p_per_m3 = 3;
    band.dissolved_hpo4_mol_p_per_m3 = 5;
    const totals = try classify(aqueous, non_band, band, .{ .ammonium_non_band = 0.75, .ammonium_band = 0.25, .nitrate_non_band = 0.65, .nitrate_band = 0.35, .phosphate_non_band = 0.6, .phosphate_band = 0.4 });
    try std.testing.expectApproxEqAbs(@as(f64, 1), totals.trivalent_cations_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), totals.monovalent_cations_mol, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.8), totals.divalent_anions_mol, 1e-15);
}
