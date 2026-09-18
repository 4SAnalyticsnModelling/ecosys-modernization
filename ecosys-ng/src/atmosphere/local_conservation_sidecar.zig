const std = @import("std");
const hourly = @import("../validation/hourly_cell_conservation.zig");
const inventory = @import("../validation/landscape_mass_inventory.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const snow_discharge = @import("../soil/water/snow_surface_discharge.zig");

/// Accepted atmospheric activity after precipitation, canopy drainage and
/// surface-vapor routing have selected their actual storage owners.  The three
/// external fragments are disjoint.  Canopy drainage is deliberately retained
/// as paired internal transfers and must never be added to an atmospheric
/// boundary ledger.
pub const CellActivity = struct {
    top_snow_external: hourly.BoundaryActivity = .{},
    surface_external: hourly.BoundaryActivity = .{},
    topsoil_external: hourly.BoundaryActivity = .{},
    canopy_to_top_snow: hourly.IntercellTransfer = .{},
    canopy_to_surface: hourly.IntercellTransfer = .{},
    canopy_to_topsoil: hourly.IntercellTransfer = .{},
    /// Diagnostic phase split retained at the producer boundary.  Both are
    /// owned by the same topsoil layer ledger scope.
    external_matrix_water_m3: f64 = 0,
    external_macropore_water_m3: f64 = 0,
    canopy_to_matrix_water_m3: f64 = 0,
    canopy_to_macropore_water_m3: f64 = 0,
};

pub const PrecipitationInputs = struct {
    /// Rain plus surface irrigation before canopy interception.
    liquid_precipitation_m3: f64,
    solid_precipitation_water_equivalent_m3: f64,
    /// Signed producer result: positive is atmosphere -> canopy; negative is
    /// canopy -> the lower precipitation router.
    canopy_retention_m3: f64,
    liquid_to_top_snow_m3: f64,
    liquid_to_surface_litter_m3: f64,
    liquid_to_topsoil_matrix_m3: f64,
    liquid_to_topsoil_macropore_m3: f64,
    atmospheric_temperature_k: f64,
    liquid_heat_capacity_megajoules_per_m3_k: f64,
    solid_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    water_absolute_tolerance_m3: f64,
    relative_tolerance: f64,
};

pub const SurfaceExchangeInputs = struct {
    snow_evaporation_m3: f64 = 0,
    snow_condensation_m3: f64 = 0,
    /// Exact accepted snow-census heat change.  It already contains radiation,
    /// sensible, latent, carrier-sensible and frozen-reference terms.
    snow_boundary_heat_megajoules: f64 = 0,
    litter_evaporation_m3: f64 = 0,
    topsoil_evaporation_m3: f64 = 0,
    litter_condensation_m3: f64 = 0,
    topsoil_condensation_m3: f64 = 0,
    /// Signed atmospheric heat assigned by the accepted surface-energy
    /// producer to the named canonical owner.  Positive is into storage.
    surface_boundary_heat_megajoules: f64 = 0,
    topsoil_boundary_heat_megajoules: f64 = 0,
};

pub const ChemistryInputs = struct {
    top_snow_input_g: [snow.species_count]f64 = [_]f64{0} ** snow.species_count,
    top_snow_input_salt_mol: [snow.salt_species_count]f64 = [_]f64{0} ** snow.salt_species_count,
    direct_surface_and_soil: snow.SurfaceDischarge = .{},
    ion_molar_mass_g_per_mol: snow_discharge.IonMolarMassesGPerMol,
};

pub fn acceptedCellActivity(
    precipitation: PrecipitationInputs,
    exchange: SurfaceExchangeInputs,
    chemistry: ChemistryInputs,
) !CellActivity {
    try validatePrecipitation(precipitation);
    inline for (std.meta.fields(SurfaceExchangeInputs)) |field| {
        const value = @field(exchange, field.name);
        if (!std.math.isFinite(value)) return error.InvalidAtmosphericLocalActivity;
        if (!std.mem.endsWith(u8, field.name, "heat_megajoules") and value < 0)
            return error.InvalidAtmosphericLocalActivity;
    }

    const retained = @max(0, precipitation.canopy_retention_m3);
    const drainage = @max(0, -precipitation.canopy_retention_m3);
    if (retained > precipitation.liquid_precipitation_m3 + precipitation.water_absolute_tolerance_m3)
        return error.CanopyRetentionExceedsPrecipitation;
    const external_below = @max(0, precipitation.liquid_precipitation_m3 - retained);
    const routed_liquid = precipitation.liquid_to_top_snow_m3 +
        precipitation.liquid_to_surface_litter_m3 +
        precipitation.liquid_to_topsoil_matrix_m3 +
        precipitation.liquid_to_topsoil_macropore_m3;
    const expected_routed = external_below + drainage;
    const route_scale = @max(routed_liquid, expected_routed);
    const route_tolerance = precipitation.water_absolute_tolerance_m3 +
        precipitation.relative_tolerance * route_scale +
        32 * std.math.floatEps(f64) * route_scale;
    if (@abs(routed_liquid - expected_routed) > route_tolerance)
        return error.AtmosphericLocalPrecipitationRouteMismatch;

    const external_fraction = if (expected_routed > 0) external_below / expected_routed else 0;
    const drainage_fraction = if (expected_routed > 0) drainage / expected_routed else 0;
    const liquid_heat_per_m3 = precipitation.liquid_heat_capacity_megajoules_per_m3_k *
        precipitation.atmospheric_temperature_k;
    const frozen_heat_per_m3 = try inventory.frozenWaterEnthalpyPerM3(
        precipitation.atmospheric_temperature_k,
        precipitation.liquid_heat_capacity_megajoules_per_m3_k,
        precipitation.solid_heat_capacity_megajoules_per_m3_k,
        precipitation.latent_heat_of_fusion_megajoules_per_m3,
        precipitation.pure_water_melting_temperature_k,
    );

    const snow_external_liquid = precipitation.liquid_to_top_snow_m3 * external_fraction;
    const surface_external_liquid = precipitation.liquid_to_surface_litter_m3 * external_fraction;
    const matrix_external_liquid = precipitation.liquid_to_topsoil_matrix_m3 * external_fraction;
    const macro_external_liquid = precipitation.liquid_to_topsoil_macropore_m3 * external_fraction;
    const snow_drainage = precipitation.liquid_to_top_snow_m3 * drainage_fraction;
    const surface_drainage = precipitation.liquid_to_surface_litter_m3 * drainage_fraction;
    const matrix_drainage = precipitation.liquid_to_topsoil_matrix_m3 * drainage_fraction;
    const macro_drainage = precipitation.liquid_to_topsoil_macropore_m3 * drainage_fraction;

    var result: CellActivity = .{
        .top_snow_external = .{
            .water_input_m3 = precipitation.solid_precipitation_water_equivalent_m3 +
                snow_external_liquid + exchange.snow_condensation_m3,
            .water_output_m3 = exchange.snow_evaporation_m3,
        },
        .surface_external = .{
            .water_input_m3 = surface_external_liquid + exchange.litter_condensation_m3,
            .water_output_m3 = exchange.litter_evaporation_m3,
        },
        .topsoil_external = .{ .water_input_m3 = matrix_external_liquid + macro_external_liquid + exchange.topsoil_condensation_m3, .water_output_m3 = exchange.topsoil_evaporation_m3 },
        .canopy_to_top_snow = .{ .water_m3 = snow_drainage, .heat_megajoules = snow_drainage * liquid_heat_per_m3 },
        .canopy_to_surface = .{ .water_m3 = surface_drainage, .heat_megajoules = surface_drainage * liquid_heat_per_m3 },
        .canopy_to_topsoil = .{ .water_m3 = matrix_drainage + macro_drainage, .heat_megajoules = (matrix_drainage + macro_drainage) * liquid_heat_per_m3 },
        .external_matrix_water_m3 = matrix_external_liquid,
        .external_macropore_water_m3 = macro_external_liquid,
        .canopy_to_matrix_water_m3 = matrix_drainage,
        .canopy_to_macropore_water_m3 = macro_drainage,
    };
    try addSignedHeat(&result.top_snow_external, precipitation.solid_precipitation_water_equivalent_m3 * frozen_heat_per_m3 +
        snow_external_liquid * liquid_heat_per_m3 + exchange.snow_boundary_heat_megajoules);
    try addSignedHeat(&result.surface_external, surface_external_liquid * liquid_heat_per_m3 + exchange.surface_boundary_heat_megajoules);
    try addSignedHeat(&result.topsoil_external, (matrix_external_liquid + macro_external_liquid) * liquid_heat_per_m3 +
        exchange.topsoil_boundary_heat_megajoules);

    const top_snow_direct: snow.SurfaceDischarge = .{};
    const top_snow_g = chemistry.top_snow_input_g;
    const top_snow_salt = chemistry.top_snow_input_salt_mol;
    const top_snow_chemistry = try hourly.atmosphericSoluteActivity(
        0,
        1,
        &top_snow_g,
        &top_snow_salt,
        &.{top_snow_direct},
        chemistry.ion_molar_mass_g_per_mol,
    );
    var surface_direct: snow.SurfaceDischarge = .{};
    surface_direct.litter_g = chemistry.direct_surface_and_soil.litter_g;
    surface_direct.litter_salt_mol = chemistry.direct_surface_and_soil.litter_salt_mol;
    const zero_g = [_]f64{0} ** snow.species_count;
    const zero_salt = [_]f64{0} ** snow.salt_species_count;
    const surface_chemistry = try hourly.atmosphericSoluteActivity(
        0,
        1,
        &zero_g,
        &zero_salt,
        &.{surface_direct},
        chemistry.ion_molar_mass_g_per_mol,
    );
    var soil_direct: snow.SurfaceDischarge = .{};
    soil_direct.soil_nonband_g = chemistry.direct_surface_and_soil.soil_nonband_g;
    soil_direct.soil_band_g = chemistry.direct_surface_and_soil.soil_band_g;
    soil_direct.soil_nonband_salt_mol = chemistry.direct_surface_and_soil.soil_nonband_salt_mol;
    soil_direct.soil_band_salt_mol = chemistry.direct_surface_and_soil.soil_band_salt_mol;
    const soil_chemistry = try hourly.atmosphericSoluteActivity(
        0,
        1,
        &zero_g,
        &zero_salt,
        &.{soil_direct},
        chemistry.ion_molar_mass_g_per_mol,
    );
    result.top_snow_external = try hourly.addActivities(result.top_snow_external, top_snow_chemistry);
    result.surface_external = try hourly.addActivities(result.surface_external, surface_chemistry);
    result.topsoil_external = try hourly.addActivities(result.topsoil_external, soil_chemistry);
    return result;
}

fn validatePrecipitation(inputs: PrecipitationInputs) !void {
    inline for (std.meta.fields(PrecipitationInputs)) |field|
        if (!std.math.isFinite(@field(inputs, field.name))) return error.InvalidAtmosphericLocalActivity;
    inline for (.{
        inputs.liquid_precipitation_m3,
        inputs.solid_precipitation_water_equivalent_m3,
        inputs.liquid_to_top_snow_m3,
        inputs.liquid_to_surface_litter_m3,
        inputs.liquid_to_topsoil_matrix_m3,
        inputs.liquid_to_topsoil_macropore_m3,
        inputs.water_absolute_tolerance_m3,
        inputs.relative_tolerance,
    }) |value| if (value < 0) return error.InvalidAtmosphericLocalActivity;
    inline for (.{
        inputs.atmospheric_temperature_k,
        inputs.liquid_heat_capacity_megajoules_per_m3_k,
        inputs.solid_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.pure_water_melting_temperature_k,
    }) |value| if (value <= 0) return error.InvalidAtmosphericLocalActivity;
}

fn addSignedHeat(activity: *hourly.BoundaryActivity, signed_heat: f64) !void {
    if (!std.math.isFinite(signed_heat)) return error.InvalidAtmosphericLocalActivity;
    activity.* = try hourly.addActivities(activity.*, if (signed_heat >= 0)
        .{ .heat_input_megajoules = signed_heat }
    else
        .{ .heat_output_megajoules = -signed_heat });
}

fn ionMasses() snow_discharge.IonMolarMassesGPerMol {
    return .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24, .sodium = 23, .potassium = 39, .sulfur = 32, .chloride = 35.5 };
}

test "precipitation routes external liquid and canopy drainage to disjoint exact owners" {
    const activity = try acceptedCellActivity(.{
        .liquid_precipitation_m3 = 8,
        .solid_precipitation_water_equivalent_m3 = 2,
        .canopy_retention_m3 = -2,
        .liquid_to_top_snow_m3 = 2,
        .liquid_to_surface_litter_m3 = 3,
        .liquid_to_topsoil_matrix_m3 = 4,
        .liquid_to_topsoil_macropore_m3 = 1,
        .atmospheric_temperature_k = 270,
        .liquid_heat_capacity_megajoules_per_m3_k = 4,
        .solid_heat_capacity_megajoules_per_m3_k = 2,
        .latent_heat_of_fusion_megajoules_per_m3 = 300,
        .pure_water_melting_temperature_k = 273,
        .water_absolute_tolerance_m3 = 1e-12,
        .relative_tolerance = 1e-12,
    }, .{}, .{ .ion_molar_mass_g_per_mol = ionMasses() });
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), activity.top_snow_external.water_input_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), activity.surface_external.water_input_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4), activity.topsoil_external.water_input_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), activity.canopy_to_top_snow.water_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), activity.canopy_to_surface.water_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), activity.canopy_to_topsoil.water_m3, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), activity.canopy_to_top_snow.water_m3 + activity.canopy_to_surface.water_m3 + activity.canopy_to_topsoil.water_m3, 1e-14);
}

test "solid precipitation and snow exchange book canonical frozen heat exactly once" {
    const activity = try acceptedCellActivity(.{
        .liquid_precipitation_m3 = 0,
        .solid_precipitation_water_equivalent_m3 = 2,
        .canopy_retention_m3 = 0,
        .liquid_to_top_snow_m3 = 0,
        .liquid_to_surface_litter_m3 = 0,
        .liquid_to_topsoil_matrix_m3 = 0,
        .liquid_to_topsoil_macropore_m3 = 0,
        .atmospheric_temperature_k = 270,
        .liquid_heat_capacity_megajoules_per_m3_k = 4,
        .solid_heat_capacity_megajoules_per_m3_k = 2,
        .latent_heat_of_fusion_megajoules_per_m3 = 300,
        .pure_water_melting_temperature_k = 273,
        .water_absolute_tolerance_m3 = 1e-12,
        .relative_tolerance = 1e-12,
    }, .{ .snow_evaporation_m3 = 0.25, .snow_condensation_m3 = 0.1, .snow_boundary_heat_megajoules = -7 }, .{ .ion_molar_mass_g_per_mol = ionMasses() });
    const frozen = try inventory.frozenWaterEnthalpyPerM3(270, 4, 2, 300, 273);
    try std.testing.expectApproxEqAbs(2 * frozen - 7, activity.top_snow_external.heat_input_megajoules - activity.top_snow_external.heat_output_megajoules, 1e-12);
    try std.testing.expectEqual(@as(f64, 2.1), activity.top_snow_external.water_input_m3);
    try std.testing.expectEqual(@as(f64, 0.25), activity.top_snow_external.water_output_m3);
}

test "gross ground vapor directions and chemistry retain actual local owners" {
    var chemistry: ChemistryInputs = .{ .ion_molar_mass_g_per_mol = ionMasses() };
    chemistry.top_snow_input_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 2;
    chemistry.direct_surface_and_soil.litter_g[@intFromEnum(snow.Species.nitrate_nitrogen)] = 3;
    chemistry.direct_surface_and_soil.soil_band_g[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 5;
    const activity = try acceptedCellActivity(.{
        .liquid_precipitation_m3 = 0,
        .solid_precipitation_water_equivalent_m3 = 0,
        .canopy_retention_m3 = 0,
        .liquid_to_top_snow_m3 = 0,
        .liquid_to_surface_litter_m3 = 0,
        .liquid_to_topsoil_matrix_m3 = 0,
        .liquid_to_topsoil_macropore_m3 = 0,
        .atmospheric_temperature_k = 280,
        .liquid_heat_capacity_megajoules_per_m3_k = 4,
        .solid_heat_capacity_megajoules_per_m3_k = 2,
        .latent_heat_of_fusion_megajoules_per_m3 = 300,
        .pure_water_melting_temperature_k = 273,
        .water_absolute_tolerance_m3 = 1e-12,
        .relative_tolerance = 1e-12,
    }, .{
        .litter_evaporation_m3 = 1,
        .topsoil_evaporation_m3 = 2,
        .litter_condensation_m3 = 0.5,
        .topsoil_condensation_m3 = 0.75,
        .surface_boundary_heat_megajoules = -4,
        .topsoil_boundary_heat_megajoules = -6,
    }, chemistry);
    try std.testing.expectEqual(@as(f64, 0.5), activity.surface_external.water_input_m3);
    try std.testing.expectEqual(@as(f64, 1), activity.surface_external.water_output_m3);
    try std.testing.expectEqual(@as(f64, 2), activity.topsoil_external.water_output_m3);
    try std.testing.expectEqual(@as(f64, 0.75), activity.topsoil_external.water_input_m3);
    try std.testing.expectEqual(@as(f64, 2), activity.top_snow_external.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 3), activity.surface_external.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 5), activity.topsoil_external.phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 4), activity.surface_external.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 6), activity.topsoil_external.heat_output_megajoules);
}

test "invalid late route is transactional because the sidecar is pure" {
    const bad: PrecipitationInputs = .{
        .liquid_precipitation_m3 = 1,
        .solid_precipitation_water_equivalent_m3 = 0,
        .canopy_retention_m3 = 0,
        .liquid_to_top_snow_m3 = 0,
        .liquid_to_surface_litter_m3 = 1,
        .liquid_to_topsoil_matrix_m3 = 0,
        .liquid_to_topsoil_macropore_m3 = 1,
        .atmospheric_temperature_k = 280,
        .liquid_heat_capacity_megajoules_per_m3_k = 4,
        .solid_heat_capacity_megajoules_per_m3_k = 2,
        .latent_heat_of_fusion_megajoules_per_m3 = 300,
        .pure_water_melting_temperature_k = 273,
        .water_absolute_tolerance_m3 = 1e-12,
        .relative_tolerance = 1e-12,
    };
    try std.testing.expectError(error.AtmosphericLocalPrecipitationRouteMismatch, acceptedCellActivity(bad, .{}, .{ .ion_molar_mass_g_per_mol = ionMasses() }));
}
