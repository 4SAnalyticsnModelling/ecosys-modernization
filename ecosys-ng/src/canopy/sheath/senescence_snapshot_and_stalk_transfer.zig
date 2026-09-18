// **PRODUCTION BOUND.** The IFLGP-scoped GROSUB 2666--2702 sheath snapshot
// and selected-internode transfer are projected here and committed atomically
// by `photosynthesis_node_layer.state_updateSelectedNodeSenescence`, reached
// from `shoot_growth_runtime.applyTile`.
const std = @import("std");

pub const State = struct {
    sheath_carbon_g_c: []const f64,
    sheath_nitrogen_g_n: []const f64,
    sheath_phosphorus_g_p: []const f64,
    sheath_height_m: []const f64,
    internode_carbon_g_c: []f64,
    internode_nitrogen_g_n: []f64,
    internode_phosphorus_g_p: []f64,
    internode_length_m: []f64,
    residual_stalk_carbon_g_c: *f64,
    residual_stalk_nitrogen_g_n: *f64,
    residual_stalk_phosphorus_g_p: *f64,
};

pub const RecyclingFractions = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

pub const Snapshot = struct {
    sheath_carbon_g_c: f64,
    sheath_nitrogen_g_n: f64,
    sheath_phosphorus_g_p: f64,
    sheath_height_m: f64,
    remobilizable_carbon_g_c: f64,
    remobilizable_nitrogen_g_n: f64,
    remobilizable_phosphorus_g_p: f64,
};

pub const Prepared = struct {
    snapshot: Snapshot,
    residual_stalk_carbon_g_c: f64,
    residual_stalk_nitrogen_g_n: f64,
    residual_stalk_phosphorus_g_p: f64,
};

/// grosub.f lines 2666--2702. The IFLGP gate encloses both the sheath snapshot
/// and transfer of the selected logical internode into residual stalk pools.
/// Runtime node ordinals replace fixed modulo-25 storage indexes.
pub fn prepareAndTransfer(
    remobilization_from_lowest_node_enabled: bool,
    state: State,
    selected_node: usize,
    structural_presence_threshold_g_c: f64,
    recycling: RecyclingFractions,
) !?Snapshot {
    const prepared = (try preview(
        remobilization_from_lowest_node_enabled,
        state,
        selected_node,
        structural_presence_threshold_g_c,
        recycling,
    )) orelse return null;
    // WTSTXB/N/P additions precede clearing WGNODE/N/P and HTNODX.
    state.residual_stalk_carbon_g_c.* = prepared.residual_stalk_carbon_g_c;
    state.residual_stalk_nitrogen_g_n.* = prepared.residual_stalk_nitrogen_g_n;
    state.residual_stalk_phosphorus_g_p.* = prepared.residual_stalk_phosphorus_g_p;
    state.internode_carbon_g_c[selected_node] = 0;
    state.internode_nitrogen_g_n[selected_node] = 0;
    state.internode_phosphorus_g_p[selected_node] = 0;
    state.internode_length_m[selected_node] = 0;
    return prepared.snapshot;
}

/// Pure projection used by a larger leaf/sheath transaction so a late litter,
/// protein, or mobile-pool error cannot leave the internode half-transferred.
pub fn preview(
    remobilization_from_lowest_node_enabled: bool,
    state: State,
    selected_node: usize,
    structural_presence_threshold_g_c: f64,
    recycling: RecyclingFractions,
) !?Prepared {
    if (!remobilization_from_lowest_node_enabled) return null;
    const runtime_node_count = state.sheath_carbon_g_c.len;
    inline for (.{
        state.sheath_nitrogen_g_n,
        state.sheath_phosphorus_g_p,
        state.sheath_height_m,
        state.internode_carbon_g_c,
        state.internode_nitrogen_g_n,
        state.internode_phosphorus_g_p,
        state.internode_length_m,
    }) |values| if (values.len != runtime_node_count)
        return error.SheathSenescenceDimensionMismatch;
    if (selected_node >= runtime_node_count)
        return error.SheathSenescenceNodeIndexOutOfBounds;
    if (!std.math.isFinite(structural_presence_threshold_g_c) or structural_presence_threshold_g_c < 0)
        return error.InvalidSheathSenescenceThreshold;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| {
        const value = @field(recycling, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidSheathSenescenceRecyclingFraction;
    }

    const sheath_carbon_g_c = state.sheath_carbon_g_c[selected_node];
    const sheath_nitrogen_g_n = state.sheath_nitrogen_g_n[selected_node];
    const sheath_phosphorus_g_p = state.sheath_phosphorus_g_p[selected_node];
    const sheath_height_m = state.sheath_height_m[selected_node];
    const internode_carbon_g_c = state.internode_carbon_g_c[selected_node];
    const internode_nitrogen_g_n = state.internode_nitrogen_g_n[selected_node];
    const internode_phosphorus_g_p = state.internode_phosphorus_g_p[selected_node];
    const internode_length_m = state.internode_length_m[selected_node];
    inline for (.{
        sheath_carbon_g_c,
        sheath_nitrogen_g_n,
        sheath_phosphorus_g_p,
        sheath_height_m,
        internode_carbon_g_c,
        internode_nitrogen_g_n,
        internode_phosphorus_g_p,
        internode_length_m,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSheathSenescenceNodeState;

    var remobilizable_carbon_g_c: f64 = 0;
    var remobilizable_nitrogen_g_n: f64 = 0;
    var remobilizable_phosphorus_g_p: f64 = 0;
    if (sheath_carbon_g_c > structural_presence_threshold_g_c) {
        remobilizable_carbon_g_c = sheath_carbon_g_c * recycling.carbon;
        remobilizable_nitrogen_g_n = sheath_nitrogen_g_n *
            (recycling.nitrogen + (1.0 - recycling.nitrogen) *
                remobilizable_carbon_g_c / sheath_carbon_g_c);
        remobilizable_phosphorus_g_p = sheath_phosphorus_g_p *
            (recycling.phosphorus + (1.0 - recycling.phosphorus) *
                remobilizable_carbon_g_c / sheath_carbon_g_c);
    }
    const residual_carbon_g_c = state.residual_stalk_carbon_g_c.* + internode_carbon_g_c;
    const residual_nitrogen_g_n = state.residual_stalk_nitrogen_g_n.* + internode_nitrogen_g_n;
    const residual_phosphorus_g_p = state.residual_stalk_phosphorus_g_p.* + internode_phosphorus_g_p;
    inline for (.{
        remobilizable_carbon_g_c,
        remobilizable_nitrogen_g_n,
        remobilizable_phosphorus_g_p,
        residual_carbon_g_c,
        residual_nitrogen_g_n,
        residual_phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSheathSenescenceResult;

    return .{
        .snapshot = .{
            .sheath_carbon_g_c = sheath_carbon_g_c,
            .sheath_nitrogen_g_n = sheath_nitrogen_g_n,
            .sheath_phosphorus_g_p = sheath_phosphorus_g_p,
            .sheath_height_m = sheath_height_m,
            .remobilizable_carbon_g_c = remobilizable_carbon_g_c,
            .remobilizable_nitrogen_g_n = remobilizable_nitrogen_g_n,
            .remobilizable_phosphorus_g_p = remobilizable_phosphorus_g_p,
        },
        .residual_stalk_carbon_g_c = residual_carbon_g_c,
        .residual_stalk_nitrogen_g_n = residual_nitrogen_g_n,
        .residual_stalk_phosphorus_g_p = residual_phosphorus_g_p,
    };
}

fn sampleState(
    sheath: *[4][4]f64,
    internode: *[4][4]f64,
    residual: *[3]f64,
) State {
    return .{
        .sheath_carbon_g_c = &sheath[0],
        .sheath_nitrogen_g_n = &sheath[1],
        .sheath_phosphorus_g_p = &sheath[2],
        .sheath_height_m = &sheath[3],
        .internode_carbon_g_c = &internode[0],
        .internode_nitrogen_g_n = &internode[1],
        .internode_phosphorus_g_p = &internode[2],
        .internode_length_m = &internode[3],
        .residual_stalk_carbon_g_c = &residual[0],
        .residual_stalk_nitrogen_g_n = &residual[1],
        .residual_stalk_phosphorus_g_p = &residual[2],
    };
}

const sample_recycling: RecyclingFractions = .{ .carbon = 0.5, .nitrogen = 0.6, .phosphorus = 0.7 };

test "GROSUB sheath snapshot and internode transfer preserve source equations" {
    var sheath: [4][4]f64 = @splat(@splat(0));
    var internode: [4][4]f64 = @splat(@splat(0));
    var residual = [_]f64{ 1, 0.1, 0.01 };
    sheath[0][2] = 4;
    sheath[1][2] = 0.4;
    sheath[2][2] = 0.04;
    sheath[3][2] = 0.8;
    internode[0][2] = 3;
    internode[1][2] = 0.3;
    internode[2][2] = 0.03;
    internode[3][2] = 0.5;
    const result = (try prepareAndTransfer(true, sampleState(&sheath, &internode, &residual), 2, 1.0e-9, sample_recycling)).?;
    try std.testing.expectEqual(@as(f64, 2), result.remobilizable_carbon_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.32), result.remobilizable_nitrogen_g_n, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.034), result.remobilizable_phosphorus_g_p, 1.0e-15);
    try std.testing.expectEqual(@as(f64, 4), residual[0]);
    try std.testing.expectEqual(@as(f64, 0.4), residual[1]);
    try std.testing.expectEqual(@as(f64, 0.04), residual[2]);
    try std.testing.expectEqual(@as(f64, 0), internode[0][2]);
    try std.testing.expectEqual(@as(f64, 0), internode[3][2]);
}

test "disabled sheath remobilization leaves selected internode untouched" {
    var sheath: [4][4]f64 = @splat(@splat(0));
    var internode: [4][4]f64 = @splat(@splat(0));
    var residual = [_]f64{ 0, 0, 0 };
    internode[0][1] = 3;
    const result = try prepareAndTransfer(false, sampleState(&sheath, &internode, &residual), 99, -1, sample_recycling);
    try std.testing.expectEqual(@as(?Snapshot, null), result);
    try std.testing.expectEqual(@as(f64, 3), internode[0][1]);
    try std.testing.expectEqual(@as(f64, 0), residual[0]);
}

test "runtime selected node can exceed source ring extent" {
    var residual = [_]f64{ 0, 0, 0 };
    // Use slices over separately allocated runtime storage for ordinal 30.
    var sheath_runtime: [4][31]f64 = @splat(@splat(0));
    var internode_runtime: [4][31]f64 = @splat(@splat(0));
    internode_runtime[0][30] = 2;
    const state: State = .{
        .sheath_carbon_g_c = &sheath_runtime[0],
        .sheath_nitrogen_g_n = &sheath_runtime[1],
        .sheath_phosphorus_g_p = &sheath_runtime[2],
        .sheath_height_m = &sheath_runtime[3],
        .internode_carbon_g_c = &internode_runtime[0],
        .internode_nitrogen_g_n = &internode_runtime[1],
        .internode_phosphorus_g_p = &internode_runtime[2],
        .internode_length_m = &internode_runtime[3],
        .residual_stalk_carbon_g_c = &residual[0],
        .residual_stalk_nitrogen_g_n = &residual[1],
        .residual_stalk_phosphorus_g_p = &residual[2],
    };
    _ = try prepareAndTransfer(true, state, 30, 0, sample_recycling);
    try std.testing.expectEqual(@as(f64, 2), residual[0]);
}

test "residual overflow is atomic" {
    var sheath: [4][4]f64 = @splat(@splat(0));
    var internode: [4][4]f64 = @splat(@splat(0));
    var residual = [_]f64{ std.math.floatMax(f64), 0, 0 };
    internode[0][1] = std.math.floatMax(f64);
    try std.testing.expectError(
        error.InvalidSheathSenescenceResult,
        prepareAndTransfer(true, sampleState(&sheath, &internode, &residual), 1, 0, sample_recycling),
    );
    try std.testing.expectEqual(std.math.floatMax(f64), internode[0][1]);
    try std.testing.expectEqual(std.math.floatMax(f64), residual[0]);
}

test "dimension and active index errors are explicit" {
    var sheath: [4][4]f64 = @splat(@splat(0));
    var internode: [4][4]f64 = @splat(@splat(0));
    var residual = [_]f64{ 0, 0, 0 };
    var state = sampleState(&sheath, &internode, &residual);
    state.internode_length_m = state.internode_length_m[0..3];
    try std.testing.expectError(error.SheathSenescenceDimensionMismatch, prepareAndTransfer(true, state, 0, 0, sample_recycling));
    try std.testing.expectError(error.SheathSenescenceNodeIndexOutOfBounds, prepareAndTransfer(true, sampleState(&sheath, &internode, &residual), 4, 0, sample_recycling));
}
