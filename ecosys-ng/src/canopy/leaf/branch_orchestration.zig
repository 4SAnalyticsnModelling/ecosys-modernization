const std = @import("std");

pub const NodeState = struct {
    internode_height_m: []f64,
    sheath_height_m: []const f64,
    leaf_area_m2: []const f64,
    sheath_protein_g: []const f64,
};

pub const Workspace = struct {
    stalk_height_m: []f64,
    leaf_base_height_m: []f64,
    leaf_length_m: []f64,
};

pub const Inputs = struct {
    first_leafed_node: usize,
    end_leafed_node: usize,
    latest_node: usize,
    branch_base_height_m: f64,
    plant_population_per_m2: f64,
    leaf_length_to_width_ratio: f64,
    canopy_height_before_branch_m: f64,
    /// Highest leaf-tip height returned by the existing per-node allocator.
    allocated_leaf_top_height_m: []const f64,
};

pub const Result = struct {
    lowest_live_node: ?usize,
    canopy_height_after_branch_m: f64,
    branch_stalk_tip_height_m: f64,
    latest_internode_copied_from_previous: bool,
};

/// grosub.f lines 3774--3894 around allocateLeafAcrossCanopyLayers. Prepares
/// node geometry in ascending logical-node order, accumulates allocator leaf
/// tops into ZC, records the first node with living sheath protein, applies the
/// latest-internode fallback from its immediate predecessor, and forms HTLFB.
pub fn apply(state: NodeState, workspace: Workspace, inputs: Inputs) !Result {
    const node_count = state.internode_height_m.len;
    inline for (.{ state.sheath_height_m, state.leaf_area_m2, state.sheath_protein_g, inputs.allocated_leaf_top_height_m }) |values|
        if (values.len != node_count) return error.CanopyBranchLeafDimensionMismatch;
    inline for (.{ workspace.stalk_height_m, workspace.leaf_base_height_m, workspace.leaf_length_m }) |values|
        if (values.len < node_count) return error.CanopyBranchLeafWorkspaceTooSmall;
    if (inputs.first_leafed_node >= inputs.end_leafed_node or inputs.end_leafed_node > node_count or inputs.latest_node >= node_count or inputs.latest_node != inputs.end_leafed_node - 1)
        return error.CanopyBranchLeafNodeRangeOutOfBounds;
    inline for (.{ inputs.branch_base_height_m, inputs.plant_population_per_m2, inputs.leaf_length_to_width_ratio, inputs.canopy_height_before_branch_m }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyBranchLeafInput;
    if (inputs.branch_base_height_m < 0 or inputs.plant_population_per_m2 <= 0 or inputs.leaf_length_to_width_ratio < 0 or inputs.canopy_height_before_branch_m < 0)
        return error.InvalidCanopyBranchLeafInput;

    var canopy_height_m = inputs.canopy_height_before_branch_m;
    var lowest_live_node: ?usize = null;
    for (inputs.first_leafed_node..inputs.end_leafed_node) |node| {
        inline for (.{ state.internode_height_m[node], state.sheath_height_m[node], state.leaf_area_m2[node], state.sheath_protein_g[node], inputs.allocated_leaf_top_height_m[node] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyBranchLeafNodeState;
        workspace.stalk_height_m[node] = inputs.branch_base_height_m + state.internode_height_m[node];
        workspace.leaf_base_height_m[node] = workspace.stalk_height_m[node] + state.sheath_height_m[node];
        workspace.leaf_length_m[node] = @max(0, @sqrt(inputs.leaf_length_to_width_ratio * @max(0, state.leaf_area_m2[node]) / inputs.plant_population_per_m2));
        canopy_height_m = @max(canopy_height_m, inputs.allocated_leaf_top_height_m[node]);
        if (lowest_live_node == null and state.sheath_protein_g[node] > 0) lowest_live_node = node;
        inline for (.{ workspace.stalk_height_m[node], workspace.leaf_base_height_m[node], workspace.leaf_length_m[node], canopy_height_m }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyBranchLeafResult;
    }

    var latest_height_m = state.internode_height_m[inputs.latest_node];
    if (!std.math.isFinite(latest_height_m) or latest_height_m < 0) return error.InvalidCanopyBranchLeafNodeState;
    var copied = false;
    if (latest_height_m == 0) {
        // K2 is MAX(0,MOD(KVSTG-1,25)); at logical node zero the source
        // therefore copies node zero to itself rather than addressing -1.
        const previous_node = inputs.latest_node -| 1;
        const previous_height_m = state.internode_height_m[previous_node];
        if (!std.math.isFinite(previous_height_m) or previous_height_m < 0) return error.InvalidCanopyBranchLeafNodeState;
        latest_height_m = previous_height_m;
        copied = true;
    }
    const branch_stalk_tip_height_m = inputs.branch_base_height_m + @max(0, latest_height_m);
    if (!std.math.isFinite(branch_stalk_tip_height_m)) return error.InvalidCanopyBranchLeafResult;

    if (copied) state.internode_height_m[inputs.latest_node] = latest_height_m;
    return .{
        .lowest_live_node = lowest_live_node,
        .canopy_height_after_branch_m = canopy_height_m,
        .branch_stalk_tip_height_m = branch_stalk_tip_height_m,
        .latest_internode_copied_from_previous = copied,
    };
}

fn testWorkspace(storage: *[3][32]f64, count: usize) Workspace {
    return .{ .stalk_height_m = storage[0][0..count], .leaf_base_height_m = storage[1][0..count], .leaf_length_m = storage[2][0..count] };
}

test "ascending runtime orchestration prepares geometry and records first live node" {
    var internode = [_]f64{ 1, 2, 0 };
    var storage: [3][32]f64 = undefined;
    const result = try apply(.{
        .internode_height_m = &internode,
        .sheath_height_m = &.{ 0.1, 0.2, 0.3 },
        .leaf_area_m2 = &.{ 1, 4, 9 },
        .sheath_protein_g = &.{ 0, 2, 3 },
    }, testWorkspace(&storage, 3), .{
        .first_leafed_node = 0,
        .end_leafed_node = 3,
        .latest_node = 2,
        .branch_base_height_m = 0.5,
        .plant_population_per_m2 = 4,
        .leaf_length_to_width_ratio = 4,
        .canopy_height_before_branch_m = 2,
        .allocated_leaf_top_height_m = &.{ 1.5, 4, 3 },
    });
    try std.testing.expectEqual(@as(?usize, 1), result.lowest_live_node);
    try std.testing.expectEqual(@as(f64, 4), result.canopy_height_after_branch_m);
    try std.testing.expectEqual(@as(f64, 1.5), storage[0][0]);
    try std.testing.expectEqual(@as(f64, 1), storage[2][0]);
    try std.testing.expectEqual(@as(f64, 2), internode[2]);
    try std.testing.expectEqual(@as(f64, 2.5), result.branch_stalk_tip_height_m);
}

test "logical node zero is represented without sentinel ambiguity" {
    var internode = [_]f64{1};
    var storage: [3][32]f64 = undefined;
    const result = try apply(.{ .internode_height_m = &internode, .sheath_height_m = &.{0}, .leaf_area_m2 = &.{1}, .sheath_protein_g = &.{1} }, testWorkspace(&storage, 1), .{ .first_leafed_node = 0, .end_leafed_node = 1, .latest_node = 0, .branch_base_height_m = 0, .plant_population_per_m2 = 1, .leaf_length_to_width_ratio = 1, .canopy_height_before_branch_m = 0, .allocated_leaf_top_height_m = &.{1} });
    try std.testing.expectEqual(@as(?usize, 0), result.lowest_live_node);
}

test "runtime node thirty participates without ring truncation" {
    var internode: [31]f64 = @splat(1);
    var sheath: [31]f64 = @splat(0);
    var area: [31]f64 = @splat(1);
    var protein: [31]f64 = @splat(0);
    var tops: [31]f64 = @splat(0);
    protein[30] = 1;
    tops[30] = 9;
    var storage: [3][32]f64 = undefined;
    const result = try apply(.{ .internode_height_m = &internode, .sheath_height_m = &sheath, .leaf_area_m2 = &area, .sheath_protein_g = &protein }, testWorkspace(&storage, 31), .{ .first_leafed_node = 25, .end_leafed_node = 31, .latest_node = 30, .branch_base_height_m = 0, .plant_population_per_m2 = 1, .leaf_length_to_width_ratio = 1, .canopy_height_before_branch_m = 0, .allocated_leaf_top_height_m = &tops });
    try std.testing.expectEqual(@as(?usize, 30), result.lowest_live_node);
    try std.testing.expectEqual(@as(f64, 9), result.canopy_height_after_branch_m);
}

test "logical node zero fallback copies itself as in source" {
    var internode = [_]f64{0};
    var storage: [3][32]f64 = undefined;
    const result = try apply(.{ .internode_height_m = &internode, .sheath_height_m = &.{0}, .leaf_area_m2 = &.{1}, .sheath_protein_g = &.{1} }, testWorkspace(&storage, 1), .{ .first_leafed_node = 0, .end_leafed_node = 1, .latest_node = 0, .branch_base_height_m = 0, .plant_population_per_m2 = 1, .leaf_length_to_width_ratio = 1, .canopy_height_before_branch_m = 0, .allocated_leaf_top_height_m = &.{1} });
    try std.testing.expectEqual(@as(f64, 0), internode[0]);
    try std.testing.expect(result.latest_internode_copied_from_previous);
    try std.testing.expectEqual(@as(f64, 0), result.branch_stalk_tip_height_m);
}

test "latest node must close the traversed retained window" {
    var internode = [_]f64{ 1, 2 };
    var storage: [3][32]f64 = undefined;
    try std.testing.expectError(error.CanopyBranchLeafNodeRangeOutOfBounds, apply(.{
        .internode_height_m = &internode,
        .sheath_height_m = &.{ 0, 0 },
        .leaf_area_m2 = &.{ 1, 1 },
        .sheath_protein_g = &.{ 0, 0 },
    }, testWorkspace(&storage, 2), .{
        .first_leafed_node = 0,
        .end_leafed_node = 2,
        .latest_node = 0,
        .branch_base_height_m = 0,
        .plant_population_per_m2 = 1,
        .leaf_length_to_width_ratio = 1,
        .canopy_height_before_branch_m = 0,
        .allocated_leaf_top_height_m = &.{ 1, 2 },
    }));
}
