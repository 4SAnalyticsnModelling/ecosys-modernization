//! `photosynthesis` declarations: tests.
//!
//! Split out of `photosynthesis.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const c4_mesophyll_bundle_exchange = @import("c4_mesophyll_bundle_exchange.zig");
const branch_organ_growth_state_update = @import("../../plant/growth/branch_organ_growth_state_update.zig");
const leaf_node_growth_state_update = @import("../leaf/node_growth_state_update.zig");
const shoot_recycling_fraction = @import("../../plant/growth/shoot_recycling_fraction.zig");
const reserve_maintenance_respiration = @import("../../plant/growth/reserve_maintenance_respiration.zig");
const shoot_total_senescence_setup = @import("../../plant/growth/shoot_total_senescence_setup.zig");
const node_senescence_remobilization_request = @import("../../plant/growth/node_senescence_remobilization_request.zig");
const c4_leaf_nonstructural_carbon_senescence = @import("../leaf/c4_nonstructural_carbon_senescence.zig");
const node_senescence_cascade_progress = @import("../../plant/growth/node_senescence_cascade_progress.zig");
const perennial_stalk_senescence_setup = @import("../../plant/growth/perennial_stalk_senescence_setup.zig");
const internode_senescence_state_update = @import("../sheath/internode_senescence_state_update.zig");
const residual_stalk_senescence_request = @import("../../plant/growth/residual_stalk_senescence_request.zig");
const residual_stalk_senescence_state_update = @import("../../plant/growth/residual_stalk_senescence_state_update.zig");
const group_node_layer = @import("photosynthesis_node_layer.zig");
const group_organ_growth = @import("photosynthesis_organ_growth.zig");
const group_state = @import("photosynthesis_state.zig");

test "GROSUB absent leaf routes all C4 carbon without consuming sheath" {
    var state = try group_state.State.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{0});
    defer state.deinit();
    state.node_leaf_carbon_g[0] = 1.0e-12;
    state.branch_leaf_carbon_g[0] = 1.0e-12;
    state.node_sheath_carbon_g[0] = 2;
    state.branch_sheath_carbon_g[0] = 2;
    state.node_c3_nonstructural_carbon_g[0] = 0.4;
    state.node_c4_mesophyll_nonstructural_carbon_g[0] = 0.6;
    const allocation = try group_node_layer.allocateNodeSenescenceDemandWithThreshold(1, 1.0e-12, 2, 0.5, 0.25, 0.8, 1.0e-9);
    try std.testing.expect(!allocation.leaf_present);
    try std.testing.expectEqual(@as(f64, 0), allocation.sheath_fraction);
    const kinetics: group_organ_growth.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const products = try group_node_layer.state_updateNodeSenescenceDemand(&state, 0, 0, allocation, .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 }, 2, 20, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, .{ 0.25, 0.75 }, kinetics, kinetics, kinetics);
    try std.testing.expectEqual(@as(f64, 0), state.node_c3_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_c4_mesophyll_nonstructural_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.node_leaf_carbon_g[0]);
    var litter_carbon_g_c: f64 = 0;
    for (0..4) |kinetic| litter_carbon_g_c += products.woody_carbon_g[kinetic] + products.nonwoody_carbon_g[kinetic];
    try std.testing.expectApproxEqAbs(@as(f64, 1.000000000001), litter_carbon_g_c, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 2), state.node_sheath_carbon_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.branch_sheath_carbon_g[0]);
}

test "GROSUB descending stalk sweep scales sapwood recycling only once" {
    var state = try group_state.State.init(std.testing.allocator, 1, 1, &.{1}, &.{2}, &.{ 0, 0 });
    defer state.deinit();
    state.branch_stalk_carbon_g[0] = 20;
    state.branch_stalk_nitrogen_g[0] = 2;
    state.branch_stalk_phosphorus_g[0] = 0.2;
    state.branch_sapwood_carbon_g[0] = 5;
    @memset(state.node_internode_carbon_g, 4);
    @memset(state.node_internode_nitrogen_g, 0.4);
    @memset(state.node_internode_phosphorus_g, 0.04);
    @memset(state.node_internode_length_m, 1);
    state.node_height_m[0] = 1;
    state.node_height_m[1] = 2;
    const setup = (try perennial_stalk_senescence_setup.prepare(.{
        .is_perennial = true,
        .excess_maintenance_respiration_g_c_per_timestep = 1,
        .stalk_carbon_g_c = 20,
        .sapwood_carbon_g_c = 5,
        .presence_threshold_g_c = 0,
        .first_internode = 0,
        .last_internode = 1,
        .shoot_recycling = .{ .carbon = 1, .nitrogen = 1, .phosphorus = 1 },
    })).?;
    const kinetics: group_organ_growth.KineticFractions = .{ .carbon = @splat(0.25), .nitrogen = @splat(0.25), .phosphorus = @splat(0.25) };
    const first = try group_node_layer.state_updateInternodeSenescenceDemandScaled(&state, 0, 1, 1, 0, setup.sapwood_recycling, 0, .{ 0.2, 0.8 }, .{ 0.2, 0.8 }, .{ 0.2, 0.8 }, kinetics, kinetics);
    const second = try group_node_layer.state_updateInternodeSenescenceDemandScaled(&state, 0, 0, first.remaining_respiration_demand_g_c, 0, setup.sapwood_recycling, 0, .{ 0.2, 0.8 }, .{ 0.2, 0.8 }, .{ 0.2, 0.8 }, kinetics, kinetics);
    try std.testing.expectEqual(@as(f64, 1), first.fraction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), second.fraction, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), state.node_internode_carbon_g[0], 1.0e-15);
}
