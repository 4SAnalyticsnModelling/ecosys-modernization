const std = @import("std");

pub const ErosionInputs = struct {
    net_sediment_megagrams: f64,
    snow_deposited_sediment_megagrams: f64,
    horizontal_area_m2: f64,
    surface_soil_mass_megagrams: f64,
    surface_soil_volume_m3: f64,
    receiving_soil_bulk_density_megagrams_per_m3: f64,
};

/// REDIST DDLYXE. Positive sediment deposition raises cumulative profile
/// boundaries; negative net sediment erosion lowers them.
pub fn erosionDepthChange_m(inputs: ErosionInputs) !f64 {
    try validateFinite(ErosionInputs, inputs);
    if (inputs.horizontal_area_m2 <= 0 or inputs.surface_soil_mass_megagrams <= 0 or inputs.surface_soil_volume_m3 <= 0 or inputs.receiving_soil_bulk_density_megagrams_per_m3 <= 0 or inputs.snow_deposited_sediment_megagrams < 0) return error.InvalidErosionDepthInput;
    const current_bulk_density_megagrams_per_m3 = inputs.surface_soil_mass_megagrams / inputs.surface_soil_volume_m3;
    const eroded_soil_change_m = inputs.net_sediment_megagrams / (inputs.horizontal_area_m2 * current_bulk_density_megagrams_per_m3);
    const snow_sediment_change_m = inputs.snow_deposited_sediment_megagrams / (inputs.horizontal_area_m2 * inputs.receiving_soil_bulk_density_megagrams_per_m3);
    const result = eroded_soil_change_m + snow_sediment_change_m;
    if (!std.math.isFinite(result)) return error.NonFiniteSoilDepthChange;
    return result;
}

pub const OrganicCarbonInputs = struct {
    organic_carbon_change_g: f64,
    horizontal_area_m2: f64,
    macropore_fraction: f64,
    reference_bulk_density_megagrams_per_m3: f64,
    organic_carbon_specific_volume_m3_per_g: f64,
};

/// REDIST DDLYXC. The Fortran coefficient 1.82E-06 is supplied at runtime as
/// organic_carbon_specific_volume_m3_per_g rather than hidden in parameters.h.
pub fn organicCarbonDepthChange_m(inputs: OrganicCarbonInputs) !f64 {
    try validateFinite(OrganicCarbonInputs, inputs);
    if (inputs.horizontal_area_m2 <= 0 or inputs.macropore_fraction < 0 or inputs.macropore_fraction >= 1 or inputs.reference_bulk_density_megagrams_per_m3 <= 0 or inputs.organic_carbon_specific_volume_m3_per_g <= 0) return error.InvalidOrganicCarbonDepthInput;
    const result = inputs.organic_carbon_specific_volume_m3_per_g * inputs.organic_carbon_change_g / inputs.horizontal_area_m2 / ((1 - inputs.macropore_fraction) * inputs.reference_bulk_density_megagrams_per_m3);
    if (!std.math.isFinite(result)) return error.NonFiniteSoilDepthChange;
    return result;
}

pub const FreezeThawInputs = struct {
    soil_ice_volume_change_m3: f64,
    ice_to_water_specific_volume_difference: f64,
    soil_matrix_fraction: f64,
    horizontal_area_m2: f64,
};

/// REDIST DDLYXF. `ice_to_water_specific_volume_difference` is DENSJ from the
/// runtime physical-property configuration.
pub fn freezeThawDepthChange_m(inputs: FreezeThawInputs) !f64 {
    try validateFinite(FreezeThawInputs, inputs);
    if (inputs.ice_to_water_specific_volume_difference < 0 or inputs.soil_matrix_fraction <= 0 or inputs.soil_matrix_fraction > 1 or inputs.horizontal_area_m2 <= 0) return error.InvalidFreezeThawDepthInput;
    const result = inputs.soil_ice_volume_change_m3 * inputs.ice_to_water_specific_volume_difference / (inputs.soil_matrix_fraction * inputs.horizontal_area_m2);
    if (!std.math.isFinite(result)) return error.NonFiniteSoilDepthChange;
    return result;
}

fn validateFinite(comptime T: type, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| if (!std.math.isFinite(@field(value, field.name))) return error.NonFiniteSoilDepthInput;
}

test "erosion depth uses current surface bulk density and preserves sign" {
    const deposition = try erosionDepthChange_m(.{ .net_sediment_megagrams = 2, .snow_deposited_sediment_megagrams = 0, .horizontal_area_m2 = 10, .surface_soil_mass_megagrams = 20, .surface_soil_volume_m3 = 10, .receiving_soil_bulk_density_megagrams_per_m3 = 1.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), deposition, 1e-14);
    const erosion = try erosionDepthChange_m(.{ .net_sediment_megagrams = -2, .snow_deposited_sediment_megagrams = 0, .horizontal_area_m2 = 10, .surface_soil_mass_megagrams = 20, .surface_soil_volume_m3 = 10, .receiving_soil_bulk_density_megagrams_per_m3 = 1.5 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), erosion, 1e-14);
}

test "organic carbon and freeze thaw depth equations preserve REDIST factors" {
    const carbon = try organicCarbonDepthChange_m(.{ .organic_carbon_change_g = 1000, .horizontal_area_m2 = 10, .macropore_fraction = 0.1, .reference_bulk_density_megagrams_per_m3 = 1.2, .organic_carbon_specific_volume_m3_per_g = 1.82e-6 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.82e-3) / 10.0 / 1.08, carbon, 1e-16);
    const freeze = try freezeThawDepthChange_m(.{ .soil_ice_volume_change_m3 = 1, .ice_to_water_specific_volume_difference = 0.083, .soil_matrix_fraction = 0.8, .horizontal_area_m2 = 10 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.083) / 8.0, freeze, 1e-16);
}
