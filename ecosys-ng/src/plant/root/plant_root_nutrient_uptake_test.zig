//! Tests for `plant_root_nutrient_uptake.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const rooted_layer_eligibility = @import("rooted_layer_eligibility.zig");
const root_pool_transaction_replay = @import("pool_transaction_replay.zig");
const growth_temperature = @import("../response/growth_temperature.zig");
const uptake_module = @import("plant_root_nutrient_uptake.zig");

test "UPTAKE nutrient quadratic preserves source equation and diagnostic limits" {
    const input = uptake_module.Input{ .soil_concentration_g_element_per_m3 = 4, .soil_pool_g_element = 10, .total_soil_water_volume_m3 = 2, .soil_zone_fraction = 0.75, .water_mass_flow_term = 0.1, .diffusive_conductance_m3_per_step = 0.2, .minimum_residual_concentration_g_element_per_m3 = 0.5, .michaelis_half_saturation_g_element_per_m3 = 1, .maximum_uptake_g_element_per_plant_step = 0.6, .oxygen_unlimited_maximum_uptake_g_element_per_plant_step = 1.2, .plant_population_count = 3, .population_competition_fraction = 0.4, .time_fraction = 1, .carbon_uptake_limitation_fraction = 0.5 };
    const result = try uptake_module.solve(input);
    const x = (input.diffusive_conductance_m3_per_step + input.water_mass_flow_term) * input.soil_concentration_g_element_per_m3;
    const y = input.diffusive_conductance_m3_per_step * input.minimum_residual_concentration_g_element_per_m3;
    const per_plant = result.demand_g_element / input.plant_population_count;
    const residual = per_plant * per_plant - (input.maximum_uptake_g_element_per_plant_step + input.diffusive_conductance_m3_per_step * input.michaelis_half_saturation_g_element_per_m3 + x - y) * per_plant + (x - y) * input.maximum_uptake_g_element_per_plant_step;
    try std.testing.expectApproxEqAbs(@as(f64, 0), residual, 1.0e-12);
    try std.testing.expect(result.uptake_g_element <= result.available_g_element);
    try std.testing.expect(result.oxygen_unlimited_uptake_g_element >= result.uptake_g_element);
    try std.testing.expectApproxEqAbs(result.uptake_g_element / 0.5, result.carbon_unlimited_uptake_g_element, 1.0e-12);
}

test "READQ nutrient traits convert to dimensional UPTAKE operands" {
    const translated = try uptake_module.inputFromTraits(.{
        .traits = .{ .maximum_rate_g_per_m2_h = 0.014, .half_saturation_umol_per_l = 0.40, .minimum_concentration_umol_per_l = 0.0125 },
        .element_molar_mass_g_per_mol = 14,
        .root_surface_area_m2_per_plant = 2,
        .root_activity_fraction = 0.5,
        .nutrient_zone_access_fraction = 0.8,
        .oxygen_limitation_fraction = 0.25,
        .soil_concentration_g_element_per_m3 = 1,
        .soil_pool_g_element = 2,
        .total_soil_water_volume_m3 = 3,
        .soil_zone_fraction = 0.75,
        .water_mass_flow_term = 0.1,
        .diffusive_conductance_m3_per_step = 0.2,
        .plant_population_count = 10,
        .population_competition_fraction = 0.4,
        .time_fraction = 1,
        .carbon_uptake_limitation_fraction = 0.5,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.175), translated.minimum_residual_concentration_g_element_per_m3, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.6), translated.michaelis_half_saturation_g_element_per_m3, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0112), translated.oxygen_unlimited_maximum_uptake_g_element_per_plant_step, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0028), translated.maximum_uptake_g_element_per_plant_step, 1.0e-12);

    var phosphate = translated;
    phosphate = try uptake_module.inputFromTraits(.{
        .traits = .{ .maximum_rate_g_per_m2_h = 0.004, .half_saturation_umol_per_l = 0.2, .minimum_concentration_umol_per_l = 0.01 },
        .element_molar_mass_g_per_mol = 31,
        .root_surface_area_m2_per_plant = 1,
        .root_activity_fraction = 1,
        .nutrient_zone_access_fraction = 1,
        .oxygen_limitation_fraction = 1,
        .soil_concentration_g_element_per_m3 = 1,
        .soil_pool_g_element = 2,
        .total_soil_water_volume_m3 = 3,
        .soil_zone_fraction = 1,
        .water_mass_flow_term = 0,
        .diffusive_conductance_m3_per_step = 0,
        .plant_population_count = 1,
        .population_competition_fraction = 1,
        .time_fraction = 1,
        .carbon_uptake_limitation_fraction = 1,
        .phosphate_charge_multiplier = 0.25,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), phosphate.maximum_uptake_g_element_per_plant_step, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0775), phosphate.minimum_residual_concentration_g_element_per_m3, 1.0e-12);
}

test "UPTAKE radial diffusion preserves ZNSGX PATHL and DIFFL equations" {
    const diffusivity_m2_per_h: f64 = 5.0e-5;
    const tortuosity: f64 = 0.35;
    const timestep_h: f64 = 0.5;
    const path_m: f64 = 0.02;
    const radius_m: f64 = 1.0e-4;
    const surface_area_per_radius_m: f64 = 3;
    const effective = diffusivity_m2_per_h * tortuosity * timestep_h;
    const limited_path = @min(path_m, @sqrt(2 * effective));
    const expected = effective * surface_area_per_radius_m / @log((limited_path + radius_m) / radius_m);
    try std.testing.expectApproxEqAbs(expected, try uptake_module.radialDiffusiveConductanceM3PerStep(diffusivity_m2_per_h, tortuosity, timestep_h, path_m, radius_m, surface_area_per_radius_m), 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), try uptake_module.radialDiffusiveConductanceM3PerStep(0, tortuosity, timestep_h, path_m, radius_m, surface_area_per_radius_m));
}

test "UPTAKE root growth temperature response preserves TFN4" {
    const temperature_k: f64 = 298.15;
    const rt = 8.3143 * temperature_k;
    const st = 710 * temperature_k;
    const expected = @exp(25.229 - 62500 / rt) / (1 + @exp((197500 - st) / rt) + @exp((st - 222500) / rt));
    try std.testing.expectApproxEqAbs(expected, try uptake_module.rootGrowthTemperatureResponse(temperature_k, 0, growth_temperature.compatibilityParameters()), 1.0e-15);
}

test "runtime nutrient diffusivities preserve HOUR1 temperature response" {
    const parameters = uptake_module.compatibilityRuntimeParameters();
    try std.testing.expectApproxEqAbs(@as(f64, 4.0e-6), try parameters.diffusivityM2PerH(0, 298.15), 1.0e-18);
    try std.testing.expectApproxEqAbs(6.0e-6 * std.math.pow(f64, 310.0 / 298.15, 6), try parameters.diffusivityM2PerH(1, 310), 1.0e-18);
    try std.testing.expectError(error.RootNutrientKindOutOfBounds, parameters.diffusivityM2PerH(3, 298.15));
}

test "UPTAKE protein carbon nitrogen and phosphorus activity fractions retain source equations" {
    const parameters = uptake_module.compatibilityRuntimeParameters();
    const result = try uptake_module.activityFractions(0.04, 2, 0.05, 0.3, 0.6, 0.2, 0.04, 0.01, true, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), result.protein, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.carbon, 1.0e-12);
    try std.testing.expectApproxEqAbs(@min(0.2 / (0.2 + 0.04), 0.01 / (0.01 + 0.04)), result.nitrogen, 1.0e-12);
    try std.testing.expectApproxEqAbs(@min(0.2 / (0.2 + 0.01 / 0.01), 0.04 / (0.04 + 0.01 / 0.01)), result.phosphorus, 1.0e-12);
    const no_respiration = try uptake_module.activityFractions(0, 0, 0.05, 1, 0, 0.2, 0, 0, true, parameters);
    try std.testing.expectEqual(@as(f64, 1), no_respiration.protein);
    try std.testing.expectEqual(@as(f64, 0), no_respiration.carbon);
    try std.testing.expectEqual(@as(f64, 1), no_respiration.nitrogen);
}

test "UPTAKE nutrient state_update conserves element and rejects depletion atomically" {
    var soil: f64 = 2;
    var root: f64 = 1;
    var uptake: f64 = 0;
    try uptake_module.state_updateUptake(&soil, &root, &uptake, 0.4);
    try std.testing.expectApproxEqAbs(@as(f64, 3), soil + root, 1.0e-12);
    const accepted_soil = soil;
    const accepted_root = root;
    const accepted_uptake = uptake;
    try std.testing.expectError(error.InvalidRootNutrientStateUpdate, uptake_module.state_updateUptake(&soil, &root, &uptake, soil + 5.0e-13));
    try std.testing.expectEqual(accepted_soil, soil);
    try std.testing.expectEqual(accepted_root, root);
    try std.testing.expectEqual(accepted_uptake, uptake);
    try std.testing.expectError(error.InvalidRootNutrientStateUpdate, uptake_module.state_updateUptake(&soil, &root, &uptake, 2));
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), soil, 1.0e-12);
}

test "root nutrient workspace is runtime-sized beyond the legacy species ceiling" {
    var workspace = try uptake_module.Workspace.init(std.testing.allocator, 22);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 22), workspace.competitors.len);
    try std.testing.expectEqual(@as(usize, 22 * uptake_module.nutrient_pool_count), workspace.input_by_competitor_pool.len);
    try std.testing.expectEqual(workspace.input_by_competitor_pool.ptr, (try workspace.inputs(0)).ptr);
    try std.testing.expectEqual(workspace.input_by_competitor_pool.ptr + 21 * uptake_module.nutrient_pool_count, (try workspace.inputs(21)).ptr);
    try std.testing.expectError(error.RootNutrientCompetitorOutOfBounds, workspace.inputs(22));
}

test "root nutrient grid workspace gives every parallel cell independent storage" {
    var workspace = try uptake_module.GridWorkspace.init(std.testing.allocator, 4, 22);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 4), workspace.per_cell.len);
    for (workspace.per_cell) |cell| try std.testing.expectEqual(@as(usize, 22), cell.competitor_capacity);
    try std.testing.expect(workspace.per_cell[0].input_by_competitor_pool.ptr != workspace.per_cell[1].input_by_competitor_pool.ptr);
}

test "root nutrient grid owns independent runtime admission schedules" {
    var workspace = try uptake_module.GridWorkspace.initWithAdmissionCapacity(std.testing.allocator, 3, 4, 24);
    defer workspace.deinit();
    const first = try workspace.admissionBuffer(0);
    const second = try workspace.admissionBuffer(1);
    try std.testing.expectEqual(@as(usize, 24), first.len);
    try std.testing.expect(first.ptr != second.ptr);
    first[0] = .{ .plant = 7, .biological_domain = 1, .soil_layer = 5 };
    second[0] = .{ .plant = 8, .biological_domain = 0, .soil_layer = 2 };
    try std.testing.expect(!std.meta.eql(first[0], second[0]));
    try std.testing.expectError(error.RootNutrientGridCellOutOfBounds, workspace.admissionBuffer(3));
}
