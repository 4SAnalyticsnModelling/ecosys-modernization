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
test "GROSUB sheath and stalk growth retain runtime node geometry" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{5};
    const sample_counts = [_]usize{0} ** 5;
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    @memset(state.node_leaf_carbon_g, 1);
    try canopy_photosynthesis.distributeSheathGrowth(&state, 0, 4, 1, 3, .{ .carbon_g = 0.6, .nitrogen_g = 0.06, .phosphorus_g = 0.012 }, 2, 10, 1.5, 0.4, 0.01, 2, 0, 0.8, 0.5);
    try std.testing.expectEqual(0, state.node_sheath_carbon_g[1]);
    for (2..5) |node| try std.testing.expectApproxEqAbs(0.2, state.node_sheath_carbon_g[node], 1e-15);
    const stalk = try canopy_photosynthesis.distributeStalkGrowth(&state, 0, 2, 4, .{ .carbon_g = 0.9, .nitrogen_g = 0.09, .phosphorus_g = 0.009 }, 1, 0.5, 0.01, 2, 0, 1, 0.8, 1e-5);
    try std.testing.expect(stalk.stem_diameter_m > 0);
    try std.testing.expect(state.node_height_m[4] > state.node_height_m[3]);
    try std.testing.expectApproxEqAbs(0.9, state.node_internode_carbon_g[2] + state.node_internode_carbon_g[3] + state.node_internode_carbon_g[4], 1e-15);
}

test "GROSUB stalk allocation accepts an exact runtime window wider than twenty five nodes" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{32};
    const sample_counts = [_]usize{0} ** 32;
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();

    _ = try canopy_photosynthesis.distributeStalkGrowth(
        &state,
        0,
        1,
        30,
        .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 },
        1,
        0.5,
        0.01,
        2,
        0,
        1,
        0.8,
        1e-5,
    );
    try std.testing.expectEqual(@as(f64, 0), state.node_internode_carbon_g[0]);
    for (1..31) |node| try std.testing.expectApproxEqAbs(@as(f64, 0.1), state.node_internode_carbon_g[node], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), state.node_internode_carbon_g[31]);
}

test "GROSUB recycling and leaf sheath senescence conserve C N P" {
    const recycling = try canopy_photosynthesis.recyclingFractions(true, 0.2, 0.02, 0.002, 0.025, 0.0025, 0.1, 0.5, 0.8, 0.7);
    try std.testing.expect(recycling.carbon >= 0.1 and recycling.carbon <= 0.6);
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 4;
    state.node_leaf_nitrogen_g[0] = 0.4;
    state.node_leaf_phosphorus_g[0] = 0.04;
    state.node_leaf_protein_g[0] = 0.3;
    state.node_leaf_area_m2[0] = 2;
    state.node_sheath_carbon_g[0] = 2;
    state.node_sheath_nitrogen_g[0] = 0.1;
    state.node_sheath_phosphorus_g[0] = 0.02;
    state.node_sheath_protein_g[0] = 0.08;
    state.node_sheath_height_m[0] = 0.5;
    state.node_internode_carbon_g[0] = 0.7;
    state.node_internode_nitrogen_g[0] = 0.01;
    state.node_internode_phosphorus_g[0] = 0.001;
    state.branch_leaf_carbon_g[0] = 4;
    state.branch_leaf_nitrogen_g[0] = 0.4;
    state.branch_leaf_phosphorus_g[0] = 0.04;
    state.branch_sheath_carbon_g[0] = 2;
    state.branch_sheath_nitrogen_g[0] = 0.1;
    state.branch_sheath_phosphorus_g[0] = 0.02;
    state.branch_leaf_area_m2[0] = 2;
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const products = try canopy_photosynthesis.senesceLeafAndSheathNode(&state, 0, 0, 0.25, recycling, 0.5, 5, .{ 0.2, 0.8 }, .{ 0.1, 0.9 }, .{ 0.3, 0.7 }, .{ 0.15, 0.85 }, .{ 0.25, 0.75 }, kinetics, kinetics, kinetics);
    var litter_c: f64 = 0;
    var litter_n: f64 = 0;
    var litter_p: f64 = 0;
    for (0..4) |index| {
        litter_c += products.woody_carbon_g[index] + products.nonwoody_carbon_g[index];
        litter_n += products.woody_nitrogen_g[index] + products.nonwoody_nitrogen_g[index];
        litter_p += products.woody_phosphorus_g[index] + products.nonwoody_phosphorus_g[index];
    }
    try std.testing.expectApproxEqAbs(6.0, state.node_leaf_carbon_g[0] + state.node_sheath_carbon_g[0] + litter_c + products.recycled_carbon_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.5, state.node_leaf_nitrogen_g[0] + state.node_sheath_nitrogen_g[0] + litter_n + products.recycled_nitrogen_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.06, state.node_leaf_phosphorus_g[0] + state.node_sheath_phosphorus_g[0] + litter_p + products.recycled_phosphorus_g, 1e-13);
    try std.testing.expectEqual(0, state.node_internode_carbon_g[0]);
    try std.testing.expectEqual(0.7, state.branch_senescing_stalk_carbon_g[0]);
}

test "GROSUB node senescence splits demand and phenological carbon recovery" {
    const allocation = try canopy_photosynthesis.allocateNodeSenescenceDemand(1, 3, 1, 0.5, 0.25, 0.8);
    try std.testing.expectApproxEqAbs(0.5, allocation.leaf_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(0.5, allocation.sheath_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(0.2, allocation.carbon_recovered_to_mobile_pool_g, 1e-15);
    try std.testing.expectApproxEqAbs(0.6, allocation.carbon_respired_g, 1e-15);
    try std.testing.expectApproxEqAbs(0.2, allocation.remaining_respiration_demand_g_c, 1e-15);
}

test "GROSUB node senescence state_update conserves structural mobile litter and respired elements" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 3;
    state.node_leaf_nitrogen_g[0] = 0.3;
    state.node_leaf_phosphorus_g[0] = 0.03;
    state.node_leaf_area_m2[0] = 1.5;
    state.node_sheath_carbon_g[0] = 1;
    state.node_sheath_nitrogen_g[0] = 0.1;
    state.node_sheath_phosphorus_g[0] = 0.01;
    state.node_c3_nonstructural_carbon_g[0] = 0.1;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 0.2;
    state.branch_leaf_carbon_g[0] = 3;
    state.branch_leaf_nitrogen_g[0] = 0.3;
    state.branch_leaf_phosphorus_g[0] = 0.03;
    state.branch_sheath_carbon_g[0] = 1;
    state.branch_sheath_nitrogen_g[0] = 0.1;
    state.branch_sheath_phosphorus_g[0] = 0.01;
    state.branch_leaf_area_m2[0] = 1.5;
    const allocation = try canopy_photosynthesis.allocateNodeSenescenceDemand(1, 3, 1, 0.5, 0.25, 0.8);
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const products = try canopy_photosynthesis.state_updateNodeSenescenceDemand(&state, 0, 0, allocation, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 0.5, 5, .{ 0.2, 0.8 }, .{ 0.1, 0.9 }, .{ 0.3, 0.7 }, .{ 0.15, 0.85 }, .{ 0.25, 0.75 }, kinetics, kinetics, kinetics);
    var litter_c: f64 = 0;
    var litter_n: f64 = 0;
    var litter_p: f64 = 0;
    for (0..4) |index| {
        litter_c += products.woody_carbon_g[index] + products.nonwoody_carbon_g[index];
        litter_n += products.woody_nitrogen_g[index] + products.nonwoody_nitrogen_g[index];
        litter_p += products.woody_phosphorus_g[index] + products.nonwoody_phosphorus_g[index];
    }
    const remaining_c = state.node_leaf_carbon_g[0] + state.node_sheath_carbon_g[0] + state.node_c3_nonstructural_carbon_g[0] + state.node_c4_mesophyll_nonstructural_carbon_g[0];
    try std.testing.expectApproxEqAbs(4.3, remaining_c + litter_c + products.recycled_carbon_g + products.respired_carbon_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.4, state.node_leaf_nitrogen_g[0] + state.node_sheath_nitrogen_g[0] + litter_n + products.recycled_nitrogen_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.04, state.node_leaf_phosphorus_g[0] + state.node_sheath_phosphorus_g[0] + litter_p + products.recycled_phosphorus_g, 1e-13);
}

test "GROSUB internode senescence conserves stalk reserve litter and respired C N P" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_stalk_carbon_g[0] = 10;
    state.branch_stalk_nitrogen_g[0] = 1;
    state.branch_stalk_phosphorus_g[0] = 0.1;
    state.branch_sapwood_carbon_g[0] = 5;
    state.node_internode_carbon_g[0] = 4;
    state.node_internode_nitrogen_g[0] = 0.4;
    state.node_internode_phosphorus_g[0] = 0.04;
    state.node_internode_length_m[0] = 1;
    state.node_height_m[0] = 1;
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const result = try canopy_photosynthesis.state_updateInternodeSenescenceDemand(&state, 0, 0, 0.6, 0.25, .{ .carbon = 0.6, .nitrogen = 0.7, .phosphorus = 0.8 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, kinetics, kinetics);
    var litter_c: f64 = 0;
    var litter_n: f64 = 0;
    var litter_p: f64 = 0;
    for (0..4) |kinetic| {
        litter_c += result.products.woody_carbon_g[kinetic] + result.products.nonwoody_carbon_g[kinetic];
        litter_n += result.products.woody_nitrogen_g[kinetic] + result.products.nonwoody_nitrogen_g[kinetic];
        litter_p += result.products.woody_phosphorus_g[kinetic] + result.products.nonwoody_phosphorus_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(0.5, result.fraction, 1e-15);
    try std.testing.expectApproxEqAbs(4.0, state.node_internode_carbon_g[0] + litter_c + result.products.recycled_carbon_g + result.products.respired_carbon_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.4, state.node_internode_nitrogen_g[0] + litter_n + result.products.recycled_nitrogen_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.04, state.node_internode_phosphorus_g[0] + litter_p + result.products.recycled_phosphorus_g, 1e-13);
    try std.testing.expectApproxEqAbs(8.0, state.branch_stalk_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.15, result.remaining_respiration_demand_g_c, 1e-15);
}

test "GROSUB residual stalk senescence conserves elements and lowers canopy height" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{2};
    const sample_counts = [_]usize{ 0, 0 };
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_stalk_carbon_g[0] = 10;
    state.branch_stalk_nitrogen_g[0] = 1;
    state.branch_stalk_phosphorus_g[0] = 0.1;
    state.branch_sapwood_carbon_g[0] = 5;
    state.branch_senescing_stalk_carbon_g[0] = 4;
    state.branch_senescing_stalk_nitrogen_g[0] = 0.4;
    state.branch_senescing_stalk_phosphorus_g[0] = 0.04;
    state.node_height_m[0] = 1;
    state.node_height_m[1] = 2;
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const result = try canopy_photosynthesis.state_updateResidualStalkSenescenceDemand(&state, 0, 0.6, 0.25, .{ .carbon = 0.6, .nitrogen = 0.7, .phosphorus = 0.8 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, kinetics, kinetics);
    var litter_c: f64 = 0;
    var litter_n: f64 = 0;
    var litter_p: f64 = 0;
    for (0..4) |kinetic| {
        litter_c += result.products.woody_carbon_g[kinetic] + result.products.nonwoody_carbon_g[kinetic];
        litter_n += result.products.woody_nitrogen_g[kinetic] + result.products.nonwoody_nitrogen_g[kinetic];
        litter_p += result.products.woody_phosphorus_g[kinetic] + result.products.nonwoody_phosphorus_g[kinetic];
    }
    try std.testing.expectApproxEqAbs(4.0, state.branch_senescing_stalk_carbon_g[0] + litter_c + result.products.recycled_carbon_g + result.products.respired_carbon_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.4, state.branch_senescing_stalk_nitrogen_g[0] + litter_n + result.products.recycled_nitrogen_g, 1e-13);
    try std.testing.expectApproxEqAbs(0.04, state.branch_senescing_stalk_phosphorus_g[0] + litter_p + result.products.recycled_phosphorus_g, 1e-13);
    try std.testing.expectApproxEqAbs(1.0, state.node_height_m[1], 1e-15);
    try std.testing.expectApproxEqAbs(8.0, state.branch_stalk_carbon_g[0], 1e-15);
}

test "GROSUB leaf nutrient equilibration preserves N P and source coupling" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 10;
    state.node_leaf_nitrogen_g[0] = 1;
    state.node_leaf_phosphorus_g[0] = 0.1;
    state.node_leaf_protein_g[0] = 2;
    state.branch_leaf_nitrogen_g[0] = 1;
    state.branch_leaf_phosphorus_g[0] = 0.1;
    state.branch_mobile_carbon_g[0] = 10;
    const initial_n = state.node_leaf_nitrogen_g[0] + state.branch_mobile_nitrogen_g[0];
    const initial_p = state.node_leaf_phosphorus_g[0] + state.branch_mobile_phosphorus_g[0];
    const flux = try canopy_photosynthesis.remobilizeNodeLeafNutrients(&state, 0, 0, 1.0e-3, 0.1, 0.08, 0.008, 2, 20);
    try std.testing.expectApproxEqAbs(0.0005, flux.nitrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(0.00005, flux.phosphorus_g, 1e-15);
    try std.testing.expectApproxEqAbs(initial_n, state.node_leaf_nitrogen_g[0] + state.branch_mobile_nitrogen_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(initial_p, state.node_leaf_phosphorus_g[0] + state.branch_mobile_phosphorus_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(1.999, state.node_leaf_protein_g[0], 1e-15);
}

test "GROSUB branch senescence cascade exits after reserve satisfies node remainder" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{1};
    const sample_counts = [_]usize{0};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 2;
    state.node_leaf_nitrogen_g[0] = 0.2;
    state.node_leaf_phosphorus_g[0] = 0.02;
    state.node_leaf_area_m2[0] = 1;
    state.branch_leaf_carbon_g[0] = 2;
    state.branch_leaf_nitrogen_g[0] = 0.2;
    state.branch_leaf_phosphorus_g[0] = 0.02;
    state.branch_leaf_area_m2[0] = 1;
    state.branch_reserve_carbon_g[0] = 0.1;
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const litter: canopy_photosynthesis.SenescenceLitterParameters = .{
        .woody_carbon_fraction = .{ 0.25, 0.75 },
        .leaf_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .sheath_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .stalk_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .leaf_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .sheath_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .stalk_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .woody_kinetics = kinetics,
        .leaf_kinetics = kinetics,
        .sheath_kinetics = kinetics,
        .stalk_kinetics = kinetics,
    };
    const result = try canopy_photosynthesis.state_updateBranchSenescenceDemand(&state, 0, .{ .total_respiration_demand_g_c = 0.3, .phenological_senescence_fraction = 0.5, .first_node_within_branch = 0, .last_node_within_branch = 0, .node_group_count = 1, .perennial = false, .reserve_fallback_policy = .consume_available, .demand_tolerance_g_c = 1e-12 }, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 2, 20, litter);
    var litter_c: f64 = 0;
    for (0..4) |kinetic| litter_c += result.products.woody_carbon_g[kinetic] + result.products.nonwoody_carbon_g[kinetic];
    try std.testing.expectEqual(0, result.remaining_respiration_demand_g_c);
    try std.testing.expectApproxEqAbs(0.075, result.reserve_carbon_respired_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(2.1, state.node_leaf_carbon_g[0] + state.branch_reserve_carbon_g[0] + litter_c + result.products.recycled_carbon_g + result.products.respired_carbon_g + result.reserve_carbon_respired_g_c, 1e-13);
}

test "GROSUB cascade does not repeat final node and reserve equality is strict" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 10;
    state.branch_leaf_carbon_g[0] = 10;
    state.branch_reserve_carbon_g[0] = 2.25;
    const kinetics: canopy_photosynthesis.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const litter: canopy_photosynthesis.SenescenceLitterParameters = .{
        .woody_carbon_fraction = .{ 0.25, 0.75 },
        .leaf_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .sheath_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .stalk_woody_nitrogen_fraction = .{ 0.25, 0.75 },
        .leaf_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .sheath_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .stalk_woody_phosphorus_fraction = .{ 0.25, 0.75 },
        .woody_kinetics = kinetics,
        .leaf_kinetics = kinetics,
        .sheath_kinetics = kinetics,
        .stalk_kinetics = kinetics,
    };
    const result = try canopy_photosynthesis.state_updateBranchSenescenceDemand(&state, 0, .{
        .total_respiration_demand_g_c = 3,
        .phenological_senescence_fraction = 0,
        .first_node_within_branch = 0,
        .last_node_within_branch = 0,
        .node_group_count = 3,
        .perennial = false,
        .demand_tolerance_g_c = 0,
    }, .{ .carbon = 1, .nitrogen = 1, .phosphorus = 1 }, 0, 0, litter);
    try std.testing.expectEqual(@as(f64, 9), state.node_leaf_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 1), result.remaining_respiration_demand_g_c);
    try std.testing.expectEqual(@as(f64, 1), state.branch_reserve_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 1.25), result.reserve_carbon_respired_g_c);
}

test "GROSUB reserve to grain fill conserves precursor and translocated C N P" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{0};
    const sample_counts = [_]usize{};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_reserve_carbon_g[0] = 2;
    state.branch_reserve_nitrogen_g[0] = 0.2;
    state.branch_reserve_phosphorus_g[0] = 0.02;
    state.branch_grain_carbon_g[0] = 1;
    state.branch_grain_nitrogen_g[0] = 0.05;
    state.branch_grain_phosphorus_g[0] = 0.005;
    const precursor: canopy_photosynthesis.LeafGrowth = .{ .carbon_g = 0.15, .nitrogen_g = 0.003, .phosphorus_g = 0.0003 };
    const result = try canopy_photosynthesis.fillGrainFromReserve(&state, 0, true, 100, 0.1, 0.01, 1, 1, 0.5, 0.04, 0.004, 0.02, 0.002, precursor);
    try std.testing.expectApproxEqAbs(1.0, result.carbon_translocated_g, 1e-15);
    try std.testing.expectApproxEqAbs(3.0 + precursor.carbon_g, state.branch_reserve_carbon_g[0] + state.branch_grain_carbon_g[0], 1e-14);
    try std.testing.expectApproxEqAbs(0.25 + precursor.nitrogen_g, state.branch_reserve_nitrogen_g[0] + state.branch_grain_nitrogen_g[0], 1e-14);
    try std.testing.expectApproxEqAbs(0.025 + precursor.phosphorus_g, state.branch_reserve_phosphorus_g[0] + state.branch_grain_phosphorus_g[0], 1e-14);
}

test "GROSUB grain nutrient fill uses three-way minimum rather than reserve-deficit maximum" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    state.branch_reserve_carbon_g[0] = 10;
    state.branch_reserve_nitrogen_g[0] = 0.1;
    state.branch_reserve_phosphorus_g[0] = 0.1;
    state.branch_grain_carbon_g[0] = 1;
    state.branch_grain_nitrogen_g[0] = 0;
    state.branch_grain_phosphorus_g[0] = 0;

    const result = try canopy_photosynthesis.fillGrainFromReserve(
        &state,
        0,
        true,
        1,
        10,
        1,
        1,
        1,
        0,
        1,
        1,
        0,
        0,
        .{ .carbon_g = 0, .nitrogen_g = 0, .phosphorus_g = 0 },
    );
    // The grain deficit is 2 g for both nutrients, but each reserve contains
    // only 0.1 g. The former production max selected the deficit and overdrawn
    // the reserve; the source minimum selects the available reserve term.
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.carbon_translocated_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.nitrogen_translocated_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.phosphorus_translocated_g, 1e-15);
}

test "GROSUB grain fill rejects non-finite authoritative pool state" {
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &.{1}, &.{0}, &.{});
    defer state.deinit();
    state.branch_grain_carbon_g[0] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidGrainFillState, canopy_photosynthesis.fillGrainFromReserve(
        &state,
        0,
        true,
        1,
        1,
        1,
        1,
        1,
        0.5,
        0.04,
        0.004,
        0.02,
        0.002,
        .{ .carbon_g = 0, .nitrogen_g = 0, .phosphorus_g = 0 },
    ));
}

test "GROSUB reserve respiration demand and phenological senescence are exact" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{0};
    const sample_counts = [_]usize{};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_reserve_carbon_g[0] = 4;
    const remaining = try canopy_photosynthesis.consumeReserveForRespiration(&state, 0, false, 1, 0.1, 0.5, 1);
    try std.testing.expectApproxEqAbs(0.8, remaining, 1e-15);
    try std.testing.expectApproxEqAbs(3.8, state.branch_reserve_carbon_g[0], 1e-15);
    const remobilizing_remaining = try canopy_photosynthesis.consumeReserveForRespiration(&state, 0, true, 1, 0.1, 0.5, 1);
    try std.testing.expectEqual(@as(f64, 1), remobilizing_remaining);
    try std.testing.expectApproxEqAbs(3.8, state.branch_reserve_carbon_g[0], 1e-15);
    const demand = try canopy_photosynthesis.senescenceDemand(true, true, true, 6, 1, 0.01, 20, 50, 100, 1, 0.2, 10, 2);
    try std.testing.expectApproxEqAbs(0.3, demand.phenological_respiration_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(0.5, demand.total_respiration_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(0.6, demand.phenological_fraction, 1e-15);
    try std.testing.expectEqual(@as(usize, 5), demand.node_group_count);
}

test "GROSUB interbranch reserve exchange is pairwise conservative" {
    const branch_counts = [_]usize{2};
    const node_counts = [_]usize{ 0, 0 };
    const sample_counts = [_]usize{};
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_sapwood_carbon_g[0] = 2;
    state.branch_sapwood_carbon_g[1] = 1;
    state.branch_reserve_carbon_g[0] = 3;
    state.branch_reserve_nitrogen_g[0] = 0.3;
    state.branch_reserve_phosphorus_g[0] = 0.03;
    const flux = try canopy_photosynthesis.equilibrateBranchReserves(&state, 0, 1, 0.5, 0.5, 1, 0);
    try std.testing.expectApproxEqAbs(0.5, flux.carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(3.0, state.branch_reserve_carbon_g[0] + state.branch_reserve_carbon_g[1], 1e-15);
    try std.testing.expectApproxEqAbs(0.3, state.branch_reserve_nitrogen_g[0] + state.branch_reserve_nitrogen_g[1], 1e-15);
    try std.testing.expectApproxEqAbs(0.03, state.branch_reserve_phosphorus_g[0] + state.branch_reserve_phosphorus_g[1], 1e-15);
}

test "GROSUB harvest retention partitions export litter and remaining pools" {
    const branch_counts = [_]usize{1};
    const node_counts = [_]usize{2};
    const sample_counts = [_]usize{ 0, 0 };
    var state = try canopy_photosynthesis.State.init(std.testing.allocator, 1, 1, &branch_counts, &node_counts, &sample_counts);
    defer state.deinit();
    state.branch_stalk_carbon_g[0] = 10;
    state.branch_stalk_nitrogen_g[0] = 1;
    state.branch_stalk_phosphorus_g[0] = 0.1;
    state.branch_sapwood_carbon_g[0] = 4;
    state.branch_senescing_stalk_carbon_g[0] = 2;
    state.branch_reserve_carbon_g[0] = 5;
    state.branch_reserve_nitrogen_g[0] = 0.5;
    state.branch_reserve_phosphorus_g[0] = 0.05;
    const products = try canopy_photosynthesis.harvestBranchStalkAndReserve(&state, 0, 0.4, 0.7, 0.2, 0.8);
    try std.testing.expectApproxEqAbs(15.0, state.branch_stalk_carbon_g[0] + state.branch_reserve_carbon_g[0] + products.ecosystem_export.carbon_g + products.litter.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(1.5, state.branch_stalk_nitrogen_g[0] + state.branch_reserve_nitrogen_g[0] + products.ecosystem_export.nitrogen_g + products.litter.nitrogen_g, 1e-14);
    try std.testing.expectApproxEqAbs(1.6, state.branch_sapwood_carbon_g[0], 1e-15);
    state.branch_mobile_carbon_g[0] = 2;
    state.branch_mobile_nitrogen_g[0] = 0.2;
    state.branch_mobile_phosphorus_g[0] = 0.02;
    state.node_c3_nonstructural_carbon_g[0] = 0.4;
    state.node_c4_mesophyll_nonstructural_carbon_g[1] = 0.6;
    const removed = try canopy_photosynthesis.harvestBranchMobilePools(&state, 0, 0.25);
    try std.testing.expectApproxEqAbs(2.25, removed.carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(0.5, state.branch_mobile_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.1, state.node_c3_nonstructural_carbon_g[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.15, state.node_c4_mesophyll_nonstructural_carbon_g[1], 1e-15);
    try std.testing.expectApproxEqAbs(3.0, removed.carbon_g + state.branch_mobile_carbon_g[0] + state.node_c3_nonstructural_carbon_g[0] + state.node_c4_mesophyll_nonstructural_carbon_g[1], 1e-15);
}

test "GROSUB branch mobile removal preserves source ratios and thresholds" {
    try std.testing.expectEqual(
        @as(f64, 0.25),
        try canopy_photosynthesis.sourceOrderNonGrazingMobileRetention(8, 2, 1.0e-12),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try canopy_photosynthesis.sourceOrderNonGrazingMobileRetention(1.0e-12, 0.5e-12, 1.0e-12),
    );
    const result = try canopy_photosynthesis.sourceOrderProportionalMobileRemoval(
        .{ .carbon_g = 4, .nitrogen_g = 2, .phosphorus_g = 1 },
        1,
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 3), result.remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, 1.5), result.remaining.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 0.75), result.remaining.phosphorus_g);
    try std.testing.expectEqual(@as(f64, 0.75), result.unclamped_carbon_retention_fraction);
}

test "GROSUB symbiont structural scaling exposes source overdraw" {
    const result = try canopy_photosynthesis.sourceOrderProportionalMobileRemoval(
        .{ .carbon_g = 1, .nitrogen_g = 0.1, .phosphorus_g = 0.01 },
        2,
        1.0e-12,
    );
    try std.testing.expectEqual(@as(f64, 0), result.remaining.carbon_g);
    try std.testing.expectEqual(@as(f64, -1), result.unclamped_carbon_retention_fraction);
}
