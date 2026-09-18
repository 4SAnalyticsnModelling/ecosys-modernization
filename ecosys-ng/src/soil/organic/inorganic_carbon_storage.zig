const std = @import("std");

pub const Inputs = struct {
    carbon_dioxide_and_methane_g_c: f64,
    soil_water_volume_m3: []const f64,
    soil_bulk_volume_m3: []const f64,
    carbonate_mol_per_m3: []const f64,
    bicarbonate_mol_per_m3: []const f64,
    dissolved_carbonate_complexes_mol_per_m3: []const f64,
    calcite_mol_per_m3: []const f64,
    litter_water_volume_m3: f64,
    litter_carbonate_mol_per_m3: f64,
    litter_bicarbonate_mol_per_m3: f64,
    litter_dissolved_carbonate_complexes_mol_per_m3: f64,
    litter_calcite_mol_per_m3: f64,
    /// Independent extensive carrier for solid litter minerals.  This is not
    /// necessarily either live litter water or litter bulk volume.
    litter_mineral_reference_volume_m3: f64,
    carbon_molar_mass_g_per_mol: f64 = 12,
};

/// Exact UCO2S owner: gaseous/dissolved CO2 and CH4 plus aqueous carbonate,
/// bicarbonate, their dissolved ion pairs, and precipitated calcite.
pub fn calculate(inputs: Inputs) !f64 {
    const layer_count = inputs.soil_water_volume_m3.len;
    inline for (.{ inputs.soil_bulk_volume_m3, inputs.carbonate_mol_per_m3, inputs.bicarbonate_mol_per_m3, inputs.dissolved_carbonate_complexes_mol_per_m3, inputs.calcite_mol_per_m3 }) |values|
        if (values.len != layer_count) return error.InorganicCarbonStorageDimensionMismatch;
    inline for (.{ inputs.carbon_dioxide_and_methane_g_c, inputs.litter_water_volume_m3, inputs.litter_carbonate_mol_per_m3, inputs.litter_bicarbonate_mol_per_m3, inputs.litter_dissolved_carbonate_complexes_mol_per_m3, inputs.litter_calcite_mol_per_m3, inputs.litter_mineral_reference_volume_m3, inputs.carbon_molar_mass_g_per_mol }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteInorganicCarbonStorage;
    if (inputs.carbon_dioxide_and_methane_g_c < 0 or inputs.litter_water_volume_m3 < 0 or
        inputs.litter_carbonate_mol_per_m3 < 0 or inputs.litter_bicarbonate_mol_per_m3 < 0 or
        inputs.litter_dissolved_carbonate_complexes_mol_per_m3 < 0 or inputs.litter_calcite_mol_per_m3 < 0 or
        inputs.litter_mineral_reference_volume_m3 < 0 or inputs.carbon_molar_mass_g_per_mol <= 0)
        return error.InvalidInorganicCarbonStorage;
    if (inputs.litter_water_volume_m3 == 0 and
        (inputs.litter_carbonate_mol_per_m3 != 0 or inputs.litter_bicarbonate_mol_per_m3 != 0 or
            inputs.litter_dissolved_carbonate_complexes_mol_per_m3 != 0))
        return error.UnboundLitterAqueousCarbonStorage;
    if (inputs.litter_mineral_reference_volume_m3 == 0 and inputs.litter_calcite_mol_per_m3 != 0)
        return error.UnboundLitterMineralCarbonStorage;

    var carbon_g_c = inputs.carbon_dioxide_and_methane_g_c;
    for (0..layer_count) |layer| {
        inline for (.{ inputs.soil_water_volume_m3[layer], inputs.soil_bulk_volume_m3[layer], inputs.carbonate_mol_per_m3[layer], inputs.bicarbonate_mol_per_m3[layer], inputs.dissolved_carbonate_complexes_mol_per_m3[layer], inputs.calcite_mol_per_m3[layer] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidInorganicCarbonStorage;
        carbon_g_c += inputs.carbon_molar_mass_g_per_mol *
            ((inputs.carbonate_mol_per_m3[layer] + inputs.bicarbonate_mol_per_m3[layer] + inputs.dissolved_carbonate_complexes_mol_per_m3[layer]) * inputs.soil_water_volume_m3[layer] +
                inputs.calcite_mol_per_m3[layer] * inputs.soil_bulk_volume_m3[layer]);
    }
    carbon_g_c += inputs.carbon_molar_mass_g_per_mol *
        ((inputs.litter_carbonate_mol_per_m3 + inputs.litter_bicarbonate_mol_per_m3 + inputs.litter_dissolved_carbonate_complexes_mol_per_m3) * inputs.litter_water_volume_m3 +
            inputs.litter_calcite_mol_per_m3 * inputs.litter_mineral_reference_volume_m3);
    if (!std.math.isFinite(carbon_g_c)) return error.NonFiniteInorganicCarbonStorage;
    return carbon_g_c;
}

test "UCO2S includes runtime layers dissolved ion pairs and calcite without fixed limits" {
    const water = [_]f64{ 2, 3 };
    const bulk = [_]f64{ 4, 5 };
    const carbonate = [_]f64{ 1, 2 };
    const bicarbonate = [_]f64{ 0.5, 1 };
    const complexes = [_]f64{ 0.25, 0.5 };
    const calcite = [_]f64{ 0.1, 0.2 };
    const result = try calculate(.{
        .carbon_dioxide_and_methane_g_c = 7,
        .soil_water_volume_m3 = &water,
        .soil_bulk_volume_m3 = &bulk,
        .carbonate_mol_per_m3 = &carbonate,
        .bicarbonate_mol_per_m3 = &bicarbonate,
        .dissolved_carbonate_complexes_mol_per_m3 = &complexes,
        .calcite_mol_per_m3 = &calcite,
        .litter_water_volume_m3 = 1,
        .litter_carbonate_mol_per_m3 = 0.25,
        .litter_bicarbonate_mol_per_m3 = 0.5,
        .litter_dissolved_carbonate_complexes_mol_per_m3 = 0.25,
        .litter_calcite_mol_per_m3 = 0.5,
        .litter_mineral_reference_volume_m3 = 2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 215.8), result, 1e-12);
}

test "UCO2S dry litter carbon uses independent aqueous and mineral references" {
    const empty: [0]f64 = .{};
    const result = try calculate(.{
        .carbon_dioxide_and_methane_g_c = 0,
        .soil_water_volume_m3 = &empty,
        .soil_bulk_volume_m3 = &empty,
        .carbonate_mol_per_m3 = &empty,
        .bicarbonate_mol_per_m3 = &empty,
        .dissolved_carbonate_complexes_mol_per_m3 = &empty,
        .calcite_mol_per_m3 = &empty,
        .litter_water_volume_m3 = 3,
        .litter_carbonate_mol_per_m3 = 2,
        .litter_bicarbonate_mol_per_m3 = 1,
        .litter_dissolved_carbonate_complexes_mol_per_m3 = 0,
        .litter_calcite_mol_per_m3 = 5,
        .litter_mineral_reference_volume_m3 = 4,
    });
    try std.testing.expectEqual(@as(f64, 12 * (3 * 3 + 5 * 4)), result);
}
