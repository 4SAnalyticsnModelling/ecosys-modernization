//! Tests for `plant_root_metabolism.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const NutrientResult = @import("../plant/root/plant_root_nutrient_uptake.zig").Result;
const RootState = @import("../plant/root/plant_root_system.zig").State;
const root_domain_count = @import("../plant/root/plant_root_system.zig").biological_domain_count;
const std = @import("std");
const plant_root_metabolism = @import("../plant/root/plant_root_metabolism.zig");
test "negative primary growth removes concurrent mycorrhizal structure and mobile pools" {
    const kinetics: plant_root_metabolism.RootLitterFractions = .{
        .woody_carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .woody_nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .woody_phosphorus = .{ 0.1, 0.2, 0.3, 0.4 },
        .nonwoody_carbon = .{ 0.4, 0.3, 0.2, 0.1 },
        .nonwoody_nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .nonwoody_phosphorus = .{ 0.4, 0.3, 0.2, 0.1 },
    };
    const result = try plant_root_metabolism.mycorrhizalLossWithSecondaryRoots(
        -2,
        8,
        20,
        1.0e-12,
        .{
            .structural_carbon_g_c = 4,
            .structural_nitrogen_g_n = 2,
            .structural_phosphorus_g_p = 1,
            .length_m = 12,
            .mobile_carbon_g_c = 5,
            .mobile_nitrogen_g_n = 3,
            .mobile_phosphorus_g_p = 2,
        },
        .{ .{ 0.6, 0.4 }, .{ 0.5, 0.5 }, .{ 0.25, 0.75 } },
        kinetics,
    );
    try std.testing.expectApproxEqAbs(0.25, result.structural_loss_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.1, result.mobile_loss_fraction, 1.0e-12);
    try std.testing.expectApproxEqAbs(3, result.remaining.structural_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(9, result.remaining.length_m, 1.0e-12);
    try std.testing.expectApproxEqAbs(4.5, result.remaining.mobile_carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(0.06, result.litter.woody_carbon_g_c[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(0.36, result.litter.nonwoody_carbon_g_c[0], 1.0e-12);

    const unchanged = try plant_root_metabolism.mycorrhizalLossWithSecondaryRoots(
        0.2,
        0,
        0,
        1.0e-12,
        result.remaining,
        .{ .{ 0.6, 0.4 }, .{ 0.5, 0.5 }, .{ 0.25, 0.75 } },
        kinetics,
    );
    try std.testing.expectEqual(@as(f64, 0), unchanged.structural_loss_fraction);
    try std.testing.expectEqual(result.remaining, unchanged.remaining);
}

test "live GROSUB mycorrhizal loss follows current then upper host-root deficits" {
    var roots = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try workspace.resetAxes(1);
    workspace.primary_deficit_active[0] = true;
    workspace.primary_deficit_absorption[0] = try plant_root_metabolism.absorbPrimaryDeficitFromSecondaryRoots(
        3,
        0,
        0,
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0, .phosphorus_g_p = 0, .length_m = 2 },
        .{ .carbon_g_c = 4, .nitrogen_g_n = 0, .phosphorus_g_p = 0, .length_m = 4 },
    );
    const upper_axis = try roots.layerAxisIndex(0, 1, 0, 0);
    const current_axis = try roots.layerAxisIndex(0, 1, 1, 0);
    const upper_root = try roots.layerIndex(0, 1, 0);
    const current_root = try roots.layerIndex(0, 1, 1);
    roots.axis_secondary_carbon_g[upper_axis] = 8;
    roots.axis_secondary_carbon_g[current_axis] = 4;
    roots.axis_secondary_length_m[upper_axis] = 16;
    roots.axis_secondary_length_m[current_axis] = 8;
    roots.mobile_carbon_g[upper_root] = 8;
    roots.mobile_carbon_g[current_root] = 10;
    const unit = [_]f64{1} ** 4;
    const zero = [_]f64{0} ** 4;
    const litter = try plant_root_metabolism.state_updateMycorrhizalLossWithSecondaryRoots(
        &roots,
        0,
        1,
        workspace,
        1,
        .{ 10, 8 },
        1.0e-12,
        .{ .{ 0, 1 }, .{ 0, 1 }, .{ 0, 1 } },
        .{
            .woody_carbon = zero,
            .woody_nitrogen = zero,
            .woody_phosphorus = zero,
            .nonwoody_carbon = unit,
            .nonwoody_nitrogen = unit,
            .nonwoody_phosphorus = unit,
        },
    );
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_carbon_g[current_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_length_m[current_axis]);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0 / 3.0), roots.axis_secondary_carbon_g[upper_axis], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 32.0 / 3.0), roots.axis_secondary_length_m[upper_axis], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), roots.mobile_carbon_g[current_root], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), roots.mobile_carbon_g[upper_root], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 7), litter.current.nonwoody_carbon_g_c[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0 / 3.0), litter.upper.nonwoody_carbon_g_c[0], 1.0e-12);
}

test "GROSUB root respiration assembly preserves RCO2T and RCO2TM equations" {
    const components: plant_root_metabolism.Components = .{
        .maintenance_demand_g_c = 3,
        .substrate_respiration_actual_g_c = 2,
        .substrate_respiration_oxygen_unlimited_g_c = 4,
        .growth_respiration_actual_g_c = 0.5,
        .growth_respiration_oxygen_unlimited_g_c = 0.8,
        .senescence_respiration_actual_g_c = 0.2,
        .senescence_respiration_oxygen_unlimited_g_c = 0.3,
        .nitrogen_assimilation_respiration_actual_g_c = 0.1,
        .nitrogen_assimilation_respiration_oxygen_unlimited_g_c = 0.15,
    };
    const result = try plant_root_metabolism.assemble(components);
    try std.testing.expectApproxEqAbs(@as(f64, 2.8), result.actual_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.25), result.oxygen_unlimited_g_c, 1.0e-12);
    try std.testing.expectEqual(result.actual_g_c, result.carbon_unlimited_g_c);
}

test "GROSUB secondary-root metabolism preserves source equations" {
    const parameters: plant_root_metabolism.SecondaryRootParameters = .{
        .maximum_substrate_respiration_fraction_per_h = 0.015,
        .substrate_respiration_half_saturation_g_c_per_g_c = 0.025,
        .nitrogen_feedback_half_saturation_g_n_per_g_c = 0.1,
        .phosphorus_feedback_half_saturation_g_p_per_g_c = 0.01,
        .maintenance_respiration_g_c_per_g_n_h = 0.010,
        .nitrogen_assimilation_respiration_g_c_per_g_n = 1.70,
        .minimum_carbon_recycling_fraction = 0.167,
        .responsive_carbon_recycling_fraction = 0.333,
        .maximum_nitrogen_recycling_fraction = 0.667,
        .maximum_phosphorus_recycling_fraction = 0.667,
        .storage_exchange_fraction_per_h = 2.5e-5,
        .nonwoody_root_fraction_exponent = 0.167,
        .maintenance_gas_constant_j_per_mol_k = 8.3143,
        .maintenance_enthalpy_j_per_mol_k = 710,
        .maintenance_activation_energy_j_per_mol = 62500,
        .maintenance_low_temperature_inactivation_energy_j_per_mol = 197500,
        .maintenance_normalization_log_intercept = 25.216,
        .maximum_maintenance_temperature_response = 1.0e3,
        .shallow_root_water_response_per_megapascal = 0.05,
        .deep_root_water_response_per_megapascal = 0.10,
        .maintenance_water_response_exponent = 0.25,
        .root_penetration_reference_radius_m = 1.0e-3,
        .acidity_half_effect_hydrogen_activity_mol_per_m3 = 1,
        .maximum_acidity_enhancement = 4,
        .shallow_primary_root_sink_multiplier = 0.25,
        .intermediate_primary_root_sink_multiplier = 1,
        .deep_primary_root_sink_multiplier = 2,
        .deeper_primary_root_sink_multiplier = 4,
        .annual_termination_hours_without_grain_fill = 336,
        .root_protein_carbon_per_nitrogen_g_c_per_g_n = 2.5,
        .root_protein_carbon_per_phosphorus_g_c_per_g_p = 25,
        .nutrient_uptake_respiration_g_c_per_g_element = 0.86,
        .evergreen_leafoff_remobilization_start_fraction = 0.75,
        .deciduous_leafoff_remobilization_start_fraction = 0.5,
        .full_senescence_duration_h = 480,
    };
    const inputs: plant_root_metabolism.SecondaryRootInputs = .{
        .mobile_carbon_g_c = 0.2,
        .nonstructural_nitrogen_g_n = 0.04,
        .nonstructural_phosphorus_g_p = 0.004,
        .root_carbon_g_c = 2,
        .root_nitrogen_g_n = 0.04,
        .root_nitrogen_to_carbon_ratio_g_n_per_g_c = 0.02,
        .root_phosphorus_to_carbon_ratio_g_p_per_g_c = 0.002,
        .root_growth_yield_g_c_per_g_c = 0.8,
        .active_root_fraction = 0.5,
        .biological_timestep_h = 1,
        .substrate_temperature_response = 0.9,
        .maintenance_temperature_response = 0.8,
        .acidity_response = 0.75,
        .substrate_feedback = 0.6,
        .oxygen_limitation = 0.7,
        .substrate_water_response = 0.5,
        .maintenance_water_response = 0.5,
    };
    const result = try plant_root_metabolism.secondaryRootMetabolism(parameters, inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), result.nutrient_feedback, 1.0e-12);
    const rco2rm = 0.015 * 0.5 * 0.2 * 0.9 * (2.0 / 3.0) * 0.6 * 0.5 * 0.1 / 0.125;
    const rmncr = 0.010 * 0.04 * 0.8 * 0.75 * 0.5;
    try std.testing.expectApproxEqAbs(rco2rm, result.substrate_respiration_oxygen_unlimited_g_c_per_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(rmncr, result.maintenance_respiration_g_c_per_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(1.70 * result.nitrogen_growth_actual_g_n_per_h, result.nitrogen_assimilation_respiration_actual_g_c_per_h, 1.0e-12);
    var singular = inputs;
    singular.root_growth_yield_g_c_per_g_c = 1;
    try std.testing.expectError(error.InvalidSecondaryRootMetabolismInput, plant_root_metabolism.secondaryRootMetabolism(parameters, singular));
}

test "GROSUB secondary-root entry and respiration water selectors preserve source gates" {
    try std.testing.expect(plant_root_metabolism.secondaryRootAxisActive(2, 2, false));
    try std.testing.expect(!plant_root_metabolism.secondaryRootAxisActive(3, 2, false));
    try std.testing.expect(!plant_root_metabolism.secondaryRootAxisActive(2, 2, true));
    try std.testing.expect(plant_root_metabolism.rootRespirationActive(true, true));
    try std.testing.expect(plant_root_metabolism.rootRespirationActive(false, false));
    try std.testing.expect(!plant_root_metabolism.rootRespirationActive(false, true));

    const evergreen_deep = try plant_root_metabolism.sourceRootRespirationWaterResponses(2, 0, 0.25, 0.70);
    try std.testing.expectEqual(@as(f64, 0.25), evergreen_deep.substrate);
    try std.testing.expectEqual(@as(f64, 0.70), evergreen_deep.maintenance);
    const drought_deciduous = try plant_root_metabolism.sourceRootRespirationWaterResponses(2, 2, 0.25, 0.70);
    try std.testing.expectEqual(@as(f64, 0.25), drought_deciduous.substrate);
    try std.testing.expectEqual(@as(f64, 0.25), drought_deciduous.maintenance);
}

test "runtime root metabolism plant parameters reject invalid dimensions and codes" {
    const valid: plant_root_metabolism.RuntimePlantParameters = .{
        .root_profile_type = 2,
        .mycorrhizal_type = 2,
        .growth_habit = 1,
        .leaf_phenology_type = 0,
        .root_growth_yield_g_c_per_g_c = 0.7,
        .root_nitrogen_to_carbon_g_n_per_g_c = 0.03,
        .root_phosphorus_to_carbon_g_p_per_g_c = 0.004,
        .stalk_nitrogen_to_carbon_g_n_per_g_c = 0.01,
        .stalk_phosphorus_to_carbon_g_p_per_g_c = 0.001,
        .primary_root_radius_m = 0.001,
        .secondary_root_radius_m = 0.0002,
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 100,
        .secondary_root_branching_per_m = 20,
        .shoot_root_equilibration_fraction_per_h = 0.1,
    };
    try valid.validate();
    var invalid = valid;
    invalid.root_profile_type = 4;
    try std.testing.expectError(error.InvalidRootMetabolismPlantCode, invalid.validate());
    invalid = valid;
    invalid.secondary_specific_length_m_per_g_c = 0;
    try std.testing.expectError(error.InvalidRootMetabolismPlantParameter, invalid.validate());
}

test "STARTQ CNRTS and CPRTS yield-scaled ratios bound GROSUB root growth respiration" {
    const respiration_fraction = 0.3;
    const growth_yield = 0.8;
    const active_fraction = 0.5;
    const nitrogen_ratio = 0.02;
    const phosphorus_ratio = 0.002;
    const nitrogen = 0.04;
    const phosphorus = 0.003;
    const result = try plant_root_metabolism.nutrientLimitedRootGrowthRespiration(
        nitrogen,
        phosphorus,
        active_fraction,
        respiration_fraction,
        growth_yield,
        nitrogen_ratio,
        phosphorus_ratio,
    );
    const source_n_limit = nitrogen * respiration_fraction * active_fraction / (nitrogen_ratio * growth_yield);
    const source_p_limit = phosphorus * respiration_fraction * active_fraction / (phosphorus_ratio * growth_yield);
    try std.testing.expect(source_p_limit < source_n_limit);
    try std.testing.expectApproxEqAbs(source_p_limit, result, 1.0e-15);
    // Converting source growth respiration back through DMRTD and DMRT
    // consumes exactly the limiting active phosphorus inventory.
    const structural_growth_g_c = result / respiration_fraction * growth_yield;
    try std.testing.expectApproxEqAbs(phosphorus * active_fraction, structural_growth_g_c * phosphorus_ratio, 1.0e-15);
}

test "GROSUB primary-root bottom cap uses current axis maintenance demand" {
    const result = try plant_root_metabolism.primaryRootMetabolism(plant_root_metabolism.compatibilitySecondaryRootParameters(), .{
        .shared = .{
            .mobile_carbon_g_c = 1,
            .nonstructural_nitrogen_g_n = 0.1,
            .nonstructural_phosphorus_g_p = 0.01,
            .root_carbon_g_c = 2,
            .root_nitrogen_g_n = 0.02,
            .root_nitrogen_to_carbon_ratio_g_n_per_g_c = 0.02,
            .root_phosphorus_to_carbon_ratio_g_p_per_g_c = 0.002,
            .root_growth_yield_g_c_per_g_c = 0.8,
            .active_root_fraction = 1,
            .biological_timestep_h = 1,
            .substrate_temperature_response = 1,
            .maintenance_temperature_response = 1,
            .acidity_response = 1,
            .substrate_feedback = 1,
            .oxygen_limitation = 1,
            .substrate_water_response = 1,
            .maintenance_water_response = 1,
        },
        .primary_tip_at_or_below_profile_bottom = true,
    });
    try std.testing.expectApproxEqAbs(result.maintenance_respiration_g_c_per_h, result.substrate_respiration_oxygen_unlimited_g_c_per_h, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), result.growth_respiration_actual_g_c_per_h);
}

test "GROSUB primary-root plant_root_metabolism.state_update updates axis and shared pools atomically" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    roots.mobile_carbon_g[0] = 10;
    roots.mobile_nitrogen_g[0] = 1;
    roots.mobile_phosphorus_g[0] = 0.1;
    roots.axis_primary_carbon_g[0] = 2;
    roots.axis_primary_nitrogen_g[0] = 0.2;
    roots.axis_primary_phosphorus_g[0] = 0.02;
    roots.axis_primary_length_m[0] = 4;
    roots.axis_depth_m[0] = 1;
    const senescence: plant_root_metabolism.SecondaryRootSenescence = .{
        .respiration_oxygen_unlimited_g_c_per_h = 0.1,
        .respiration_actual_g_c_per_h = 0.1,
        .phenological_senescence_g_c_per_h = 0,
        .senesced_fraction = 0.25,
        .recyclable_carbon_g_c = 0.8,
        .recyclable_nitrogen_g_n = 0.08,
        .recyclable_phosphorus_g_p = 0.008,
    };
    try plant_root_metabolism.state_updatePrimaryRoot(&roots, 0, 0, 0, .{
        .metabolism = std.mem.zeroes(plant_root_metabolism.SecondaryRootResult),
        .senescence = senescence,
        .primary_specific_length_m_per_g_c = 10,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 0.6,
        .nonwoody_nitrogen_fraction = 0.7,
        .nonwoody_phosphorus_fraction = 0.5,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 10.02), roots.mobile_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.014), roots.mobile_nitrogen_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.101), roots.mobile_phosphorus_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), roots.axis_primary_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), roots.axis_primary_length_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), roots.axis_depth_m[0], 1e-12);
    const mobile_before = roots.mobile_carbon_g[0];
    try std.testing.expectError(error.PlantRootIndexOutOfBounds, plant_root_metabolism.state_updatePrimaryRoot(&roots, 0, 0, 2, .{
        .metabolism = std.mem.zeroes(plant_root_metabolism.SecondaryRootResult),
        .senescence = senescence,
        .primary_specific_length_m_per_g_c = 10,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 0.6,
        .nonwoody_nitrogen_fraction = 0.7,
        .nonwoody_phosphorus_fraction = 0.5,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    }));
    try std.testing.expectEqual(mobile_before, roots.mobile_carbon_g[0]);
}

test "GROSUB primary-root respiration is allocated across traversed layers" {
    var roots = try RootState.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    const indices = [_]usize{
        try roots.layerIndex(0, 0, 0),
        try roots.layerIndex(0, 0, 1),
        try roots.layerIndex(0, 0, 2),
    };
    var fractions: [3]f64 = undefined;
    try plant_root_metabolism.allocatePrimaryRootRespiration(&roots, &indices, &.{ 0.2, 0.3, 0.1 }, &fractions, 1.1, 0.1, true, .{
        .actual_g_c = 2,
        .oxygen_unlimited_g_c = 3,
        .carbon_unlimited_g_c = 4,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), fractions[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), fractions[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), fractions[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), roots.actual_respiration_g_c_per_h[indices[0]], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), roots.actual_respiration_g_c_per_h[indices[2]], 1e-15);
    var actual_total: f64 = 0;
    for (indices) |root| actual_total += roots.actual_respiration_g_c_per_h[root];
    try std.testing.expectApproxEqAbs(@as(f64, 2), actual_total, 1e-15);
}

test "GROSUB primary root depth retracts under negative net growth" {
    const positive = try plant_root_metabolism.primaryRootLengthChange(0.2, 0.2, 4, 1.1, 0.1, 10, 2, 0.5);
    try std.testing.expectApproxEqAbs(0.5, positive, 1e-15);
    const retraction = try plant_root_metabolism.primaryRootLengthChange(0.02, -0.8, 4, 1.1, 0.1, 10, 2, 0.5);
    // Gross extension is 0.05 m; proportional withdrawal is -0.20 m.
    try std.testing.expectApproxEqAbs(-0.15, retraction, 1e-15);
}

test "GROSUB secondary-root recycling and senescence preserve source branches" {
    const parameters = plant_root_metabolism.compatibilitySecondaryRootParameters();
    const recycling = try plant_root_metabolism.secondaryRootRecyclingFractions(true, 0.2, 0.04, 0.004, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.167 + 0.333 * (2.0 / 3.0)), recycling.carbon, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.667 / 3.0), recycling.nitrogen, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.667 / 3.0), recycling.phosphorus, 1.0e-12);
    const senescence = try plant_root_metabolism.secondaryRootSenescence(.{
        .oxygen_unlimited_substrate_minus_maintenance_g_c_per_h = -0.3,
        .actual_substrate_minus_maintenance_g_c_per_h = -0.4,
        .root_carbon_g_c = 1,
        .root_nitrogen_g_n = 0.02,
        .root_phosphorus_g_p = 0.002,
        .oxygen_limitation = 0.5,
        .phenological_remobilization_enabled = true,
        .root_remobilization_enabled = true,
        .storage_exchange_fraction_per_h = 0.01,
        .remobilization_elapsed_h = 50,
        .full_senescence_h = 100,
        .biological_timestep_h = 1,
        .structural_presence_threshold_g_c = 1.0e-12,
    }, recycling);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), senescence.respiration_oxygen_unlimited_g_c_per_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(senescence.recyclable_carbon_g_c * 0.5 + 0.005, senescence.respiration_actual_g_c_per_h, 1.0e-12);
    try std.testing.expectApproxEqAbs(senescence.respiration_actual_g_c_per_h / senescence.recyclable_carbon_g_c, senescence.senesced_fraction, 1.0e-12);
}

test "GROSUB primary senescence excludes secondary phenological remobilization" {
    const recycling: plant_root_metabolism.RecyclingFractions = .{ .carbon = 0.5, .nitrogen = 0.5, .phosphorus = 0.5 };
    const inputs: plant_root_metabolism.SecondaryRootSenescenceInputs = .{
        .oxygen_unlimited_substrate_minus_maintenance_g_c_per_h = 0,
        .actual_substrate_minus_maintenance_g_c_per_h = 0,
        .root_carbon_g_c = 10,
        .root_nitrogen_g_n = 1,
        .root_phosphorus_g_p = 0.1,
        .oxygen_limitation = 1,
        .phenological_remobilization_enabled = true,
        .root_remobilization_enabled = true,
        .storage_exchange_fraction_per_h = 0.1,
        .remobilization_elapsed_h = 10,
        .full_senescence_h = 10,
        .biological_timestep_h = 1,
        .structural_presence_threshold_g_c = 1e-12,
    };
    const secondary = try plant_root_metabolism.secondaryRootSenescence(inputs, recycling);
    const primary = try plant_root_metabolism.primaryRootSenescence(inputs, recycling);
    try std.testing.expectEqual(@as(f64, 1), secondary.phenological_senescence_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 0), primary.phenological_senescence_g_c_per_h);
    try std.testing.expectEqual(@as(f64, 0), primary.respiration_actual_g_c_per_h);
}

test "GROSUB root wood composition preserves FWODR and weighted growth ratios" {
    const composition = try plant_root_metabolism.rootWoodComposition(true, true, 8, 2, 0.01, 0.03, 0.001, 0.003, 1.0e-12, 0.167);
    const nonwoody = std.math.pow(f64, 0.25, 0.167);
    try std.testing.expectApproxEqAbs(nonwoody, composition.carbon_fraction[1], 1.0e-12);
    try std.testing.expectEqual(composition.carbon_fraction, composition.nitrogen_fraction);
    try std.testing.expectApproxEqAbs((1 - nonwoody) * 0.01 + nonwoody * 0.03, composition.growth_nitrogen_to_carbon_g_n_per_g_c, 1.0e-12);
    const herbaceous = try plant_root_metabolism.rootWoodComposition(false, false, 0, 0, 0.01, 0.03, 0.001, 0.003, 1.0e-12, 0.167);
    try std.testing.expectEqual([2]f64{ 0, 1 }, herbaceous.carbon_fraction);
}

test "GROSUB root environment preserves TFN6 FPH and water responses" {
    const parameters = plant_root_metabolism.compatibilitySecondaryRootParameters();
    const response = try plant_root_metabolism.rootEnvironmentResponses(parameters, 298.15, 0, 7, -1, 0.5, 0, 0.2, 0.5e-3, true);
    const adjusted_temperature_k = 298.15;
    const rtk = 8.3143 * adjusted_temperature_k;
    const expected_temperature = @min(@as(f64, 1.0e3), std.math.exp(25.216 - @as(f64, 62500) / rtk) / (1 + std.math.exp((197500 - 710 * adjusted_temperature_k) / rtk)));
    try std.testing.expectApproxEqAbs(expected_temperature, response.maintenance_temperature, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0001), response.acidity, 1.0e-12);
    try std.testing.expectApproxEqAbs(std.math.exp(@as(f64, -0.05)), response.growth_water, 1.0e-12);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, response.growth_water, 0.25), response.maintenance_water, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), response.scaled_penetration_resistance_megapascal, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), response.extension_water, 1.0e-12);
}

test "GROSUB next lower root layer skips thin layers but retains the bottom" {
    const thickness_m = [_]f64{ 0.1, 1e-8, 0.2, 0 };
    try std.testing.expectEqual(@as(usize, 2), try plant_root_metabolism.nextLowerRootLayer(&thickness_m, 0, 1e-6));
    try std.testing.expectEqual(@as(usize, 3), try plant_root_metabolism.nextLowerRootLayer(&thickness_m, 2, 1e-6));
    try std.testing.expectError(error.NoLowerRootLayer, plant_root_metabolism.nextLowerRootLayer(&thickness_m, 3, 1e-6));
    try std.testing.expectError(error.InvalidRootLayerThickness, plant_root_metabolism.nextLowerRootLayer(&.{ 0.1, std.math.nan(f64) }, 0, 1e-6));
}
