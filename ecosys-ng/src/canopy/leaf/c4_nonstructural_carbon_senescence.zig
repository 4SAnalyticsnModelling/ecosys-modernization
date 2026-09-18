const std = @import("std");

pub const State = struct {
    bundle_sheath_carbon_g_c: []f64,
    mesophyll_carbon_g_c: []f64,
    foliar_litter_carbon_g_c_by_kinetic_pool: []f64,
};

pub const Routing = struct {
    /// Null represents the source K=0 sentinel. A present zero is a valid
    /// ecosys-ng logical runtime node.
    selected_node: ?usize,
    foliar_litter_kinetic_pool: usize,
};

/// grosub.f lines 2975--2981. Routes the same fraction of selected-node C4
/// bundle-sheath and mesophyll nonstructural carbon to foliar litter. Source
/// order is litter addition, bundle-sheath subtraction, mesophyll subtraction.
pub fn routePartial(state: State, routing: Routing, removal_fraction: f64) !void {
    if (!std.math.isFinite(removal_fraction) or removal_fraction < 0 or removal_fraction > 1)
        return error.InvalidC4LeafCarbonRemovalFraction;
    const node = try validate(state, routing) orelse return;
    const bundle_sheath_removed_g_c = removal_fraction * state.bundle_sheath_carbon_g_c[node];
    const mesophyll_removed_g_c = removal_fraction * state.mesophyll_carbon_g_c[node];
    const litter_after_g_c = state.foliar_litter_carbon_g_c_by_kinetic_pool[routing.foliar_litter_kinetic_pool] +
        bundle_sheath_removed_g_c + mesophyll_removed_g_c;
    const bundle_sheath_after_g_c = state.bundle_sheath_carbon_g_c[node] - bundle_sheath_removed_g_c;
    const mesophyll_after_g_c = state.mesophyll_carbon_g_c[node] - mesophyll_removed_g_c;
    try validateResults(litter_after_g_c, bundle_sheath_after_g_c, mesophyll_after_g_c);

    state.foliar_litter_carbon_g_c_by_kinetic_pool[routing.foliar_litter_kinetic_pool] = litter_after_g_c;
    state.bundle_sheath_carbon_g_c[node] = bundle_sheath_after_g_c;
    state.mesophyll_carbon_g_c[node] = mesophyll_after_g_c;
}

/// grosub.f lines 3071--3075. Routes all selected-node C4 nonstructural carbon
/// to the configured foliar litter kinetic pool, then clears both node pools.
pub fn routeAll(state: State, routing: Routing) !void {
    const node = try validate(state, routing) orelse return;
    const litter_after_g_c = state.foliar_litter_carbon_g_c_by_kinetic_pool[routing.foliar_litter_kinetic_pool] +
        state.bundle_sheath_carbon_g_c[node] + state.mesophyll_carbon_g_c[node];
    try validateResults(litter_after_g_c, 0, 0);

    state.foliar_litter_carbon_g_c_by_kinetic_pool[routing.foliar_litter_kinetic_pool] = litter_after_g_c;
    state.bundle_sheath_carbon_g_c[node] = 0;
    state.mesophyll_carbon_g_c[node] = 0;
}

fn validate(state: State, routing: Routing) !?usize {
    if (state.bundle_sheath_carbon_g_c.len != state.mesophyll_carbon_g_c.len)
        return error.C4LeafCarbonNodeDimensionMismatch;
    if (routing.foliar_litter_kinetic_pool >= state.foliar_litter_carbon_g_c_by_kinetic_pool.len)
        return error.C4LeafCarbonLitterIndexOutOfBounds;
    const node = routing.selected_node orelse return null;
    if (node >= state.bundle_sheath_carbon_g_c.len)
        return error.C4LeafCarbonNodeIndexOutOfBounds;
    inline for (.{
        state.bundle_sheath_carbon_g_c[node],
        state.mesophyll_carbon_g_c[node],
        state.foliar_litter_carbon_g_c_by_kinetic_pool[routing.foliar_litter_kinetic_pool],
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidC4LeafCarbonState;
    return node;
}

fn validateResults(litter_g_c: f64, bundle_sheath_g_c: f64, mesophyll_g_c: f64) !void {
    inline for (.{ litter_g_c, bundle_sheath_g_c, mesophyll_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidC4LeafCarbonRoutingResult;
}

fn totalCarbon(state: State) f64 {
    var total: f64 = 0;
    for (state.bundle_sheath_carbon_g_c) |value| total += value;
    for (state.mesophyll_carbon_g_c) |value| total += value;
    for (state.foliar_litter_carbon_g_c_by_kinetic_pool) |value| total += value;
    return total;
}

test "partial route conserves C4 carbon in exact source destinations" {
    var bundle = [_]f64{ 2, 8 };
    var mesophyll = [_]f64{ 3, 12 };
    var litter = [_]f64{ 1, 10, 100, 1000 };
    const state: State = .{
        .bundle_sheath_carbon_g_c = &bundle,
        .mesophyll_carbon_g_c = &mesophyll,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &litter,
    };
    const before = totalCarbon(state);
    try routePartial(state, .{ .selected_node = 1, .foliar_litter_kinetic_pool = 1 }, 0.25);
    try std.testing.expectEqual(@as(f64, 6), bundle[1]);
    try std.testing.expectEqual(@as(f64, 9), mesophyll[1]);
    try std.testing.expectEqual(@as(f64, 15), litter[1]);
    try std.testing.expectEqual(before, totalCarbon(state));
    try std.testing.expectEqual(@as(f64, 1), litter[0]);
}

test "complete route clears both node pools and conserves carbon" {
    var bundle = [_]f64{4};
    var mesophyll = [_]f64{6};
    var litter = [_]f64{ 7, 8, 9 };
    const state: State = .{
        .bundle_sheath_carbon_g_c = &bundle,
        .mesophyll_carbon_g_c = &mesophyll,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &litter,
    };
    const before = totalCarbon(state);
    try routeAll(state, .{ .selected_node = 0, .foliar_litter_kinetic_pool = 2 });
    try std.testing.expectEqual(@as(f64, 0), bundle[0]);
    try std.testing.expectEqual(@as(f64, 0), mesophyll[0]);
    try std.testing.expectEqual(@as(f64, 19), litter[2]);
    try std.testing.expectEqual(before, totalCarbon(state));
}

test "logical runtime node beyond legacy ring routes directly" {
    var bundle: [31]f64 = @splat(0);
    var mesophyll: [31]f64 = @splat(0);
    var litter = [_]f64{0};
    bundle[30] = 2;
    mesophyll[30] = 1;
    try routeAll(.{
        .bundle_sheath_carbon_g_c = &bundle,
        .mesophyll_carbon_g_c = &mesophyll,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &litter,
    }, .{ .selected_node = 30, .foliar_litter_kinetic_pool = 0 });
    try std.testing.expectEqual(@as(f64, 3), litter[0]);
}

test "source sentinel gate performs no read or mutation" {
    var bundle = [_]f64{std.math.nan(f64)};
    var mesophyll = [_]f64{std.math.nan(f64)};
    var litter = [_]f64{std.math.nan(f64)};
    try routePartial(.{
        .bundle_sheath_carbon_g_c = &bundle,
        .mesophyll_carbon_g_c = &mesophyll,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &litter,
    }, .{ .selected_node = null, .foliar_litter_kinetic_pool = 0 }, 0.5);
    try std.testing.expect(std.math.isNan(bundle[0]));
}

test "late overflow and topology errors are atomic" {
    var bundle = [_]f64{std.math.floatMax(f64)};
    var mesophyll = [_]f64{std.math.floatMax(f64)};
    var litter = [_]f64{1};
    const state: State = .{
        .bundle_sheath_carbon_g_c = &bundle,
        .mesophyll_carbon_g_c = &mesophyll,
        .foliar_litter_carbon_g_c_by_kinetic_pool = &litter,
    };
    try std.testing.expectError(error.InvalidC4LeafCarbonRoutingResult, routeAll(state, .{
        .selected_node = 0,
        .foliar_litter_kinetic_pool = 0,
    }));
    try std.testing.expectEqual(std.math.floatMax(f64), bundle[0]);
    try std.testing.expectEqual(std.math.floatMax(f64), mesophyll[0]);
    try std.testing.expectEqual(@as(f64, 1), litter[0]);
    try std.testing.expectError(error.C4LeafCarbonLitterIndexOutOfBounds, routeAll(state, .{
        .selected_node = 0,
        .foliar_litter_kinetic_pool = 1,
    }));
}
