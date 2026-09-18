const std = @import("std");

/// Exact grosub.f lines 2096--2098 admission to C4 mesophyll/bundle-sheath
/// exchange. Leaf carbon and the plant-specific ZEROP threshold are g C.
/// Runtime node masks replace the fixed source K=1..25 loop.
pub fn computeRuntimeNodes(
    is_c4_pathway: bool,
    leaf_carbon_g_c_by_node: []const f64,
    leaf_carbon_presence_threshold_g_c: f64,
    scratch: []bool,
    destination: []bool,
) !void {
    const node_count = leaf_carbon_g_c_by_node.len;
    if (node_count == 0 or
        scratch.len != node_count or
        destination.len != node_count)
        return error.CanopyC4NodeExchangeEligibilityDimensionMismatch;
    if (!std.math.isFinite(leaf_carbon_presence_threshold_g_c) or
        leaf_carbon_presence_threshold_g_c < 0)
        return error.InvalidCanopyC4LeafCarbonThreshold;

    for (leaf_carbon_g_c_by_node, scratch) |leaf_carbon_g_c, *candidate| {
        if (!std.math.isFinite(leaf_carbon_g_c) or leaf_carbon_g_c < 0)
            return error.InvalidCanopyC4NodeLeafCarbon;
        candidate.* = try admitsNode(
            is_c4_pathway,
            leaf_carbon_g_c,
            leaf_carbon_presence_threshold_g_c,
        );
    }
    @memcpy(destination, scratch);
}

/// GROSUB 2096--2098 scalar admission for one runtime node. The comparison
/// remains strict: a node at ZEROP is not admitted.
pub fn admitsNode(
    is_c4_pathway: bool,
    leaf_carbon_g_c: f64,
    leaf_carbon_presence_threshold_g_c: f64,
) !bool {
    if (!std.math.isFinite(leaf_carbon_presence_threshold_g_c) or
        leaf_carbon_presence_threshold_g_c < 0)
        return error.InvalidCanopyC4LeafCarbonThreshold;
    if (!std.math.isFinite(leaf_carbon_g_c) or leaf_carbon_g_c < 0)
        return error.InvalidCanopyC4NodeLeafCarbon;
    return is_c4_pathway and leaf_carbon_g_c > leaf_carbon_presence_threshold_g_c;
}

test "GROSUB admits arbitrary runtime C4 nodes in K order" {
    const allocator = std.testing.allocator;
    const node_count = 34;
    const leaf_carbon = try allocator.alloc(f64, node_count);
    defer allocator.free(leaf_carbon);
    const scratch = try allocator.alloc(bool, node_count);
    defer allocator.free(scratch);
    const admitted = try allocator.alloc(bool, node_count);
    defer allocator.free(admitted);
    for (leaf_carbon, 0..) |*carbon_g_c, node|
        carbon_g_c.* = @as(f64, @floatFromInt(node)) * 0.1;

    try computeRuntimeNodes(true, leaf_carbon, 1.5, scratch, admitted);

    for (admitted, 0..) |is_admitted, node|
        try std.testing.expectEqual(node > 15, is_admitted);
}

test "source carbon threshold is strict and C3 rejects every node" {
    const leaf_carbon = [_]f64{ 0.9, 1.0, 1.1 };
    var scratch: [3]bool = undefined;
    var admitted: [3]bool = undefined;
    try computeRuntimeNodes(true, &leaf_carbon, 1, &scratch, &admitted);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &admitted);
    try computeRuntimeNodes(false, &leaf_carbon, 0, &scratch, &admitted);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, &admitted);
}

test "invalid late leaf carbon preserves published admission" {
    const leaf_carbon = [_]f64{ 1, std.math.nan(f64) };
    var scratch: [2]bool = undefined;
    var admitted = [_]bool{ false, true };
    try std.testing.expectError(
        error.InvalidCanopyC4NodeLeafCarbon,
        computeRuntimeNodes(true, &leaf_carbon, 0, &scratch, &admitted),
    );
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &admitted);
}

test "runtime node topology mismatch fails explicitly" {
    const leaf_carbon = [_]f64{ 1, 2 };
    var short_scratch: [1]bool = undefined;
    var admitted: [2]bool = undefined;
    try std.testing.expectError(
        error.CanopyC4NodeExchangeEligibilityDimensionMismatch,
        computeRuntimeNodes(true, &leaf_carbon, 0, &short_scratch, &admitted),
    );
}
