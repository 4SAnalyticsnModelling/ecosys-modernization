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
test "GROSUB root axis sink strengths retain series equation and runtime axes" {
    const parameters = plant_root_metabolism.compatibilitySecondaryRootParameters();
    const first = try plant_root_metabolism.rootAxisSinkStrength(parameters, .{
        .root_profile_type = 2,
        .primary_axis_count_multiplier = 3,
        .primary_root_radius_m = 2e-3,
        .primary_root_depth_from_canopy_m = 0.4,
        .secondary_root_depth_from_canopy_m = 0.3,
        .secondary_axis_count = 8,
        .secondary_root_radius_m = 1e-3,
        .average_secondary_root_length_m = 0.2,
        .primary_biological_domain = true,
    });
    const primary_series = 3 * std.math.pow(f64, 2e-3, 2) / 0.3;
    const secondary_parallel = 8 * std.math.pow(f64, 1e-3, 2) / 0.2;
    try std.testing.expectApproxEqAbs(2 * 3 * std.math.pow(f64, 2e-3, 2) / 0.4, first.primary_m, 1.0e-15);
    try std.testing.expectApproxEqAbs(primary_series * secondary_parallel / (primary_series + secondary_parallel), first.secondary_m, 1.0e-15);
    var strengths = [_]plant_root_metabolism.RootAxisSinkStrength{first} ** 7;
    strengths[6] = .{ .primary_m = 0, .secondary_m = first.secondary_m };
    var primary_fractions: [7]f64 = undefined;
    var secondary_fractions: [7]f64 = undefined;
    const total = try plant_root_metabolism.normalizeRootAxisSinkFractions(&strengths, &primary_fractions, &secondary_fractions, 1e-20);
    try std.testing.expect(total > 0);
    var fraction_sum: f64 = 0;
    for (primary_fractions, secondary_fractions) |primary, secondary| fraction_sum += primary + secondary;
    try std.testing.expectApproxEqAbs(@as(f64, 1), fraction_sum, 1.0e-12);
}

test "GROSUB source sink comparator gates primary tips and uses rooted midpoint depth" {
    const parameters = plant_root_metabolism.compatibilitySecondaryRootParameters();
    const shared: plant_root_metabolism.SourceOrderRootAxisSinkInputs = .{
        .root_profile_type = 2,
        .primary_axis_count_multiplier = 3,
        .primary_root_radius_m = 2e-3,
        .primary_root_depth_from_surface_m = 0.45,
        .layer_top_depth_m = 0.2,
        .layer_thickness_m = 0.2,
        .secondary_root_origin_offset_m = 0.05,
        .seeding_depth_m = 0.1,
        .hypocotyledon_height_m = 0.02,
        .canopy_height_m = 0.3,
        .secondary_axis_count = 8,
        .secondary_root_radius_m = 1e-3,
        .average_secondary_root_length_m = 0.2,
        .negligible_sink_m = 1e-20,
        .primary_biological_domain = true,
    };
    const outside_tip_layer = try plant_root_metabolism.sourceOrderRootAxisSinkStrength(parameters, shared);
    try std.testing.expectEqual(@as(f64, 0), outside_tip_layer.primary_m);
    const rooted_length_m = 0.2;
    const secondary_depth_m = 0.2 + 0.5 * rooted_length_m + 0.3;
    const primary_series = 3 * std.math.pow(f64, 2e-3, 2) / secondary_depth_m;
    const secondary_parallel = 8 * std.math.pow(f64, 1e-3, 2) / 0.2;
    try std.testing.expectApproxEqAbs(primary_series * secondary_parallel / (primary_series + secondary_parallel), outside_tip_layer.secondary_m, 1e-15);

    var mycorrhiza = shared;
    mycorrhiza.primary_biological_domain = false;
    const mycorrhizal = try plant_root_metabolism.sourceOrderRootAxisSinkStrength(parameters, mycorrhiza);
    try std.testing.expectEqual(@as(f64, 0), mycorrhizal.primary_m);
    try std.testing.expectApproxEqAbs(secondary_parallel, mycorrhizal.secondary_m, 1e-15);
}

test "root metabolism grid workspace is runtime sized and cell independent" {
    var workspace = try plant_root_metabolism.GridWorkspace.init(std.testing.allocator, 4, 19, 7);
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 4), workspace.per_cell.len);
    for (workspace.per_cell) |cell| {
        try std.testing.expectEqual(@as(usize, 19), cell.sink_strengths.len);
        try std.testing.expectEqual(@as(usize, 7), cell.primary_respiration_allocation_fractions.len);
        try std.testing.expectEqual(@as(usize, 19 * 7), cell.withdrawal_sink_fractions.len);
        try std.testing.expectEqual(@as(usize, 7), cell.withdrawn_layers.len);
    }
    workspace.per_cell[0].primary_active[18] = true;
    try workspace.per_cell[0].beginPlantHour(19);
    try workspace.per_cell[0].markPrimaryProcessed(0, 18);
    try workspace.per_cell[0].markSecondaryProcessed(1, 18);
    try workspace.per_cell[0].resetAxes(19);
    try std.testing.expect(!workspace.per_cell[0].primary_active[18]);
    try std.testing.expect(try workspace.per_cell[0].primaryWasProcessed(0, 18));
    try std.testing.expect(try workspace.per_cell[0].secondaryWasProcessed(1, 18));
    try workspace.per_cell[0].beginPlantHour(19);
    try std.testing.expect(!try workspace.per_cell[0].primaryWasProcessed(0, 18));
    try std.testing.expect(!try workspace.per_cell[0].secondaryWasProcessed(1, 18));
    try std.testing.expect(workspace.per_cell[0].sink_strengths.ptr != workspace.per_cell[1].sink_strengths.ptr);
    try std.testing.expectEqual(
        @as(usize, 6 * 19 + 18),
        try workspace.per_cell[0].withdrawalSinkIndex(6, 18),
    );
    try std.testing.expectError(error.RootMetabolismWorkspaceCapacityExceeded, workspace.per_cell[0].resetAxes(20));
}

test "staged primary and secondary axes plant_root_metabolism.state_update one shared mobile-pool transaction" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 2);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 2, 1);
    defer workspace.deinit();
    try workspace.resetAxes(2);
    roots.mobile_carbon_g[0] = 10;
    roots.mobile_nitrogen_g[0] = 1;
    roots.mobile_phosphorus_g[0] = 0.1;
    roots.axis_primary_carbon_g[0] = 1;
    roots.axis_secondary_carbon_g[1] = 1;
    workspace.primary_active[0] = true;
    workspace.secondary_active[1] = true;
    workspace.primary_metabolism[0].root_growth_actual_g_c_per_h = 0.2;
    workspace.primary_metabolism[0].growth_and_respiration_carbon_actual_g_c_per_h = 0.25;
    workspace.primary_metabolism[0].nitrogen_growth_actual_g_n_per_h = 0.02;
    workspace.primary_metabolism[0].phosphorus_growth_actual_g_p_per_h = 0.002;
    workspace.secondary_metabolism[1].root_growth_actual_g_c_per_h = 0.3;
    workspace.secondary_metabolism[1].growth_and_respiration_carbon_actual_g_c_per_h = 0.375;
    workspace.secondary_metabolism[1].nitrogen_growth_actual_g_n_per_h = 0.03;
    workspace.secondary_metabolism[1].phosphorus_growth_actual_g_p_per_h = 0.003;
    const parameters: plant_root_metabolism.StagedLayerStateUpdateParameters = .{
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 20,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 2,
        .next_layer_thickness_m = 0,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 0.5,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    };
    try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 0, &workspace, 2, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 9.375), roots.mobile_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), roots.mobile_nitrogen_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.095), roots.mobile_phosphorus_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), roots.axis_primary_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), roots.axis_secondary_carbon_g[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), roots.axis_primary_length_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), roots.axis_secondary_length_m[1], 1e-15);

    const mobile_carbon_before = roots.mobile_carbon_g[0..1].*;
    const mobile_nitrogen_before = roots.mobile_nitrogen_g[0..1].*;
    const mobile_phosphorus_before = roots.mobile_phosphorus_g[0..1].*;
    const protein_before = roots.protein_carbon_g[0..1].*;
    const respiration_before = roots.actual_respiration_g_c_per_h[0..1].*;
    const oxygen_unlimited_before = roots.respiration_unlimited_by_oxygen_g_c_per_h[0..1].*;
    const carbon_unlimited_before = roots.respiration_unlimited_by_carbon_g_c_per_h[0..1].*;
    const primary_carbon_before = roots.axis_primary_carbon_g[0..2].*;
    const primary_nitrogen_before = roots.axis_primary_nitrogen_g[0..2].*;
    const primary_phosphorus_before = roots.axis_primary_phosphorus_g[0..2].*;
    const primary_length_before = roots.axis_primary_length_m[0..2].*;
    const secondary_carbon_before = roots.axis_secondary_carbon_g[0..2].*;
    const secondary_nitrogen_before = roots.axis_secondary_nitrogen_g[0..2].*;
    const secondary_phosphorus_before = roots.axis_secondary_phosphorus_g[0..2].*;
    const secondary_length_before = roots.axis_secondary_length_m[0..2].*;
    const depth_before = roots.axis_depth_m[0..2].*;
    const secondary_axis_count_total_before = roots.secondary_axis_count_total[0..1].*;
    try workspace.resetAxes(2);
    workspace.primary_active[0] = true;
    workspace.primary_senescence[0].senesced_fraction = 0.5;
    workspace.primary_metabolism[0].growth_and_respiration_carbon_actual_g_c_per_h = 20;
    try std.testing.expectError(error.StagedRootStateUpdateWouldOverdrawPool, plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 0, &workspace, 2, parameters));
    try std.testing.expectEqualSlices(f64, &mobile_carbon_before, roots.mobile_carbon_g[0..1]);
    try std.testing.expectEqualSlices(f64, &mobile_nitrogen_before, roots.mobile_nitrogen_g[0..1]);
    try std.testing.expectEqualSlices(f64, &mobile_phosphorus_before, roots.mobile_phosphorus_g[0..1]);
    try std.testing.expectEqualSlices(f64, &protein_before, roots.protein_carbon_g[0..1]);
    try std.testing.expectEqualSlices(f64, &respiration_before, roots.actual_respiration_g_c_per_h[0..1]);
    try std.testing.expectEqualSlices(f64, &oxygen_unlimited_before, roots.respiration_unlimited_by_oxygen_g_c_per_h[0..1]);
    try std.testing.expectEqualSlices(f64, &carbon_unlimited_before, roots.respiration_unlimited_by_carbon_g_c_per_h[0..1]);
    try std.testing.expectEqualSlices(f64, &primary_carbon_before, roots.axis_primary_carbon_g[0..2]);
    try std.testing.expectEqualSlices(f64, &primary_nitrogen_before, roots.axis_primary_nitrogen_g[0..2]);
    try std.testing.expectEqualSlices(f64, &primary_phosphorus_before, roots.axis_primary_phosphorus_g[0..2]);
    try std.testing.expectEqualSlices(f64, &primary_length_before, roots.axis_primary_length_m[0..2]);
    try std.testing.expectEqualSlices(f64, &secondary_carbon_before, roots.axis_secondary_carbon_g[0..2]);
    try std.testing.expectEqualSlices(f64, &secondary_nitrogen_before, roots.axis_secondary_nitrogen_g[0..2]);
    try std.testing.expectEqualSlices(f64, &secondary_phosphorus_before, roots.axis_secondary_phosphorus_g[0..2]);
    try std.testing.expectEqualSlices(f64, &secondary_length_before, roots.axis_secondary_length_m[0..2]);
    try std.testing.expectEqualSlices(f64, &depth_before, roots.axis_depth_m[0..2]);
    try std.testing.expectEqualSlices(f64, &secondary_axis_count_total_before, roots.secondary_axis_count_total[0..1]);
    try std.testing.expect(!workspace.primary_deficit_active[0]);
}

test "GROSUB primary respiration allocation uses pre-growth RTDP1 and RTLG1" {
    var roots = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    roots.active_root_axis_count[0] = 1;
    roots.deepest_rooted_layer_by_axis[0] = 1;
    roots.current_deepest_rooted_layer_by_plant[0] = 1;
    roots.next_deepest_rooted_layer_by_plant[0] = 1;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 0.5;
    roots.axis_primary_length_m[try roots.layerAxisIndex(0, 0, 0, 0)] = 0.2;
    const tip = try roots.layerAxisIndex(0, 0, 1, 0);
    roots.axis_primary_length_m[tip] = 0.3;
    roots.axis_primary_carbon_g[tip] = 1;
    roots.mobile_carbon_g[try roots.layerIndex(0, 0, 1)] = 10;
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try workspace.resetAxes(1);
    workspace.primary_active[0] = true;
    workspace.primary_metabolism[0].maintenance_respiration_g_c_per_h = 1;
    workspace.primary_metabolism[0].substrate_respiration_actual_g_c_per_h = 1;
    workspace.primary_metabolism[0].substrate_respiration_oxygen_unlimited_g_c_per_h = 1;
    workspace.primary_metabolism[0].growth_and_respiration_carbon_actual_g_c_per_h = 0.1;
    workspace.primary_metabolism[0].root_growth_actual_g_c_per_h = 0.1;
    try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 1, &workspace, 1, .{
        .primary_specific_length_m_per_g_c = 1,
        .secondary_specific_length_m_per_g_c = 0,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 2,
        .next_layer_thickness_m = 0,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), roots.actual_respiration_g_c_per_h[try roots.layerIndex(0, 0, 0)], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), roots.actual_respiration_g_c_per_h[try roots.layerIndex(0, 0, 1)], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), roots.axis_depth_m[try roots.axisIndex(0, 0, 0)], 1e-14);
}

test "GROSUB WSRTL is rebuilt each hour instead of accumulating across hours" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();

    const axis_layer = try roots.layerAxisIndex(0, 0, 0, 0);
    roots.axis_secondary_carbon_g[axis_layer] = 100;
    roots.axis_secondary_nitrogen_g[axis_layer] = 2;
    roots.axis_secondary_phosphorus_g[axis_layer] = 1;
    const parameters: plant_root_metabolism.StagedLayerStateUpdateParameters = .{
        .primary_specific_length_m_per_g_c = 1,
        .secondary_specific_length_m_per_g_c = 1,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 1,
        .next_layer_thickness_m = 0,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 2.5,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 25,
    };

    inline for (0..2) |_| {
        roots.resetGrosubProteinCarbon();
        try std.testing.expectEqual(@as(f64, 0), roots.protein_carbon_g[0]);
        try workspace.resetAxes(1);
        workspace.secondary_active[0] = true;
        try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 0, &workspace, 1, parameters);
        try std.testing.expectEqual(@as(f64, 5), roots.protein_carbon_g[0]);
    }
}

test "production preserves prior WSRTL through UPTAKE then resets it before GROSUB" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_vegetation.zig",
        std.testing.allocator,
        .limited(512 * 1024),
    );
    defer std.testing.allocator.free(source);

    const uptake = std.mem.indexOf(u8, source, "try root_processes.applyRootNutrientUptake(context.*);") orelse
        return error.MissingProductionRootNutrientUptake;
    const reset = std.mem.indexOfPos(u8, source, uptake, "roots.resetGrosubProteinCarbon();") orelse
        return error.MissingProductionGrosubProteinReset;
    const grosub_start = std.mem.indexOfPos(u8, source, reset, "try plant_daily.applyPlantStorageRemobilization(context.*, plant_calendar,") orelse
        return error.MissingProductionGrosubStart;
    const metabolism = std.mem.indexOfPos(u8, source, grosub_start, "try root_processes.applyRootMetabolism(context.*,") orelse
        return error.MissingProductionRootMetabolism;
    try std.testing.expect(uptake < reset);
    try std.testing.expect(reset < grosub_start);
    try std.testing.expect(grosub_start < metabolism);
}

test "GROSUB primary crossing skips a thin intermediate runtime layer" {
    const placement = try plant_root_metabolism.primaryRootExtensionPlacement(2, 0.9, 1.0, 0.5);
    try std.testing.expect(placement.crosses_into_next_layer);
    try std.testing.expectEqual(@as(f64, 0.5), placement.extension_m);
    const next_lower_layer = try plant_root_metabolism.nextLowerRootLayer(&.{ 1, 1.0e-7, 0.5 }, 0, 1.0e-6);
    try std.testing.expectEqual(@as(usize, 2), next_lower_layer);

    var roots = try RootState.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 3);
    defer workspace.deinit();
    try workspace.resetAxes(1);
    const current_root = try roots.layerIndex(0, 0, 0);
    const skipped_root = try roots.layerIndex(0, 0, 1);
    const next_root = try roots.layerIndex(0, 0, next_lower_layer);
    const current_axis = try roots.layerAxisIndex(0, 0, 0, 0);
    const skipped_axis = try roots.layerAxisIndex(0, 0, 1, 0);
    const next_axis = try roots.layerAxisIndex(0, 0, next_lower_layer, 0);
    roots.mobile_carbon_g[current_root] = 8;
    roots.mobile_nitrogen_g[current_root] = 1;
    roots.mobile_phosphorus_g[current_root] = 0.1;
    roots.total_water_potential_megapascal[current_root] = -0.4;
    roots.osmotic_water_potential_megapascal[current_root] = -0.8;
    roots.turgor_water_potential_megapascal[current_root] = 0.4;
    roots.primary_radius_m[current_root] = 0.001;
    roots.axis_primary_carbon_g[current_axis] = 1;
    roots.axis_primary_nitrogen_g[current_axis] = 0.1;
    roots.axis_primary_phosphorus_g[current_axis] = 0.01;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 0.9;
    workspace.primary_active[0] = true;
    workspace.primary_sink_fractions[0] = 0.25;
    workspace.primary_metabolism[0].root_growth_actual_g_c_per_h = 0.2;
    workspace.primary_metabolism[0].nitrogen_growth_actual_g_n_per_h = 0.02;
    workspace.primary_metabolism[0].phosphorus_growth_actual_g_p_per_h = 0.002;
    try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 0, &workspace, 1, .{
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 20,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 1,
        .next_lower_layer = next_lower_layer,
        .next_layer_thickness_m = 0.5,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    });
    try std.testing.expectEqual(@as(f64, 1), roots.axis_primary_carbon_g[current_axis]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), roots.axis_primary_carbon_g[next_axis], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), roots.axis_primary_length_m[next_axis], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_carbon_g[skipped_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_primary_length_m[skipped_axis]);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), roots.axis_depth_m[try roots.axisIndex(0, 0, 0)], 1e-15);
    try std.testing.expectEqual(
        @as(usize, 2),
        roots.deepest_rooted_layer_by_axis[try roots.rootAxisIndex(0, 0)],
    );
    try std.testing.expectApproxEqAbs(@as(f64, 6), roots.mobile_carbon_g[current_root], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), roots.mobile_carbon_g[next_root], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.735), roots.mobile_nitrogen_g[current_root], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.245), roots.mobile_nitrogen_g[next_root], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[skipped_root]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_nitrogen_g[skipped_root]);
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_phosphorus_g[skipped_root]);
    try std.testing.expectEqual(roots.total_water_potential_megapascal[current_root], roots.total_water_potential_megapascal[next_root]);
    try std.testing.expectEqual(roots.primary_radius_m[current_root], roots.primary_radius_m[next_root]);
}

test "GROSUB primary crossing requires extension above ZEROP" {
    const below = try plant_root_metabolism.sourceOrderPrimaryRootExtensionPlacement(5e-7, 0.9999998, 1, 0.5, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5e-7), below.extension_m, 1e-18);
    try std.testing.expect(!below.crosses_into_next_layer);
    const above = try plant_root_metabolism.sourceOrderPrimaryRootExtensionPlacement(2e-6, 0.9999998, 1, 0.5, 1e-6);
    try std.testing.expect(above.crosses_into_next_layer);
}

test "GROSUB negative primary growth consumes secondary roots in tip then upper layer" {
    const result = try plant_root_metabolism.absorbPrimaryDeficitFromSecondaryRoots(
        3.5,
        0.35,
        0.035,
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02, .length_m = 4 },
        .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03, .length_m = 6 },
    );
    try std.testing.expectEqual(@as(f64, 0), result.current.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.current.length_m);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.upper.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.upper.length_m, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), result.residual_carbon_deficit_g_c);
    try std.testing.expectEqual(@as(f64, 0), result.residual_nitrogen_deficit_g_n);
    try std.testing.expectEqual(@as(f64, 0), result.residual_phosphorus_deficit_g_p);

    const exhausted = try plant_root_metabolism.absorbPrimaryDeficitFromSecondaryRoots(
        7,
        0.7,
        0.07,
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02, .length_m = 4 },
        .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03, .length_m = 6 },
    );
    try std.testing.expectEqual(@as(f64, 2), exhausted.residual_carbon_deficit_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), exhausted.residual_nitrogen_deficit_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), exhausted.residual_phosphorus_deficit_g_p, 1e-15);
}

test "live staged GROSUB plant_root_metabolism.state_update absorbs primary senescence from secondary layers first" {
    var roots = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 2);
    defer workspace.deinit();
    try workspace.resetAxes(1);
    const upper_axis = try roots.layerAxisIndex(0, 0, 0, 0);
    const tip_axis = try roots.layerAxisIndex(0, 0, 1, 0);
    roots.axis_primary_carbon_g[tip_axis] = 2;
    roots.axis_primary_nitrogen_g[tip_axis] = 0.2;
    roots.axis_primary_phosphorus_g[tip_axis] = 0.02;
    roots.axis_secondary_carbon_g[tip_axis] = 0.6;
    roots.axis_secondary_nitrogen_g[tip_axis] = 0.06;
    roots.axis_secondary_phosphorus_g[tip_axis] = 0.006;
    roots.axis_secondary_length_m[tip_axis] = 3;
    roots.axis_secondary_carbon_g[upper_axis] = 0.6;
    roots.axis_secondary_nitrogen_g[upper_axis] = 0.06;
    roots.axis_secondary_phosphorus_g[upper_axis] = 0.006;
    roots.axis_secondary_length_m[upper_axis] = 3;
    roots.axis_depth_m[try roots.axisIndex(0, 0, 0)] = 1.5;
    workspace.primary_active[0] = true;
    workspace.primary_senescence[0].senesced_fraction = 0.5;
    try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 1, &workspace, 1, .{
        .primary_specific_length_m_per_g_c = 10,
        .secondary_specific_length_m_per_g_c = 20,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 2,
        .next_layer_thickness_m = 0,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
    });
    try std.testing.expectEqual(@as(f64, 2), roots.axis_primary_carbon_g[tip_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_carbon_g[tip_axis]);
    try std.testing.expectEqual(@as(f64, 0), roots.axis_secondary_length_m[tip_axis]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), roots.axis_secondary_carbon_g[upper_axis], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), roots.axis_secondary_length_m[upper_axis], 1e-15);
    try std.testing.expect(workspace.primary_deficit_active[0]);
}

test "STOMATE annual termination feedback is shared with root metabolism" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try plant_root_metabolism.annualTerminationFeedback(0, 168, 336), 1.0e-12);
    try std.testing.expectEqual(@as(f64, 1), try plant_root_metabolism.annualTerminationFeedback(1, 168, 336));
    try std.testing.expectEqual(@as(f64, 0), try plant_root_metabolism.annualTerminationFeedback(0, 400, 336));
}

test "GROSUB secondary-root litter allocation and plant_root_metabolism.state_update are atomic" {
    const senescence: plant_root_metabolism.SecondaryRootSenescence = .{
        .respiration_oxygen_unlimited_g_c_per_h = 0.1,
        .respiration_actual_g_c_per_h = 0.1,
        .phenological_senescence_g_c_per_h = 0,
        .senesced_fraction = 0.25,
        .recyclable_carbon_g_c = 0.8,
        .recyclable_nitrogen_g_n = 0.08,
        .recyclable_phosphorus_g_p = 0.008,
    };
    const quarter = [_]f64{0.25} ** 4;
    const litter = try plant_root_metabolism.secondaryRootLitter(senescence, 2, 0.2, 0.02, .{ 0.4, 0.6 }, .{ 0.3, 0.7 }, .{ 0.2, 0.8 }, .{
        .woody_carbon = quarter,
        .woody_nitrogen = quarter,
        .woody_phosphorus = quarter,
        .nonwoody_carbon = quarter,
        .nonwoody_nitrogen = quarter,
        .nonwoody_phosphorus = quarter,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), litter.woody_carbon_g_c[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.045), litter.nonwoody_carbon_g_c[0], 1.0e-12);

    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    roots.mobile_carbon_g[0] = 10;
    roots.mobile_nitrogen_g[0] = 1;
    roots.mobile_phosphorus_g[0] = 0.1;
    roots.axis_secondary_carbon_g[0] = 2;
    roots.axis_secondary_nitrogen_g[0] = 0.2;
    roots.axis_secondary_phosphorus_g[0] = 0.02;
    roots.axis_secondary_length_m[0] = 4;
    const metabolism = try plant_root_metabolism.secondaryRootMetabolism(plant_root_metabolism.compatibilitySecondaryRootParameters(), .{
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
    });
    const state_update_inputs: plant_root_metabolism.SecondaryRootStateUpdateInputs = .{
        .metabolism = metabolism,
        .senescence = senescence,
        .root_specific_length_m_per_g_c = 10,
        .root_extension_water_response = 0.8,
        .nonwoody_carbon_fraction = 0.6,
        .nonwoody_nitrogen_fraction = 0.7,
        .nonwoody_phosphorus_fraction = 0.8,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 2,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 20,
    };
    try plant_root_metabolism.state_updateSecondaryRoot(&roots, 0, 0, state_update_inputs);
    try std.testing.expect(roots.axis_secondary_carbon_g[0] < 2);
    try std.testing.expect(roots.actual_respiration_g_c_per_h[0] > 0);
    const mobile_before_failure = roots.mobile_carbon_g[0];
    roots.mobile_carbon_g[0] = 0;
    var failing_inputs = state_update_inputs;
    failing_inputs.senescence.recyclable_carbon_g_c = 0;
    failing_inputs.senescence.recyclable_nitrogen_g_n = 0;
    failing_inputs.senescence.recyclable_phosphorus_g_p = 0;
    try std.testing.expectError(error.SecondaryRootStateUpdateWouldOverdrawPool, plant_root_metabolism.state_updateSecondaryRoot(&roots, 0, 0, failing_inputs));
    try std.testing.expectEqual(@as(f64, 0), roots.mobile_carbon_g[0]);
    try std.testing.expect(mobile_before_failure > 0);
}

test "GROSUB nutrient uptake respiration retains 0.86 coefficient and three limits" {
    const result = NutrientResult{ .demand_g_element = 1, .uptake_g_element = 0.5, .oxygen_unlimited_uptake_g_element = 0.75, .carbon_unlimited_uptake_g_element = 1, .available_g_element = 2 };
    const respiration = try plant_root_metabolism.nutrientUptakeRespiration(&([_]NutrientResult{result} ** 8), 0.86);
    try std.testing.expectApproxEqAbs(@as(f64, 3.44), respiration.actual_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.16), respiration.oxygen_unlimited_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6.88), respiration.carbon_unlimited_g_c, 1.0e-12);
}

test "root respiration plant_root_metabolism.state_update is conservative and rollback safe" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    roots.mobile_carbon_g[0] = 5;
    try plant_root_metabolism.state_update(&roots, 0, .{ .actual_g_c = 2, .oxygen_unlimited_g_c = 3, .carbon_unlimited_g_c = 4 });
    try std.testing.expectEqual(@as(f64, 3), roots.mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), roots.actual_respiration_g_c_per_h[0]);
    try std.testing.expectError(error.InsufficientRootMobileCarbonForRespiration, plant_root_metabolism.state_update(&roots, 0, .{ .actual_g_c = 4, .oxygen_unlimited_g_c = 4, .carbon_unlimited_g_c = 4 }));
    try std.testing.expectEqual(@as(f64, 3), roots.mobile_carbon_g[0]);
}

test "GROSUB primary-root axis scaling retains the larger carbon basis" {
    const decay_limited = try plant_root_metabolism.primaryRootAxisScaling(4, 2, 1, 1);
    const expected_retained = 0.999992087 * 4.0;
    try std.testing.expectApproxEqAbs(expected_retained, decay_limited.retained_root_carbon_g_c_per_plant, 1.0e-15);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, expected_retained, 0.667), decay_limited.primary_axis_count_multiplier, 1.0e-15);

    const biomass_limited = try plant_root_metabolism.primaryRootAxisScaling(1, 18, 3, 1);
    try std.testing.expectEqual(@as(f64, 6), biomass_limited.retained_root_carbon_g_c_per_plant);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, 6, 0.667) * 3, biomass_limited.primary_axis_count_multiplier, 1.0e-15);
}

test "GROSUB primary-root axis scaling clears state without population" {
    const result = try plant_root_metabolism.primaryRootAxisScaling(12, 30, 0, 1);
    try std.testing.expectEqual(@as(f64, 0), result.retained_root_carbon_g_c_per_plant);
    try std.testing.expectEqual(@as(f64, 0), result.primary_axis_count_multiplier);
}

test "GROSUB primary-root axis scaling rejects invalid state" {
    try std.testing.expectError(error.InvalidPrimaryRootAxisScalingInput, plant_root_metabolism.primaryRootAxisScaling(-1, 1, 1, 1));
    try std.testing.expectError(error.InvalidPrimaryRootAxisScalingInput, plant_root_metabolism.primaryRootAxisScaling(1, 1, 1, 0));
    try std.testing.expectError(error.InvalidPrimaryRootAxisScalingInput, plant_root_metabolism.primaryRootAxisScaling(1, std.math.nan(f64), 1, 1));
}

test "GROSUB rebuilds primary and secondary axis counts from accepted root geometry" {
    try std.testing.expectEqual(
        @as(f64, 9),
        try plant_root_metabolism.sourceOrderSecondaryAxisCount(2, 3, 0.5),
    );

    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var workspace = try plant_root_metabolism.AxisWorkspace.init(std.testing.allocator, 1, 1);
    defer workspace.deinit();
    try workspace.resetAxes(1);
    workspace.secondary_active[0] = true;

    try plant_root_metabolism.state_updateStagedLayerAxes(&roots, 0, 0, 0, &workspace, 1, .{
        .primary_specific_length_m_per_g_c = 0,
        .secondary_specific_length_m_per_g_c = 0,
        .plant_population_count = 1,
        .seeding_depth_m = 0,
        .current_layer_bottom_depth_m = 0.5,
        .next_layer_thickness_m = 0,
        .extension_presence_threshold_m = 0,
        .root_extension_water_response = 1,
        .nonwoody_carbon_fraction = 1,
        .nonwoody_nitrogen_fraction = 1,
        .nonwoody_phosphorus_fraction = 1,
        .protein_carbon_per_nitrogen_g_c_per_g_n = 0,
        .protein_carbon_per_phosphorus_g_c_per_g_p = 0,
        .primary_axis_count_multiplier = 3,
        .secondary_root_branching_per_m = 2,
        .current_layer_thickness_m = 0.5,
    });
    try std.testing.expectEqual(@as(f64, 3), roots.axis_primary_count[0]);
    try std.testing.expectEqual(@as(f64, 9), roots.axis_secondary_count[0]);
    try std.testing.expectEqual(@as(f64, 9), roots.secondary_axis_count_total[0]);
}

test "GROSUB preserves dormant and dead RTN1 RTNL state by gating before reset" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/root_processes_metabolism.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const gate = std.mem.indexOf(
        u8,
        source,
        "if (!context.plant_phenology.*.?.active[plant] or roots.roots_dead[plant]) continue;",
    ) orelse return error.MissingDormantDeadRootMetabolismGate;
    const reset = std.mem.indexOfPos(
        u8,
        source,
        gate,
        "try roots.resetGrosubAxisCountAggregates(plant);",
    ) orelse return error.MissingGrosubAxisCountReset;
    try std.testing.expect(gate < reset);
}

test "production GROSUB captures RTDP1 before growth and reuses it for withdrawal selection" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/root_processes_metabolism.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);

    const capture = std.mem.indexOf(
        u8,
        source,
        "workspace.pre_update_primary_depth_m[axis] = primary_depth_m;",
    ) orelse return error.MissingPreUpdateRootDepthCapture;
    const growth = std.mem.indexOfPos(
        u8,
        source,
        capture,
        "try ecosys.plant_root_metabolism.state_updateStagedLayerAxes(",
    ) orelse return error.MissingRootGrowthStateUpdate;
    const selection = std.mem.indexOfPos(
        u8,
        source,
        growth,
        "workspace.pre_update_primary_depth_m[axis],",
    ) orelse return error.MissingPreUpdateWithdrawalDepth;
    try std.testing.expect(capture < growth);
    try std.testing.expect(growth < selection);
}
