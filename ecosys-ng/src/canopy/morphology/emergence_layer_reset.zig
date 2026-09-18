const std = @import("std");

pub const MainNodeZeroGeometry = struct {
    leaf_area_m2: f64,
    sheath_height_m: f64,
    internode_height_m: f64,
};

pub const LayerState = struct {
    layer_count: usize,
    node_count: usize,
    leaf_area_m2: []f64,
    leaf_carbon_g_c: []f64,
    leaf_nitrogen_g_n: []f64,
    leaf_phosphorus_g_p: []f64,
    stalk_area_m2: []f64,
};

pub const State = struct {
    lowest_canopy_node: *?usize,
    hypocotyledon_height_m: *f64,
    layers: LayerState,
};

pub const Inputs = struct {
    seeding_depth_m: f64,
    plant_population_per_m2: f64,
    main_node_zero: MainNodeZeroGeometry,
};

pub const Result = struct {
    emerged: bool,
    hypocotyledon_initialized: bool,
    inferred_leaf_length_m: f64,
};

/// grosub.f lines 3714--3735. Resets KVSTGN, optionally initializes HTCTL from
/// explicit main-branch node-zero geometry, then clears current-branch leaf
/// node-by-layer state followed by stalk layer area when the canopy has emerged.
pub fn apply(state: State, inputs: Inputs) !Result {
    try validateDimensions(state.layers);
    inline for (.{ inputs.seeding_depth_m, inputs.plant_population_per_m2, state.hypocotyledon_height_m.* }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyEmergenceInput;
    if (inputs.seeding_depth_m < 0 or inputs.plant_population_per_m2 <= 0 or state.hypocotyledon_height_m.* < 0)
        return error.InvalidCanopyEmergenceInput;

    var next_hypocotyledon_height_m = state.hypocotyledon_height_m.*;
    var inferred_leaf_length_m: f64 = 0;
    var initialized = false;
    if (next_hypocotyledon_height_m <= inputs.seeding_depth_m) {
        const main_leaf_area_m2 = inputs.main_node_zero.leaf_area_m2;
        if (!std.math.isFinite(main_leaf_area_m2) or main_leaf_area_m2 < 0)
            return error.InvalidCanopyEmergenceGeometry;
        if (main_leaf_area_m2 > 0) {
            const main_sheath_height_m = inputs.main_node_zero.sheath_height_m;
            const main_internode_height_m = inputs.main_node_zero.internode_height_m;
            inline for (.{ main_sheath_height_m, main_internode_height_m }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyEmergenceGeometry;
            inferred_leaf_length_m = @sqrt(1.0e2 * main_leaf_area_m2 / inputs.plant_population_per_m2);
            next_hypocotyledon_height_m = inferred_leaf_length_m + main_sheath_height_m + main_internode_height_m;
            if (!std.math.isFinite(inferred_leaf_length_m) or !std.math.isFinite(next_hypocotyledon_height_m))
                return error.InvalidCanopyEmergenceResult;
            initialized = true;
        }
    }
    const emerged = next_hypocotyledon_height_m > inputs.seeding_depth_m;

    state.lowest_canopy_node.* = null;
    state.hypocotyledon_height_m.* = next_hypocotyledon_height_m;
    if (emerged) {
        // Preserve K-outer/L-inner order and the four assignments within each
        // source iteration; node-major storage maps K*layer_count+L directly.
        for (0..state.layers.node_count) |node| for (0..state.layers.layer_count) |layer| {
            const index = node * state.layers.layer_count + layer;
            state.layers.leaf_area_m2[index] = 0;
            state.layers.leaf_carbon_g_c[index] = 0;
            state.layers.leaf_nitrogen_g_n[index] = 0;
            state.layers.leaf_phosphorus_g_p[index] = 0;
        };
        for (state.layers.stalk_area_m2) |*area_m2| area_m2.* = 0;
    }
    return .{ .emerged = emerged, .hypocotyledon_initialized = initialized, .inferred_leaf_length_m = inferred_leaf_length_m };
}

fn validateDimensions(layers: LayerState) !void {
    if (layers.layer_count == 0 or layers.node_count == 0) return error.InvalidCanopyLayerDimensions;
    const leaf_count = std.math.mul(usize, layers.node_count, layers.layer_count) catch return error.CanopyEmergenceDimensionOverflow;
    inline for (.{ layers.leaf_area_m2, layers.leaf_carbon_g_c, layers.leaf_nitrogen_g_n, layers.leaf_phosphorus_g_p }) |values|
        if (values.len != leaf_count) return error.CanopyLayerDimensionMismatch;
    if (layers.stalk_area_m2.len != layers.layer_count) return error.CanopyLayerDimensionMismatch;
}

fn makeState(lowest: *?usize, height: *f64, leaf: *[4][6]f64, stalk: []f64, nodes: usize, layers: usize) State {
    return .{
        .lowest_canopy_node = lowest,
        .hypocotyledon_height_m = height,
        .layers = .{
            .layer_count = layers,
            .node_count = nodes,
            .leaf_area_m2 = leaf[0][0 .. nodes * layers],
            .leaf_carbon_g_c = leaf[1][0 .. nodes * layers],
            .leaf_nitrogen_g_n = leaf[2][0 .. nodes * layers],
            .leaf_phosphorus_g_p = leaf[3][0 .. nodes * layers],
            .stalk_area_m2 = stalk,
        },
    };
}

test "non-first main branch node zero initializes height and clears emerged canopy" {
    var lowest: ?usize = 9;
    var height_m: f64 = 0.1;
    var leaf: [4][6]f64 = @splat(@splat(7));
    var stalk = [_]f64{ 8, 8 };
    const geometry = MainNodeZeroGeometry{ .leaf_area_m2 = 4, .sheath_height_m = 0.3, .internode_height_m = 0.2 };
    const result = try apply(makeState(&lowest, &height_m, &leaf, &stalk, 3, 2), .{
        .seeding_depth_m = 0.1,
        .plant_population_per_m2 = 100,
        .main_node_zero = geometry,
    });
    try std.testing.expect(result.emerged);
    try std.testing.expect(result.hypocotyledon_initialized);
    try std.testing.expectEqual(@as(f64, 2), result.inferred_leaf_length_m);
    try std.testing.expectEqual(@as(f64, 2.5), height_m);
    try std.testing.expectEqual(@as(?usize, null), lowest);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0, 0, 0, 0 }, &leaf[0]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0 }, &stalk);
}

test "not emerged resets lowest node but preserves layer state" {
    var lowest: ?usize = 4;
    var height_m: f64 = 0.05;
    var leaf: [4][6]f64 = @splat(@splat(7));
    var stalk = [_]f64{ 8, 8 };
    const result = try apply(makeState(&lowest, &height_m, &leaf, &stalk, 3, 2), .{
        .seeding_depth_m = 0.1,
        .plant_population_per_m2 = 100,
        .main_node_zero = .{ .leaf_area_m2 = 0, .sheath_height_m = 0, .internode_height_m = 0 },
    });
    try std.testing.expect(!result.emerged);
    try std.testing.expectEqual(@as(?usize, null), lowest);
    try std.testing.expectEqual(@as(f64, 7), leaf[0][5]);
    try std.testing.expectEqual(@as(f64, 8), stalk[1]);
}

test "runtime nodes and layers are not capped by legacy extents" {
    const nodes: usize = 31;
    const layers: usize = 3;
    var lowest: ?usize = 30;
    var height_m: f64 = 2;
    var leaf_storage: [4][93]f64 = @splat(@splat(1));
    var stalk: [3]f64 = @splat(1);
    const state: State = .{ .lowest_canopy_node = &lowest, .hypocotyledon_height_m = &height_m, .layers = .{ .layer_count = layers, .node_count = nodes, .leaf_area_m2 = &leaf_storage[0], .leaf_carbon_g_c = &leaf_storage[1], .leaf_nitrogen_g_n = &leaf_storage[2], .leaf_phosphorus_g_p = &leaf_storage[3], .stalk_area_m2 = &stalk } };
    _ = try apply(state, .{ .seeding_depth_m = 0.1, .plant_population_per_m2 = 1, .main_node_zero = .{ .leaf_area_m2 = 0, .sheath_height_m = 0, .internode_height_m = 0 } });
    try std.testing.expectEqual(@as(f64, 0), leaf_storage[3][92]);
}

test "late dimension error leaves reset and layer destinations untouched" {
    var lowest: ?usize = 5;
    var height_m: f64 = 2;
    var leaf: [4][6]f64 = @splat(@splat(7));
    var stalk = [_]f64{8};
    try std.testing.expectError(error.CanopyLayerDimensionMismatch, apply(makeState(&lowest, &height_m, &leaf, &stalk, 3, 2), .{
        .seeding_depth_m = 0.1,
        .plant_population_per_m2 = 1,
        .main_node_zero = .{ .leaf_area_m2 = 0, .sheath_height_m = 0, .internode_height_m = 0 },
    }));
    try std.testing.expectEqual(@as(usize, 5), lowest);
    try std.testing.expectEqual(@as(f64, 7), leaf[0][0]);
}

test "already emerged canopy does not inspect dormant node-zero geometry" {
    var lowest: ?usize = 5;
    var height_m: f64 = 2;
    var leaf: [4][6]f64 = @splat(@splat(7));
    var stalk = [_]f64{ 8, 8 };
    const result = try apply(makeState(&lowest, &height_m, &leaf, &stalk, 3, 2), .{
        .seeding_depth_m = 0.1,
        .plant_population_per_m2 = 1,
        .main_node_zero = .{ .leaf_area_m2 = std.math.nan(f64), .sheath_height_m = std.math.nan(f64), .internode_height_m = std.math.nan(f64) },
    });
    try std.testing.expect(result.emerged);
    try std.testing.expect(!result.hypocotyledon_initialized);
    try std.testing.expectEqual(@as(?usize, null), lowest);
    try std.testing.expectEqual(@as(f64, 0), leaf[3][5]);
    try std.testing.expectEqual(@as(f64, 0), stalk[1]);
}
