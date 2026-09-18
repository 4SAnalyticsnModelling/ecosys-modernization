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
test "GROSUB C4 intermediate retention uses host mobile carbon ratio" {
    try std.testing.expectEqual(@as(f64, 0.25), try canopy_photosynthesis.sourceOrderC4IntermediateRetention(true, 4, 1, 1.0e-12));
    try std.testing.expectEqual(@as(f64, 1), try canopy_photosynthesis.sourceOrderC4IntermediateRetention(false, 4, 1, 1.0e-12));
    try std.testing.expectEqual(@as(f64, 1), try canopy_photosynthesis.sourceOrderC4IntermediateRetention(true, 1.0e-12, 0, 1.0e-12));
}

test "GROSUB layer leaf harvest reconciles sample node branch and products" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{1};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.sample_leaf_area_m2[0] = 2;
    state.sample_exposed_leaf_area_m2[0] = 1;
    state.sample_stalk_area_m2[0] = 2;
    state.sample_leaf_carbon_g[0] = 4;
    state.sample_leaf_nitrogen_g[0] = 0.4;
    state.sample_leaf_phosphorus_g[0] = 0.04;
    state.node_leaf_area_m2[0] = 2;
    state.node_leaf_carbon_g[0] = 4;
    state.node_leaf_nitrogen_g[0] = 0.4;
    state.node_leaf_phosphorus_g[0] = 0.04;
    state.node_leaf_protein_g[0] = 1;
    state.branch_leaf_area_m2[0] = 2;
    state.branch_leaf_carbon_g[0] = 4;
    state.branch_leaf_nitrogen_g[0] = 0.4;
    state.branch_leaf_phosphorus_g[0] = 0.04;
    const products = try canopy_photosynthesis.harvestLeafLayerSample(&state, 0, 0, 0, .{ .remaining_fraction = 0.5, .unexported_fraction = 0.8, .height_below_cut_fraction = 0.5 }, .{ 0.25, 0.75 }, .{ 0.2, 0.8 }, .{ 0.1, 0.9 }, true);
    const exported_c = products.foliar.ecosystem_export.carbon_g + products.woody.ecosystem_export.carbon_g;
    const litter_c = products.foliar.litter.carbon_g + products.woody.litter.carbon_g;
    const exported_n = products.foliar.ecosystem_export.nitrogen_g + products.woody.ecosystem_export.nitrogen_g;
    const litter_n = products.foliar.litter.nitrogen_g + products.woody.litter.nitrogen_g;
    const exported_p = products.foliar.ecosystem_export.phosphorus_g + products.woody.ecosystem_export.phosphorus_g;
    const litter_p = products.foliar.litter.phosphorus_g + products.woody.litter.phosphorus_g;
    try std.testing.expectApproxEqAbs(4.0, state.sample_leaf_carbon_g[0] + exported_c + litter_c, 1e-15);
    try std.testing.expectApproxEqAbs(0.4, state.sample_leaf_nitrogen_g[0] + exported_n + litter_n, 1e-15);
    try std.testing.expectApproxEqAbs(0.04, state.sample_leaf_phosphorus_g[0] + exported_p + litter_p, 1e-15);
    try std.testing.expectEqual(state.sample_leaf_carbon_g[0], state.node_leaf_carbon_g[0]);
    try std.testing.expectEqual(state.node_leaf_carbon_g[0], state.branch_leaf_carbon_g[0]);
    try std.testing.expectApproxEqAbs(0.5, state.node_leaf_protein_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, state.sample_stalk_area_m2[0], 1e-15);
}

test "leaf harvest rejects sub-legacy-tolerance aggregate overdraw atomically" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{1};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.sample_leaf_area_m2[0] = 1;
    state.sample_exposed_leaf_area_m2[0] = 0.5;
    state.sample_stalk_area_m2[0] = 0.25;
    state.sample_leaf_carbon_g[0] = 1;
    state.sample_leaf_nitrogen_g[0] = 0.1;
    state.sample_leaf_phosphorus_g[0] = 0.01;
    state.node_leaf_area_m2[0] = 1;
    state.node_leaf_carbon_g[0] = 1 - 5e-13;
    state.node_leaf_nitrogen_g[0] = 0.1;
    state.node_leaf_phosphorus_g[0] = 0.01;
    state.node_leaf_protein_g[0] = 0.2;
    state.branch_leaf_area_m2[0] = 1;
    state.branch_leaf_carbon_g[0] = 1;
    state.branch_leaf_nitrogen_g[0] = 0.1;
    state.branch_leaf_phosphorus_g[0] = 0.01;
    const before = .{
        state.sample_leaf_area_m2[0],
        state.sample_exposed_leaf_area_m2[0],
        state.sample_stalk_area_m2[0],
        state.sample_leaf_carbon_g[0],
        state.node_leaf_area_m2[0],
        state.node_leaf_carbon_g[0],
        state.node_leaf_protein_g[0],
        state.branch_leaf_area_m2[0],
        state.branch_leaf_carbon_g[0],
    };
    try std.testing.expectError(error.LeafHarvestWouldOverdrawAggregate, canopy_photosynthesis.harvestLeafLayerSample(
        &state,
        0,
        0,
        0,
        .{ .remaining_fraction = 0, .unexported_fraction = 1, .height_below_cut_fraction = 0 },
        .{ 0.25, 0.75 },
        .{ 0.2, 0.8 },
        .{ 0.1, 0.9 },
        true,
    ));
    try std.testing.expectEqualDeep(before, .{
        state.sample_leaf_area_m2[0],
        state.sample_exposed_leaf_area_m2[0],
        state.sample_stalk_area_m2[0],
        state.sample_leaf_carbon_g[0],
        state.node_leaf_area_m2[0],
        state.node_leaf_carbon_g[0],
        state.node_leaf_protein_g[0],
        state.branch_leaf_area_m2[0],
        state.branch_leaf_carbon_g[0],
    });
}

test "GROSUB node sheath harvest conserves elements and truncates at cutting plane" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_height_m[0] = 1;
    state.node_sheath_height_m[0] = 2;
    state.node_sheath_carbon_g[0] = 2;
    state.node_sheath_nitrogen_g[0] = 0.2;
    state.node_sheath_phosphorus_g[0] = 0.02;
    state.node_sheath_protein_g[0] = 0.5;
    state.branch_sheath_carbon_g[0] = 2;
    state.branch_sheath_nitrogen_g[0] = 0.2;
    state.branch_sheath_phosphorus_g[0] = 0.02;
    const products = try canopy_photosynthesis.harvestNodeSheath(&state, 0, 0, 0.5, 0.8, .{ 0.25, 0.75 }, .{ 0.2, 0.8 }, .{ 0.1, 0.9 }, true, 2);
    const exported_c = products.nonwoody.ecosystem_export.carbon_g + products.woody.ecosystem_export.carbon_g;
    const litter_c = products.nonwoody.litter.carbon_g + products.woody.litter.carbon_g;
    try std.testing.expectApproxEqAbs(2.0, state.node_sheath_carbon_g[0] + exported_c + litter_c, 1e-15);
    try std.testing.expectEqual(state.node_sheath_carbon_g[0], state.branch_sheath_carbon_g[0]);
    try std.testing.expectApproxEqAbs(1.0, state.node_sheath_height_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.25, state.node_sheath_protein_g[0], 1e-15);
}

test "sheath harvest rejects sub-legacy-tolerance aggregate overdraw atomically" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_height_m[0] = 1;
    state.node_sheath_height_m[0] = 2;
    state.node_sheath_carbon_g[0] = 2;
    state.node_sheath_nitrogen_g[0] = 0.2;
    state.node_sheath_phosphorus_g[0] = 0.02;
    state.node_sheath_protein_g[0] = 0.5;
    state.branch_sheath_carbon_g[0] = 2 - 5e-13;
    state.branch_sheath_nitrogen_g[0] = 0.2;
    state.branch_sheath_phosphorus_g[0] = 0.02;
    const before = .{
        state.node_sheath_height_m[0],
        state.node_sheath_carbon_g[0],
        state.node_sheath_nitrogen_g[0],
        state.node_sheath_phosphorus_g[0],
        state.node_sheath_protein_g[0],
        state.branch_sheath_carbon_g[0],
        state.branch_sheath_nitrogen_g[0],
        state.branch_sheath_phosphorus_g[0],
    };
    try std.testing.expectError(error.SheathHarvestWouldOverdrawAggregate, canopy_photosynthesis.harvestNodeSheath(
        &state,
        0,
        0,
        0,
        1,
        .{ 0.25, 0.75 },
        .{ 0.2, 0.8 },
        .{ 0.1, 0.9 },
        true,
        2,
    ));
    try std.testing.expectEqualDeep(before, .{
        state.node_sheath_height_m[0],
        state.node_sheath_carbon_g[0],
        state.node_sheath_nitrogen_g[0],
        state.node_sheath_phosphorus_g[0],
        state.node_sheath_protein_g[0],
        state.branch_sheath_carbon_g[0],
        state.branch_sheath_nitrogen_g[0],
        state.branch_sheath_phosphorus_g[0],
    });
}

test "GROSUB remaining node leaf rebuilds runtime layers and scales protein" {
    const result = try canopy_photosynthesis.sourceOrderRemainingNodeLeaf(
        &.{ 1, 2, 3 },
        &.{ 4, 5, 6 },
        &.{ 0.4, 0.5, 0.6 },
        &.{ 0.04, 0.05, 0.06 },
        12,
        8,
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 6), result.area_m2);
    try std.testing.expectEqual(@as(f64, 15), result.carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.nitrogen_g_n, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 4), result.protein_mass_g);
}

test "GROSUB node organ retention preserves leaf coupling and kind zero litter" {
    const coupled = try canopy_photosynthesis.sourceOrderNodeOrganRetention(false, false, 10, 5, 0.5, 0.25, 0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.75), coupled.remaining_fraction);
    try std.testing.expectEqual(coupled.remaining_fraction, coupled.unexported_fraction);
    const kind_zero = try canopy_photosynthesis.sourceOrderNodeOrganRetention(false, true, 0, 0, 0.5, 0.25, 0.4, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.6), kind_zero.remaining_fraction);
    try std.testing.expectEqual(@as(f64, 0.9), kind_zero.unexported_fraction);
    const equality = try canopy_photosynthesis.sourceOrderNodeOrganRetention(false, false, 1.0e-12, 0, 0.5, 0.25, 0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.75), equality.remaining_fraction);
}

test "GROSUB internode harvest retains source geometry and runtime node state" {
    try std.testing.expectApproxEqAbs(0.5, try canopy_photosynthesis.internodeHarvestRetention(3, 2, 2, false, 0, 1, false, 0, 10), 1e-15);
    try std.testing.expectApproxEqAbs(0.8, try canopy_photosynthesis.internodeHarvestRetention(3, 2, 2, false, 0.2, 1, false, 0, 10), 1e-15);
    try std.testing.expectApproxEqAbs(0.7, try canopy_photosynthesis.internodeHarvestRetention(3, 2, 2, false, 0, 1, true, 3, 10), 1e-15);
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_height_m[0] = 3;
    state.node_internode_length_m[0] = 2;
    state.node_internode_carbon_g[0] = 4;
    state.node_internode_nitrogen_g[0] = 0.4;
    state.node_internode_phosphorus_g[0] = 0.04;
    try canopy_photosynthesis.state_updateInternodeHarvest(&state, 0, 0, 0.5, true, 2);
    try std.testing.expectApproxEqAbs(2.0, state.node_internode_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.0, state.node_internode_length_m[0], 1e-15);
    try std.testing.expectApproxEqAbs(2.0, state.node_height_m[0], 1e-15);
}

test "GROSUB branch stalk retention preserves kind zero and grazing operands" {
    const kind_zero = try canopy_photosynthesis.sourceOrderBranchStalkRetention(false, true, false, 4, 2, 0.5, 0.8, 10, 0, 0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.5), kind_zero.remaining_fraction);
    try std.testing.expectEqual(@as(f64, 0.8), kind_zero.unexported_fraction);
    const grazing = try canopy_photosynthesis.sourceOrderBranchStalkRetention(true, false, false, 4, 2, 0, 0.8, 10, 2, 3, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0.5), grazing.remaining_fraction);
}

test "GROSUB stalk reserve is discarded when no stalk remains" {
    const prior: canopy_photosynthesis.LayerHarvestRetention = .{ .remaining_fraction = 0.5, .unexported_fraction = 0.8, .height_below_cut_fraction = 0 };
    const retained = try canopy_photosynthesis.sourceOrderStalkReserveRetention(false, 2, prior, 4, 0, 1.0e-12);
    try std.testing.expectEqualDeep(prior, retained);
    const discarded = try canopy_photosynthesis.sourceOrderStalkReserveRetention(false, 1.0e-12, prior, 4, 0, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), discarded.remaining_fraction);
}

test "GROSUB cutting height layer retention and grazing demand retain equations" {
    const boundaries = [_]f64{ 0, 1, 2 };
    const leaf_area = [_]f64{ 2, 2 };
    try std.testing.expectApproxEqAbs(1.5, try canopy_photosynthesis.cuttingHeightForLeafAreaRemoval(0.25, &boundaries, &leaf_area), 1e-15);
    const direct_cut = try canopy_photosynthesis.layerHarvestRetention(1, 2, 1.5, false, false, 0, 0.8);
    try std.testing.expectApproxEqAbs(0.5, direct_cut.height_below_cut_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(0.6, direct_cut.remaining_fraction, 1e-15);
    const thinned = try canopy_photosynthesis.layerHarvestRetention(1, 2, 1.5, false, true, 0.25, 0.8);
    try std.testing.expectApproxEqAbs(0.75, thinned.remaining_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(0.9, thinned.unexported_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(1.0 / 12.0, try canopy_photosynthesis.grazingCarbonDemandGPerH(true, 10, 0.1, 2, 0, 1, 20, 10), 1e-15);
    try std.testing.expectApproxEqAbs(1.0 / 12.0, try canopy_photosynthesis.grazingCarbonDemandGPerH(false, 10, 0.1, 1, 4, 0.5, 20, 10), 1e-15);
}

test "GROSUB grazing cascade carries unmet demand through organ order" {
    const allocation = try canopy_photosynthesis.allocateGrazingDemand(1, 0.5, 0.3, 0.2, 0.25, 0.1, .{ .leaf_carbon_g = 2, .sheath_carbon_g = 1, .husk_carbon_g = 1, .ear_carbon_g = 1, .grain_carbon_g = 1, .stalk_carbon_g = 2, .reserve_carbon_g = 2 });
    const physical_removal = allocation.structural_leaf_carbon_g + allocation.structural_sheath_carbon_g + allocation.husk_carbon_g + allocation.ear_carbon_g + allocation.grain_carbon_g + allocation.stalk_carbon_g + allocation.reserve_carbon_g + allocation.mobile_carbon_g;
    try std.testing.expectApproxEqAbs(1.0, physical_removal, 1e-14);
    try std.testing.expectEqual(0, allocation.unmet_carbon_g);
    try std.testing.expect(allocation.symbiont_mobile_carbon_g > 0);
}

test "GROSUB grazing demand retains ZEROP gate and animal insect drivers" {
    const animal = try canopy_photosynthesis.sourceOrderGrazingCarbonDemandGPerH(true, 2, 3, 10, 20, 0.5, 5, 10, 1.0e-12);
    const insect = try canopy_photosynthesis.sourceOrderGrazingCarbonDemandGPerH(false, 2, 3, 10, 20, 0.5, 5, 10, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), animal, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.625), insect, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), try canopy_photosynthesis.sourceOrderGrazingCarbonDemandGPerH(true, 2, 3, 10, 20, 0.5, 5, 1.0e-12, 1.0e-12));
}

test "GROSUB additional nonfoliar redistribution exposes source overdraw" {
    const source = try canopy_photosynthesis.sourceOrderAdditionalGrazingRemoval(1, 0.8, 0.5);
    try std.testing.expectEqual(@as(f64, 1.3), source.next_total_removed_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), source.next_unmet_carbon_g_c);
}

test "GROSUB top-down grazing node selector characterizes source skip" {
    const partial = try canopy_photosynthesis.sourceOrderGrazingNodeRemoval(4, 1);
    try std.testing.expectEqual(@as(f64, 0.75), partial.remaining_fraction);
    try std.testing.expectEqual(@as(f64, 0), partial.remaining_branch_layer_demand_g_c);

    const skipped = try canopy_photosynthesis.sourceOrderGrazingNodeRemoval(1, 1);
    try std.testing.expectEqual(@as(f64, 1), skipped.remaining_fraction);
    try std.testing.expectEqual(@as(f64, 1), skipped.remaining_branch_layer_demand_g_c);
}

test "GROSUB branch-layer leaf demand retains ZEROP2 gate" {
    try std.testing.expectEqual(
        @as(f64, 0.5),
        try canopy_photosynthesis.sourceOrderBranchLayerLeafDemand(4, 2, 1, 1.0e-12),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try canopy_photosynthesis.sourceOrderBranchLayerLeafDemand(1.0e-12, 2, 1, 1.0e-12),
    );
}

test "GROSUB reproductive harvest conserves export litter and retained C N P" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{0};
    const sample_counts = [_]usize{};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_husk_carbon_g[0] = 2;
    state.branch_husk_nitrogen_g[0] = 0.2;
    state.branch_husk_phosphorus_g[0] = 0.02;
    state.branch_ear_carbon_g[0] = 3;
    state.branch_ear_nitrogen_g[0] = 0.3;
    state.branch_ear_phosphorus_g[0] = 0.03;
    state.branch_grain_carbon_g[0] = 5;
    state.branch_grain_nitrogen_g[0] = 0.5;
    state.branch_grain_phosphorus_g[0] = 0.05;
    state.branch_potential_seed_site_count[0] = 100;
    state.branch_seed_count[0] = 80;
    state.branch_individual_seed_carbon_g[0] = 0.1;
    const retention = try canopy_photosynthesis.reproductiveRetention(false, true, false, 0.2, 0.5, 2, 3, 5, 0, 0, 0);
    const result = try canopy_photosynthesis.harvestReproductiveOrgans(&state, 0, retention);
    const retained_c = state.branch_husk_carbon_g[0] + state.branch_ear_carbon_g[0] + state.branch_grain_carbon_g[0];
    try std.testing.expectApproxEqAbs(10.0, retained_c + result.products.ecosystem_export.carbon_g + result.products.litter.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(1.0, result.harvested_grain.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(80, state.branch_potential_seed_site_count[0], 1e-14);
    try std.testing.expectApproxEqAbs(64, state.branch_seed_count[0], 1e-14);
    try std.testing.expectEqual(0.1, state.branch_individual_seed_carbon_g[0]);
}

test "GROSUB reproductive retention preserves non-grazing source branches" {
    const direct_cut = try canopy_photosynthesis.sourceOrderReproductiveRetention(.{
        .grazing = false,
        .reproductive_organs_reached_by_cut = true,
        .grain_or_pruning = false,
        .thinning_fraction = 0,
        .harvested_nonfoliar_fraction = 0.6,
        .total_husk_carbon_g_c = 2,
        .total_ear_carbon_g_c = 3,
        .total_grain_carbon_g_c = 5,
        .grazed_husk_carbon_g_c = 0,
        .grazed_ear_carbon_g_c = 0,
        .grazed_grain_carbon_g_c = 0,
        .plant_presence_threshold_g_c = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 0.4), direct_cut.grain_remaining);
    try std.testing.expectEqual(direct_cut.grain_remaining, direct_cut.grain_unexported);

    var thinned = canopy_photosynthesis.SourceOrderReproductiveRetentionInput{
        .grazing = false,
        .reproductive_organs_reached_by_cut = false,
        .grain_or_pruning = true,
        .thinning_fraction = 0.25,
        .harvested_nonfoliar_fraction = 0.6,
        .total_husk_carbon_g_c = 2,
        .total_ear_carbon_g_c = 3,
        .total_grain_carbon_g_c = 5,
        .grazed_husk_carbon_g_c = 0,
        .grazed_ear_carbon_g_c = 0,
        .grazed_grain_carbon_g_c = 0,
        .plant_presence_threshold_g_c = 1.0e-12,
    };
    const grain_harvest = try canopy_photosynthesis.sourceOrderReproductiveRetention(thinned);
    try std.testing.expectEqual(@as(f64, 0.75), grain_harvest.grain_remaining);
    try std.testing.expectEqual(@as(f64, 0.85), grain_harvest.grain_unexported);

    thinned.grain_or_pruning = false;
    const above_cut = try canopy_photosynthesis.sourceOrderReproductiveRetention(thinned);
    try std.testing.expectEqual(@as(f64, 0.75), above_cut.grain_remaining);
    try std.testing.expectEqual(above_cut.grain_remaining, above_cut.grain_unexported);
}

test "GROSUB reproductive grazing uses strict plant presence threshold" {
    const retention = try canopy_photosynthesis.sourceOrderReproductiveRetention(.{
        .grazing = true,
        .reproductive_organs_reached_by_cut = false,
        .grain_or_pruning = false,
        .thinning_fraction = 0,
        .harvested_nonfoliar_fraction = 0,
        .total_husk_carbon_g_c = 1.0e-12,
        .total_ear_carbon_g_c = 2.0e-12,
        .total_grain_carbon_g_c = 4,
        .grazed_husk_carbon_g_c = 1.0e-12,
        .grazed_ear_carbon_g_c = 1.0e-12,
        .grazed_grain_carbon_g_c = 6,
        .plant_presence_threshold_g_c = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 1), retention.husk_remaining);
    try std.testing.expectEqual(@as(f64, 0.5), retention.ear_remaining);
    try std.testing.expectEqual(@as(f64, 0), retention.grain_remaining);
    try std.testing.expectEqual(retention.grain_remaining, retention.grain_unexported);
}
