//! Tests for `photosynthesis.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const branch_organ_growth_state_update = @import("../plant/growth/branch_organ_growth_state_update.zig");
const c4_leaf_nonstructural_carbon_senescence = @import("../canopy/leaf/c4_nonstructural_carbon_senescence.zig");
const c4_mesophyll_bundle_exchange = @import("../canopy/photosynthesis/c4_mesophyll_bundle_exchange.zig");
const internode_senescence_state_update = @import("../canopy/sheath/internode_senescence_state_update.zig");
const leaf_node_growth_state_update = @import("../canopy/leaf/node_growth_state_update.zig");
const node_senescence_cascade_progress = @import("../plant/growth/node_senescence_cascade_progress.zig");
const node_senescence_remobilization_request = @import("../plant/growth/node_senescence_remobilization_request.zig");
const perennial_stalk_senescence_setup = @import("../plant/growth/perennial_stalk_senescence_setup.zig");
const reserve_maintenance_respiration = @import("../plant/growth/reserve_maintenance_respiration.zig");
const residual_stalk_senescence_state_update = @import("../plant/growth/residual_stalk_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../plant/growth/residual_stalk_senescence_request.zig");
const shoot_recycling_fraction = @import("../plant/growth/shoot_recycling_fraction.zig");
const shoot_total_senescence_setup = @import("../plant/growth/shoot_total_senescence_setup.zig");
const std = @import("std");
const canopy_photosynthesis = @import("../canopy/photosynthesis/photosynthesis.zig");
test "reconstruction preserves seed standing-dead charcoal and live acclimation owners" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    state.plant_seed_storage_carbon_g[0] = 7;
    state.plant_seed_storage_nitrogen_g[0] = 0.7;
    state.plant_seed_storage_phosphorus_g[0] = 0.07;
    state.plant_standing_dead_carbon_g[0] = 10;
    state.plant_standing_dead_nitrogen_g[0] = 1;
    state.plant_standing_dead_phosphorus_g[0] = 0.1;
    state.plant_charcoal_carbon_g[0] = 3;
    state.plant_charcoal_nitrogen_g[0] = 0.3;
    state.plant_charcoal_phosphorus_g[0] = 0.03;
    state.plant_standing_dead_height_m[0] = 1.5;
    state.plant_standing_dead_aerodynamic_temperature_k[0] = 280;
    state.plant_standing_dead_aerodynamic_vapor_pressure_kpa[0] = 0.8;
    state.plant_standing_dead_surface_temperature_k[0] = 281;
    state.plant_thermal_adaptation_offset_c[0] = 4;
    state.plant_leafout_threshold_c[0] = -7;
    state.plant_leafoff_threshold_c[0] = 13;
    state.plant_seed_set_high_temperature_c[0] = 31;
    state.plant_standing_dead_carbon_by_kinetic_g[0..4].* = .{ 1, 2, 3, 4 };
    state.plant_standing_dead_nitrogen_by_kinetic_g[0..4].* = .{ 0.1, 0.2, 0.3, 0.4 };
    state.plant_standing_dead_phosphorus_by_kinetic_g[0..4].* = .{ 0.01, 0.02, 0.03, 0.04 };
    const carried = try canopy_photosynthesis.capturePersistentReseedInventories(&state, 0);
    try state.clearPlantForReconstruction(0);
    try canopy_photosynthesis.restorePersistentReseedInventories(&state, 0, carried);
    try std.testing.expectApproxEqAbs(@as(f64, 7), state.plant_seed_storage_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.plant_standing_dead_carbon_g[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.plant_charcoal_carbon_g[0], 1e-12);
    try std.testing.expectEqual([4]f64{ 1, 2, 3, 4 }, state.plant_standing_dead_carbon_by_kinetic_g[0..4].*);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), state.plant_standing_dead_height_m[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 281), state.plant_standing_dead_surface_temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.plant_thermal_adaptation_offset_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -7), state.plant_leafout_threshold_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 13), state.plant_leafoff_threshold_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 31), state.plant_seed_set_high_temperature_c[0], 1e-12);
}

test "GROSUB zero-area leaf still advances canopy height to capped leaf base" {
    var area = [_]f64{ 9, 9 };
    var carbon = [_]f64{ 9, 9 };
    var nitrogen = [_]f64{ 9, 9 };
    var phosphorus = [_]f64{ 9, 9 };
    const height_m = try canopy_photosynthesis.allocateLeafAcrossCanopyLayers(0, 0, 0, 0, 100, 2, 0.8, 0.4, 1, &.{ 0, 0.5, 1.01 }, &.{ 0.2, 0.5, 0.8, 1 }, &.{ 0.1, 0.2, 0.3, 0.4 }, .{ .area_m2 = &area, .carbon_g = &carbon, .nitrogen_g = &nitrogen, .phosphorus_g = &phosphorus });
    try std.testing.expectEqual(@as(f64, 1.01), height_m);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &area);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &carbon);
}

test "production canopy water response retains source values above one" {
    const response = try canopy_photosynthesis.canopyWaterGrowthResponse(false, 0.5, -1.0, 2.0, 2.0);
    try std.testing.expectApproxEqAbs(std.math.exp(1.0), response.stomatal_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(std.math.exp(0.2), response.growth_fraction, 1.0e-15);
    try std.testing.expect(response.water_potential_expansion_fraction > 1);
}

test "canopy topology accepts arbitrary runtime branch node and sample counts" {
    const branch_counts = [_]usize{ 2, 1, 0, 3, 1, 2 };
    const node_counts = [_]usize{ 1, 3, 2, 0, 1, 2, 2, 1, 2 };
    const sample_counts = [_]usize{ 16, 3, 8, 1, 4, 2, 9, 5, 1, 7, 3, 2, 6, 1 };
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 2, 3, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    try std.testing.expectEqual(6, state.plant_carboxylation_umol_per_s.len);
    try std.testing.expectEqual(9, state.branch_c3_feedback_fraction.len);
    try std.testing.expectEqual(14, state.node_co2_limited_carboxylation_umol_per_m2_s.len);
    try std.testing.expectEqual(68, state.sample_carboxylation_umol_per_s.len);
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 3, .end = 3 }, try state.branchRange(2));
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 7, .end = 9 }, try state.nodeRange(5));
    try state.validateFinite();
}

test "replant canopy reconstruction clears all compact domains for only one plant" {
    const branch_counts = [_]usize{ 1, 2 };
    const node_counts = [_]usize{ 1, 1, 2 };
    const sample_counts = [_]usize{ 2, 1, 2, 1 };
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 2, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    @memset(state.plant_mobile_carbon_g, 1);
    @memset(state.plant_standing_dead_carbon_by_kinetic_g, 2);
    @memset(state.branch_leaf_carbon_g, 3);
    @memset(state.branch_salt_content_by_species_mol, 4);
    @memset(state.node_leaf_carbon_g, 5);
    @memset(state.sample_leaf_carbon_g, 6);

    try state.clearPlantForReconstruction(1);

    try std.testing.expectEqual(@as(f64, 1), state.plant_mobile_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.plant_mobile_carbon_g[1]);
    try std.testing.expectEqual(@as(f64, 2), state.plant_standing_dead_carbon_by_kinetic_g[3]);
    for (state.plant_standing_dead_carbon_by_kinetic_g[4..8]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 3), state.branch_leaf_carbon_g[0]);
    for (state.branch_leaf_carbon_g[1..3]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 4), state.branch_salt_content_by_species_mol[7]);
    for (state.branch_salt_content_by_species_mol[8..24]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 5), state.node_leaf_carbon_g[0]);
    for (state.node_leaf_carbon_g[1..4]) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 6), state.sample_leaf_carbon_g[1]);
    for (state.sample_leaf_carbon_g[2..6]) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "replant topology compaction retains one branch and node without changing neighbors" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 2, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 2, 3 });
    defer state.deinit();
    _ = try state.appendNode(0, 4);
    _ = try state.appendBranch(0, &.{5});
    @memset(state.plant_mobile_carbon_g, 7);
    state.branch_leaf_carbon_g[state.branch_leaf_carbon_g.len - 1] = 11;
    const neighbor_branch_before = state.branch_leaf_carbon_g[(try state.branchRange(1)).first];
    const neighbor_sample_count = (try state.sampleRange((try state.nodeRange((try state.branchRange(1)).first)).first)).end -
        (try state.sampleRange((try state.nodeRange((try state.branchRange(1)).first)).first)).first;

    try state.compactPlantToInitialTopology(0);

    const first = try state.branchRange(0);
    const neighbor = try state.branchRange(1);
    try std.testing.expectEqual(@as(usize, 1), first.end - first.first);
    try std.testing.expectEqual(@as(usize, 1), (try state.nodeRange(first.first)).end - (try state.nodeRange(first.first)).first);
    try std.testing.expectEqual(@as(usize, 1), neighbor.end - neighbor.first);
    try std.testing.expectEqual(neighbor_sample_count, (try state.sampleRange((try state.nodeRange(neighbor.first)).first)).end - (try state.sampleRange((try state.nodeRange(neighbor.first)).first)).first);
    try std.testing.expectEqual(neighbor_branch_before, state.branch_leaf_carbon_g[neighbor.first]);
    try std.testing.expectEqual(@as(f64, 7), state.plant_mobile_carbon_g[1]);
}

test "GROSUB runtime canopy-layer leaf allocation conserves area and C N P" {
    var area = [_]f64{0} ** 3;
    var carbon = [_]f64{0} ** 3;
    var nitrogen = [_]f64{0} ** 3;
    var phosphorus = [_]f64{0} ** 3;
    const height = try canopy_photosynthesis.allocateLeafAcrossCanopyLayers(2, 4, 0.4, 0.08, 100, 2, 0.2, 0.05, 2, &.{ 0, 0.25, 0.5, 2 }, &.{ 0.2, 0.5, 0.8, 1.0 }, &.{ 0.1, 0.2, 0.3, 0.4 }, .{ .area_m2 = &area, .carbon_g = &carbon, .nitrogen_g = &nitrogen, .phosphorus_g = &phosphorus });
    try std.testing.expect(height > 0.25);
    var area_sum: f64 = 0;
    var carbon_sum: f64 = 0;
    var nitrogen_sum: f64 = 0;
    var phosphorus_sum: f64 = 0;
    for (area, carbon, nitrogen, phosphorus) |a, c, n, p| {
        area_sum += a;
        carbon_sum += c;
        nitrogen_sum += n;
        phosphorus_sum += p;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 2), area_sum, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4), carbon_sum, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), nitrogen_sum, 1.0e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), phosphorus_sum, 1.0e-14);
}

test "GROSUB stalk geometry and runtime layer allocation conserve surface area" {
    var layer_area = [_]f64{0} ** 3;
    const result = try canopy_photosynthesis.allocateStalkAcrossCanopyLayers(20, 3, 10, 1.0e-6, 0.1, 1.6, true, false, &.{ 0, 0.5, 1.0, 2.0 }, &layer_area);
    try std.testing.expect(result.radius_m > 0);
    try std.testing.expectEqual(@as(f64, 20), result.sapwood_carbon_g);
    var sum: f64 = 0;
    for (layer_area) |area| sum += area;
    try std.testing.expectApproxEqAbs(result.surface_area_m2, sum, 1.0e-14);
    var no_height_area = [_]f64{1} ** 3;
    const no_height = try canopy_photosynthesis.allocateStalkAcrossCanopyLayers(20, 3, 10, 1.0e-6, 0.1, 0.1, false, false, &.{ 0, 0.5, 1.0, 2.0 }, &no_height_area);
    try std.testing.expectEqual(@as(f64, 3), no_height.sapwood_carbon_g);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, &no_height_area);
}

test "GROSUB potential sites and post-anthesis seed number retain source limitations" {
    const sites = try canopy_photosynthesis.accumulatePotentialSeedSites(10, true, false, 20, 100, 5, 3, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 13), sites, 1.0e-15);
    const result = try canopy_photosynthesis.updateSeedNumberAndSize(.{ .anthesis_started = true, .grain_fill_started = true, .final_seed_number_set = false, .maximum_seed_size_set = false, .mobile_carbon_concentration_g_per_g = 0.2, .mobile_nitrogen_concentration_g_per_g = 0.1, .mobile_phosphorus_concentration_g_per_g = 0.05, .carbon_half_saturation_g_per_g = 0.2, .nitrogen_half_saturation_g_per_g = 0.1, .phosphorus_half_saturation_g_per_g = 0.05, .canopy_temperature_c = 42, .chilling_temperature_c = 5, .high_temperature_c = 40, .seed_loss_fraction_per_c_h = 0.01, .timestep_h = 1, .water_growth_fraction = 1, .reproductive_stage_increment = 0.1, .maximum_seeds_per_site = 4, .potential_site_count = 13, .current_seed_count = 10, .maximum_individual_seed_carbon_g = 0.5, .current_individual_seed_carbon_g = 0.1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.nutrient_set_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), result.thermal_loss_fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 12.4), result.seed_count, 1.0e-14);
    try std.testing.expect(result.individual_seed_carbon_g > 0.1);
}

test "GROSUB end of maximum seed-size setting closes the whole seed-set block" {
    const result = try canopy_photosynthesis.updateSeedNumberAndSize(.{
        .anthesis_started = true,
        .grain_fill_started = true,
        .final_seed_number_set = false,
        .maximum_seed_size_set = true,
        .mobile_carbon_concentration_g_per_g = 0,
        .mobile_nitrogen_concentration_g_per_g = 0,
        .mobile_phosphorus_concentration_g_per_g = 0,
        .carbon_half_saturation_g_per_g = 0,
        .nitrogen_half_saturation_g_per_g = 0,
        .phosphorus_half_saturation_g_per_g = 0,
        .canopy_temperature_c = 50,
        .chilling_temperature_c = 5,
        .high_temperature_c = 40,
        .seed_loss_fraction_per_c_h = 1,
        .timestep_h = 1,
        .water_growth_fraction = 1,
        .reproductive_stage_increment = 1,
        .maximum_seeds_per_site = 10,
        .potential_site_count = 10,
        .current_seed_count = 7,
        .maximum_individual_seed_carbon_g = 1,
        .current_individual_seed_carbon_g = 0.4,
    });
    try std.testing.expectEqual(@as(f64, 0), result.nutrient_set_fraction);
    try std.testing.expectEqual(@as(f64, 0), result.thermal_loss_fraction);
    try std.testing.expectEqual(@as(f64, 7), result.seed_count);
    try std.testing.expectEqual(@as(f64, 0.4), result.individual_seed_carbon_g);
}

test "GROSUB impossible negative seed count fails instead of silently clamping" {
    try std.testing.expectError(error.NegativeSeedCount, canopy_photosynthesis.updateSeedNumberAndSize(.{
        .anthesis_started = true,
        .grain_fill_started = false,
        .final_seed_number_set = false,
        .maximum_seed_size_set = false,
        .mobile_carbon_concentration_g_per_g = 0,
        .mobile_nitrogen_concentration_g_per_g = 0,
        .mobile_phosphorus_concentration_g_per_g = 0,
        .carbon_half_saturation_g_per_g = 1,
        .nitrogen_half_saturation_g_per_g = 1,
        .phosphorus_half_saturation_g_per_g = 1,
        .canopy_temperature_c = 100,
        .chilling_temperature_c = 5,
        .high_temperature_c = 40,
        .seed_loss_fraction_per_c_h = 1,
        .timestep_h = 1,
        .water_growth_fraction = 1,
        .reproductive_stage_increment = 0,
        .maximum_seeds_per_site = 1,
        .potential_site_count = 1,
        .current_seed_count = 1,
        .maximum_individual_seed_carbon_g = 1,
        .current_individual_seed_carbon_g = 0,
    }));
}

test "branch insertion atomically preserves compact topology state" {
    const branch_counts = [_]usize{ 1, 1 };
    const node_counts = [_]usize{ 1, 1 };
    const sample_counts = [_]usize{ 2, 1 };
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 2, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_c3_feedback_fraction[0] = 0.4;
    state.branch_c3_feedback_fraction[1] = 0.8;
    state.node_co2_limited_carboxylation_umol_per_m2_s[1] = 12;
    state.sample_carboxylation_umol_per_s[2] = 7;
    const new_samples = [_]usize{ 3, 4 };
    try std.testing.expectEqual(@as(usize, 1), try state.appendBranch(0, &new_samples));
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 0, .end = 2 }, try state.branchRange(0));
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 2, .end = 3 }, try state.branchRange(1));
    try std.testing.expectEqual(@as(usize, 3), state.branch_c3_feedback_fraction.len);
    try std.testing.expectEqual(@as(usize, 4), state.node_co2_limited_carboxylation_umol_per_m2_s.len);
    try std.testing.expectEqual(@as(usize, 10), state.sample_carboxylation_umol_per_s.len);
    try std.testing.expectEqual(0.4, state.branch_c3_feedback_fraction[0]);
    try std.testing.expectEqual(0.8, state.branch_c3_feedback_fraction[2]);
    try std.testing.expectEqual(12, state.node_co2_limited_carboxylation_umol_per_m2_s[3]);
    try std.testing.expectEqual(7, state.sample_carboxylation_umol_per_s[9]);
}

test "node insertion preserves following runtime node and sample state" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 2, &.{ 1, 1 }, &.{ 1, 1 }, &.{ 2, 1 });
    defer state.deinit();
    state.branch_leaf_carbon_g[1] = 4;
    state.node_leaf_carbon_g[0] = 1;
    state.node_leaf_carbon_g[1] = 2;
    state.sample_carboxylation_umol_per_s[2] = 7;
    try std.testing.expectEqual(@as(usize, 1), try state.appendNode(0, 3));
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 0, .end = 2 }, try state.nodeRange(0));
    try std.testing.expectEqual(canopy_photosynthesis.Range{ .first = 2, .end = 3 }, try state.nodeRange(1));
    try std.testing.expectEqual(@as(usize, 6), state.sample_carboxylation_umol_per_s.len);
    try std.testing.expectEqual(@as(f64, 1), state.node_leaf_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_leaf_carbon_g[1]);
    try std.testing.expectEqual(@as(f64, 2), state.node_leaf_carbon_g[2]);
    try std.testing.expectEqual(@as(f64, 7), state.sample_carboxylation_umol_per_s[5]);
    try std.testing.expectEqual(@as(f64, 4), state.branch_leaf_carbon_g[1]);
}

test "GROSUB branch pools and C4 transfer conserve internal carbon" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_mobile_carbon_g[0] = 2;
    state.branch_mobile_nitrogen_g[0] = 0.2;
    state.branch_mobile_phosphorus_g[0] = 0.03;
    try canopy_photosynthesis.updateBranchMobilePools(&state, 0, .{ .fixed_carbon_g = 1, .maintenance_respiration_demand_g_c = 0.4, .available_respirable_carbon_g_c = 0.25, .growth_and_respiration_g_c = 0.5, .nitrogen_assimilation_respiration_g_c = 0.1, .assimilated_nitrogen_g = 0.02, .canopy_ammonia_exchange_g_n = 0.005, .assimilated_phosphorus_g = 0.01 });
    try std.testing.expectApproxEqAbs(2.15, state.branch_mobile_carbon_g[0], 1e-14);
    try std.testing.expectApproxEqAbs(0.185, state.branch_mobile_nitrogen_g[0], 1e-14);
    try std.testing.expectApproxEqAbs(0.02, state.branch_mobile_phosphorus_g[0], 1e-14);

    state.node_leaf_carbon_g[0] = 10;
    state.node_c3_nonstructural_carbon_g[0] = 0.5;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 0.8;
    state.node_bundle_sheath_co2_carbon_g[0] = 1e-5;
    state.node_bundle_sheath_bicarbonate_carbon_g[0] = 2e-5;
    const before = state.node_c3_nonstructural_carbon_g[0] + state.node_c4_mesophyll_nonstructural_carbon_g[0] + state.node_bundle_sheath_co2_carbon_g[0] + state.node_bundle_sheath_bicarbonate_carbon_g[0];
    var parameters = canopy_photosynthesis.sourceC4CarbonParameters();
    parameters.decarboxylated_co2_fraction = 0.7;
    const expected_exchange = try c4_mesophyll_bundle_exchange.exchange(.{
        .bundle_sheath_nonstructural_carbon_g_c = 0.5,
        .mesophyll_nonstructural_carbon_g_c = 0.8,
        .bundle_sheath_fixation_g_c_per_timestep = 0.01,
        .mesophyll_fixation_g_c_per_timestep = 0.02,
        .leaf_carbon_g_c = 10,
        .bundle_sheath_water_g_h2o_per_g_c = parameters.bundle_sheath_water_g_per_g_c,
        .mesophyll_water_g_h2o_per_g_c = parameters.mesophyll_water_g_per_g_c,
        .timestep_h = 0.1,
    });
    const fluxes = try canopy_photosynthesis.advanceC4CarbonPools(&state, 0, 0.02, 0.01, 10, parameters, 0.1);
    try std.testing.expectEqual(expected_exchange.mesophyll_to_bundle_sheath_carbon_g_c, fluxes.mesophyll_to_bundle_sheath_g_c);
    const after = state.node_c3_nonstructural_carbon_g[0] + state.node_c4_mesophyll_nonstructural_carbon_g[0] + state.node_bundle_sheath_co2_carbon_g[0] + state.node_bundle_sheath_bicarbonate_carbon_g[0];
    try std.testing.expectApproxEqAbs(before + 0.02 - 0.01 - fluxes.bundle_sheath_co2_leakage_g_c, after, 1e-13);
}

test "GROSUB leaf growth uses all runtime concurrent nodes without a ring" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{30};
    const sample_counts = [_]usize{0} ** 30;
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    try canopy_photosynthesis.distributeLeafGrowth(&state, 0, 29, 0, 5, .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.02 }, 2, 10, 1, 0.02, 0.01, 1, 0, 1);
    for (0..25) |node| try std.testing.expectEqual(0, state.node_leaf_carbon_g[node]);
    for (25..30) |node| try std.testing.expectApproxEqAbs(0.2, state.node_leaf_carbon_g[node], 1e-15);
    try std.testing.expectApproxEqAbs(0.02, state.branch_leaf_area_m2[0], 1e-15);
}

test "GROSUB organ partition and branch state_update preserve all C N P products" {
    const partition = [canopy_photosynthesis.organ_count]f64{ 0.2, 0.1, 0.2, 0.15, 0.1, 0.1, 0.15 };
    const yields = [canopy_photosynthesis.organ_count]f64{ 0.8, 0.7, 0.75, 0.9, 0.7, 0.65, 0.85 };
    const n_to_c = [canopy_photosynthesis.organ_count]f64{ 0.04, 0.02, 0.01, 0.015, 0.012, 0.02, 0.015 };
    const p_to_c = [canopy_photosynthesis.organ_count]f64{ 0.004, 0.002, 0.001, 0.0015, 0.0012, 0.002, 0.0015 };
    const growth = try canopy_photosynthesis.calculateOrganGrowth(10, partition, yields, n_to_c, p_to_c, 0.25, 0.5, 0.8);
    try std.testing.expectApproxEqAbs(1.6, growth.value(.leaf).carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(1.6 * 0.04 * 0.625, growth.value(.leaf).nitrogen_g, 1e-15);
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{0};
    const sample_counts = [_]usize{};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    try canopy_photosynthesis.applyBranchOrganGrowth(&state, 0, growth);
    try std.testing.expectApproxEqAbs(growth.value(.leaf).carbon_g, state.branch_leaf_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(growth.value(.ear).phosphorus_g, state.branch_ear_phosphorus_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(growth.value(.reserve).carbon_g, state.branch_reserve_carbon_g[0], 1e-15);
    try std.testing.expectEqual(0, state.branch_grain_carbon_g[0]);
}

test "organ growth state_update is atomic when a destination overflows" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    state.branch_leaf_carbon_g[0] = 2;
    state.branch_sheath_carbon_g[0] = std.math.floatMax(f64);
    var growth: canopy_photosynthesis.OrganGrowth = .{ .carbon_g = @splat(0), .nitrogen_g = @splat(0), .phosphorus_g = @splat(0), .total_shoot_carbon_production_g = 2 };
    growth.carbon_g[@intFromEnum(canopy_photosynthesis.Organ.leaf)] = 1;
    growth.carbon_g[@intFromEnum(canopy_photosynthesis.Organ.sheath)] = std.math.floatMax(f64);
    try std.testing.expectError(error.InvalidBranchOrganGrowthTransaction, canopy_photosynthesis.applyBranchOrganGrowth(&state, 0, growth));
    try std.testing.expectEqual(@as(f64, 2), state.branch_leaf_carbon_g[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), state.branch_sheath_carbon_g[0]);
}

test "branch mobile pool rejects sub-legacy-tolerance overdraw without mutation" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    try std.testing.expectError(
        error.BranchMobilePoolExhausted,
        canopy_photosynthesis.updateBranchMobilePools(&state, 0, .{
            .fixed_carbon_g = -5.0e-13,
            .maintenance_respiration_demand_g_c = 0,
            .available_respirable_carbon_g_c = 0,
            .growth_and_respiration_g_c = 0,
            .nitrogen_assimilation_respiration_g_c = 0,
            .assimilated_nitrogen_g = 0,
            .canopy_ammonia_exchange_g_n = 0,
            .assimilated_phosphorus_g = 0,
        }),
    );
    try std.testing.expectEqual(@as(f64, 0), state.branch_mobile_carbon_g[0]);
}
