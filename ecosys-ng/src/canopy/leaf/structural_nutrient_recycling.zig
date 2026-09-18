const std = @import("std");

pub const State = struct {
    leaf_carbon_g_c: []const f64,
    leaf_nitrogen_g_n: []f64,
    leaf_phosphorus_g_p: []f64,
    leaf_protein_g: []f64,
    branch_leaf_nitrogen_g_n: *f64,
    branch_leaf_phosphorus_g_p: *f64,
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: *f64,
    mobile_phosphorus_g_p: *f64,
};
pub const Workspace = struct { nitrogen_g_n: []f64, phosphorus_g_p: []f64, protein_g: []f64 };
pub const Inputs = struct {
    first_node: usize,
    end_node: usize,
    carbon_pool_threshold_g_c: f64,
    minimum_relative_leaf_nutrient_fraction: f64,
    maximum_leaf_nitrogen_per_carbon_g_n_per_g_c: f64,
    maximum_leaf_phosphorus_per_carbon_g_p_per_g_c: f64,
    protein_per_nitrogen_g_per_g_n: f64,
    protein_per_phosphorus_g_per_g_p: f64,
};

/// grosub.f lines 3677--3704. Sweeps logical runtime nodes in ascending order.
/// Each node observes mobile N/P updated by preceding nodes. The source 1e-3
/// exchange coefficient and coupled 10:1 N:P lower bounds are retained.
pub fn apply(state: State, workspace: Workspace, inputs: Inputs) !void {
    const count = state.leaf_carbon_g_c.len;
    inline for (.{ state.leaf_nitrogen_g_n, state.leaf_phosphorus_g_p, state.leaf_protein_g }) |values| if (values.len != count) return error.LeafNutrientRecyclingDimensionMismatch;
    inline for (.{ workspace.nitrogen_g_n, workspace.phosphorus_g_p, workspace.protein_g }) |values| if (values.len < count) return error.LeafNutrientRecyclingWorkspaceTooSmall;
    if (inputs.first_node > inputs.end_node or inputs.end_node > count) return error.LeafNutrientRecyclingRangeOutOfBounds;
    inline for (.{ inputs.carbon_pool_threshold_g_c, inputs.minimum_relative_leaf_nutrient_fraction, inputs.maximum_leaf_nitrogen_per_carbon_g_n_per_g_c, inputs.maximum_leaf_phosphorus_per_carbon_g_p_per_g_c, inputs.protein_per_nitrogen_g_per_g_n, inputs.protein_per_phosphorus_g_per_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLeafNutrientRecyclingInput;
    if (inputs.minimum_relative_leaf_nutrient_fraction > 1) return error.InvalidLeafNutrientRecyclingInput;
    inline for (.{ state.branch_leaf_nitrogen_g_n.*, state.branch_leaf_phosphorus_g_p.*, state.mobile_carbon_g_c, state.mobile_nitrogen_g_n.*, state.mobile_phosphorus_g_p.* }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLeafNutrientRecyclingState;
    @memcpy(workspace.nitrogen_g_n[0..count], state.leaf_nitrogen_g_n);
    @memcpy(workspace.phosphorus_g_p[0..count], state.leaf_phosphorus_g_p);
    @memcpy(workspace.protein_g[0..count], state.leaf_protein_g);
    var branch_n = state.branch_leaf_nitrogen_g_n.*;
    var branch_p = state.branch_leaf_phosphorus_g_p.*;
    var mobile_n = state.mobile_nitrogen_g_n.*;
    var mobile_p = state.mobile_phosphorus_g_p.*;

    for (inputs.first_node..inputs.end_node) |node| {
        const leaf_c = state.leaf_carbon_g_c[node];
        inline for (.{ leaf_c, workspace.nitrogen_g_n[node], workspace.phosphorus_g_p[node], workspace.protein_g[node] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLeafNutrientRecyclingState;
        if (leaf_c <= 0) continue;
        const total_c = leaf_c + state.mobile_carbon_g_c;
        if (total_c <= inputs.carbon_pool_threshold_g_c) continue;
        const nitrogen_difference = workspace.nitrogen_g_n[node] * state.mobile_carbon_g_c - mobile_n * leaf_c;
        const base_n = @max(0, @min(1.0e-3 * nitrogen_difference / total_c, workspace.nitrogen_g_n[node] - inputs.minimum_relative_leaf_nutrient_fraction * inputs.maximum_leaf_nitrogen_per_carbon_g_n_per_g_c * leaf_c));
        const phosphorus_difference = workspace.phosphorus_g_p[node] * state.mobile_carbon_g_c - mobile_p * leaf_c;
        const base_p = @max(0, @min(1.0e-3 * phosphorus_difference / total_c, workspace.phosphorus_g_p[node] - inputs.minimum_relative_leaf_nutrient_fraction * inputs.maximum_leaf_phosphorus_per_carbon_g_p_per_g_c * leaf_c));
        const transfer_n = @max(base_n, 10 * base_p);
        const transfer_p = @max(base_p, 0.1 * base_n);
        if (transfer_n > workspace.nitrogen_g_n[node] or transfer_p > workspace.phosphorus_g_p[node] or transfer_n > branch_n or transfer_p > branch_p) return error.LeafNutrientRecyclingOverdraw;
        workspace.nitrogen_g_n[node] -= transfer_n;
        branch_n -= transfer_n;
        mobile_n += transfer_n;
        workspace.phosphorus_g_p[node] -= transfer_p;
        branch_p -= transfer_p;
        mobile_p += transfer_p;
        workspace.protein_g[node] = @max(0, workspace.protein_g[node] - @max(transfer_n * inputs.protein_per_nitrogen_g_per_g_n, transfer_p * inputs.protein_per_phosphorus_g_per_g_p));
        inline for (.{ branch_n, branch_p, mobile_n, mobile_p, workspace.nitrogen_g_n[node], workspace.phosphorus_g_p[node], workspace.protein_g[node] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLeafNutrientRecyclingResult;
    }
    @memcpy(state.leaf_nitrogen_g_n, workspace.nitrogen_g_n[0..count]);
    @memcpy(state.leaf_phosphorus_g_p, workspace.phosphorus_g_p[0..count]);
    @memcpy(state.leaf_protein_g, workspace.protein_g[0..count]);
    state.branch_leaf_nitrogen_g_n.* = branch_n;
    state.branch_leaf_phosphorus_g_p.* = branch_p;
    state.mobile_nitrogen_g_n.* = mobile_n;
    state.mobile_phosphorus_g_p.* = mobile_p;
}

fn fixture(c: []const f64, n: []f64, p: []f64, protein: []f64, scalars: *[5]f64) State {
    return .{ .leaf_carbon_g_c = c, .leaf_nitrogen_g_n = n, .leaf_phosphorus_g_p = p, .leaf_protein_g = protein, .branch_leaf_nitrogen_g_n = &scalars[0], .branch_leaf_phosphorus_g_p = &scalars[1], .mobile_carbon_g_c = scalars[2], .mobile_nitrogen_g_n = &scalars[3], .mobile_phosphorus_g_p = &scalars[4] };
}
fn testInputs(end: usize) Inputs {
    return .{ .first_node = 0, .end_node = end, .carbon_pool_threshold_g_c = 0, .minimum_relative_leaf_nutrient_fraction = 0, .maximum_leaf_nitrogen_per_carbon_g_n_per_g_c = 1, .maximum_leaf_phosphorus_per_carbon_g_p_per_g_c = 1, .protein_per_nitrogen_g_per_g_n = 2, .protein_per_phosphorus_g_per_g_p = 20 };
}

test "ascending runtime sweep conserves N and P and couples transfers" {
    var c = [_]f64{ 1, 1 };
    var n = [_]f64{ 1, 1 };
    var p = [_]f64{ 0.2, 0.2 };
    var protein = [_]f64{ 5, 5 };
    var s = [_]f64{ 2, 0.4, 100, 0, 0 };
    var wn: [2]f64 = undefined;
    var wp: [2]f64 = undefined;
    var wr: [2]f64 = undefined;
    const n_before = s[0] + s[3];
    const p_before = s[1] + s[4];
    try apply(fixture(&c, &n, &p, &protein, &s), .{ .nitrogen_g_n = &wn, .phosphorus_g_p = &wp, .protein_g = &wr }, testInputs(2));
    try std.testing.expectApproxEqAbs(n_before, s[0] + s[3], 1e-15);
    try std.testing.expectApproxEqAbs(p_before, s[1] + s[4], 1e-15);
    try std.testing.expect(s[3] > 0);
    try std.testing.expect(s[4] > 0);
}
test "runtime sweep beyond legacy ring processes node thirty" {
    var c: [31]f64 = @splat(0);
    var n: [31]f64 = @splat(0);
    var p: [31]f64 = @splat(0);
    var protein: [31]f64 = @splat(0);
    c[30] = 1;
    n[30] = 1;
    p[30] = 0.1;
    protein[30] = 2;
    var s = [_]f64{ 1, 0.1, 100, 0, 0 };
    var wn: [31]f64 = undefined;
    var wp: [31]f64 = undefined;
    var wr: [31]f64 = undefined;
    try apply(fixture(&c, &n, &p, &protein, &s), .{ .nitrogen_g_n = &wn, .phosphorus_g_p = &wp, .protein_g = &wr }, testInputs(31));
    try std.testing.expect(n[30] < 1);
}
test "late overdraw leaves caller state unchanged" {
    var c = [_]f64{ 1, 1 };
    var n = [_]f64{ 1, 1 };
    var p = [_]f64{ 0.2, 0.2 };
    var protein = [_]f64{ 5, 5 };
    var s = [_]f64{ 2, 0.4, 100, 0, 0 };
    var wn: [2]f64 = undefined;
    var wp: [2]f64 = undefined;
    var wr: [2]f64 = undefined;
    var bad = testInputs(2);
    bad.minimum_relative_leaf_nutrient_fraction = 0;
    s[0] = 0.000001;
    try std.testing.expectError(error.LeafNutrientRecyclingOverdraw, apply(fixture(&c, &n, &p, &protein, &s), .{ .nitrogen_g_n = &wn, .phosphorus_g_p = &wp, .protein_g = &wr }, bad));
    try std.testing.expectEqual(@as(f64, 1), n[0]);
    try std.testing.expectEqual(@as(f64, 0), s[3]);
}
