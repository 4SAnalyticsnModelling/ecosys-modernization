const std = @import("std");
const initialization = @import("../soil/chemistry/initialization.zig");
const aqueous_rates = @import("../soil/solute/aqueous_reaction_rates.zig");
const phosphate_rates = @import("../soil/solute/phosphate_reaction_rates.zig");

pub const Inputs = struct {
    ph: f64,
    ammonium_g_n_per_m3: f64,
    nitrate_g_n_per_m3: f64,
    phosphate_g_p_per_m3: f64,
    nitrogen_g_per_mol: f64 = 14,
    phosphorus_g_per_mol: f64 = 31,
};

/// STARTE K=1 initial `CN41/CN31/CH1P1/CH2P1` speciation. The returned
/// order is NH4-N, NH3-N, NO3-N, HPO4-P, H2PO4-P in mol m-3.
pub fn calculate(inputs: Inputs, aqueous: aqueous_rates.EquilibriumConstants, phosphate: phosphate_rates.EquilibriumConstants) ![5]f64 {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0) return error.InvalidPrecipitationNutrientInput;
    if (inputs.ph > 14 or inputs.nitrogen_g_per_mol <= 0 or inputs.phosphorus_g_per_mol <= 0 or !std.math.isFinite(aqueous.ammonium) or aqueous.ammonium <= 0) return error.InvalidPrecipitationNutrientInput;
    const hydrogen = try initialization.hydrogenFromPh_mol_per_m3(inputs.ph);
    const total_ammoniacal_n = inputs.ammonium_g_n_per_m3 / inputs.nitrogen_g_per_mol;
    const ammonium = total_ammoniacal_n / (1 + aqueous.ammonium / hydrogen);
    const ammonia = ammonium * aqueous.ammonium / hydrogen;
    const species = try initialization.initialPhosphateSpecies(inputs.phosphate_g_p_per_m3 / inputs.phosphorus_g_per_mol, hydrogen, .{ .h3po4_to_h2po4_mol_per_m3 = phosphate.h3po4, .h2po4_to_hpo4_mol_per_m3 = phosphate.h2po4, .hpo4_to_po4_mol_per_m3 = phosphate.hpo4 });
    const result = [5]f64{ ammonium, ammonia, inputs.nitrate_g_n_per_m3 / inputs.nitrogen_g_per_mol, species.hpo4_mol_p_per_m3, species.h2po4_mol_p_per_m3 };
    for (result) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFinitePrecipitationNutrientSpeciation;
    return result;
}

test "STARTE precipitation initialization conserves ammoniacal N and phosphate P" {
    const aqueous = filled(aqueous_rates.EquilibriumConstants, 1e-3);
    const phosphate = filled(phosphate_rates.EquilibriumConstants, 1e-3);
    const result = try calculate(.{ .ph = 7, .ammonium_g_n_per_m3 = 14, .nitrate_g_n_per_m3 = 28, .phosphate_g_p_per_m3 = 31 }, aqueous, phosphate);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result[0] + result[1], 1e-12);
    try std.testing.expectEqual(@as(f64, 2), result[2]);
    const hydrogen = try initialization.hydrogenFromPh_mol_per_m3(7);
    const all_p = try initialization.initialPhosphateSpecies(1, hydrogen, .{ .h3po4_to_h2po4_mol_per_m3 = phosphate.h3po4, .h2po4_to_hpo4_mol_per_m3 = phosphate.h2po4, .hpo4_to_po4_mol_per_m3 = phosphate.hpo4 });
    try std.testing.expectApproxEqAbs(all_p.hpo4_mol_p_per_m3, result[3], 1e-12);
    try std.testing.expectApproxEqAbs(all_p.h2po4_mol_p_per_m3, result[4], 1e-12);
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}
