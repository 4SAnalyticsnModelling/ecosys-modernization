const std = @import("std");

pub const Inputs = struct {
    newest_growing_node: usize,
    maximum_concurrently_growing_nodes: usize,
    runtime_node_count: usize,
    is_main_branch: bool,
    canopy_height_m: f64,
    sowing_depth_m: f64,
};

pub const Window = struct {
    first_node: usize,
    last_node: usize,
    node_count: usize,
    allocation_fraction: f64,
};

/// grosub.f lines 2270--2282. This translates the Fortran node-zero admission
/// condition and growing-node window without retaining its fixed 25-node ring.
/// The returned inclusive indexes are local to one runtime-sized branch.
pub fn calculate(inputs: Inputs) !Window {
    if (!std.math.isFinite(inputs.canopy_height_m) or
        !std.math.isFinite(inputs.sowing_depth_m))
        return error.NonFiniteGrowingNodeWindowInput;
    if (inputs.canopy_height_m < 0 or
        inputs.sowing_depth_m < 0 or
        inputs.runtime_node_count == 0 or
        inputs.maximum_concurrently_growing_nodes == 0)
        return error.InvalidGrowingNodeWindowInput;
    if (inputs.newest_growing_node >= inputs.runtime_node_count)
        return error.GrowingNodeIndexOutOfBounds;

    // NNOD1=0 only for the main branch before emergence through sowing depth;
    // every other state starts at source node one.
    const source_lower_bound: usize = if (inputs.is_main_branch and
        inputs.canopy_height_m <= inputs.sowing_depth_m) 0 else 1;
    const unconstrained_first = inputs.newest_growing_node + 1 -|
        inputs.maximum_concurrently_growing_nodes;
    const first_node = @max(source_lower_bound, unconstrained_first);
    const last_node = @max(inputs.newest_growing_node, first_node);
    if (last_node >= inputs.runtime_node_count)
        return error.GrowingNodeIndexOutOfBounds;

    const node_count = last_node - first_node + 1;
    const allocation_fraction = 1.0 / @as(f64, @floatFromInt(node_count));
    if (!std.math.isFinite(allocation_fraction) or allocation_fraction <= 0)
        return error.InvalidGrowingNodeWindowResult;
    return .{
        .first_node = first_node,
        .last_node = last_node,
        .node_count = node_count,
        .allocation_fraction = allocation_fraction,
    };
}

test "GROSUB admits node zero only for submerged main branch" {
    const submerged = try calculate(.{
        .newest_growing_node = 3,
        .maximum_concurrently_growing_nodes = 5,
        .runtime_node_count = 8,
        .is_main_branch = true,
        .canopy_height_m = 0.02,
        .sowing_depth_m = 0.03,
    });
    try std.testing.expectEqual(@as(usize, 0), submerged.first_node);
    try std.testing.expectEqual(@as(usize, 3), submerged.last_node);
    try std.testing.expectEqual(@as(usize, 4), submerged.node_count);
    try std.testing.expectEqual(@as(f64, 0.25), submerged.allocation_fraction);

    const emerged = try calculate(.{
        .newest_growing_node = 3,
        .maximum_concurrently_growing_nodes = 5,
        .runtime_node_count = 8,
        .is_main_branch = true,
        .canopy_height_m = 0.031,
        .sowing_depth_m = 0.03,
    });
    try std.testing.expectEqual(@as(usize, 1), emerged.first_node);
    try std.testing.expectEqual(@as(usize, 3), emerged.last_node);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), emerged.allocation_fraction, 1.0e-15);
}

test "side branch excludes node zero regardless of canopy height" {
    const window = try calculate(.{
        .newest_growing_node = 4,
        .maximum_concurrently_growing_nodes = 2,
        .runtime_node_count = 7,
        .is_main_branch = false,
        .canopy_height_m = 0,
        .sowing_depth_m = 0.1,
    });
    try std.testing.expectEqual(@as(usize, 3), window.first_node);
    try std.testing.expectEqual(@as(usize, 4), window.last_node);
    try std.testing.expectEqual(@as(f64, 0.5), window.allocation_fraction);
}

test "source max operation advances an inadmissible newest node zero" {
    const window = try calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 3,
        .runtime_node_count = 4,
        .is_main_branch = false,
        .canopy_height_m = 0,
        .sowing_depth_m = 0.1,
    });
    try std.testing.expectEqual(@as(usize, 1), window.first_node);
    try std.testing.expectEqual(@as(usize, 1), window.last_node);
    try std.testing.expectEqual(@as(usize, 1), window.node_count);
}

test "runtime topology and physical-domain errors fail explicitly" {
    try std.testing.expectError(error.GrowingNodeIndexOutOfBounds, calculate(.{
        .newest_growing_node = 4,
        .maximum_concurrently_growing_nodes = 2,
        .runtime_node_count = 4,
        .is_main_branch = true,
        .canopy_height_m = 0.2,
        .sowing_depth_m = 0.03,
    }));
    try std.testing.expectError(error.InvalidGrowingNodeWindowInput, calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 0,
        .runtime_node_count = 1,
        .is_main_branch = true,
        .canopy_height_m = 0,
        .sowing_depth_m = 0,
    }));
    try std.testing.expectError(error.NonFiniteGrowingNodeWindowInput, calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 1,
        .runtime_node_count = 1,
        .is_main_branch = true,
        .canopy_height_m = std.math.nan(f64),
        .sowing_depth_m = 0,
    }));
}
