const std = @import("std");

pub const Inputs = struct {
    newest_growing_node: usize,
    maximum_concurrently_growing_nodes: usize,
    maximum_previous_nodes_in_rolling_window: usize,
    runtime_node_count: usize,
    emergence_date_is_set: bool,
};

pub const Window = struct {
    first_node: usize,
    last_node: usize,
    node_count: usize,
    allocation_fraction: f64,
};

/// grosub.f lines 2405--2419. The nested MIN/MAX expression is retained
/// literally because its result differs from the leaf/sheath node window.
/// The source's `23` rolling bound is supplied at runtime rather than compiled
/// into model topology; a value of 23 reproduces the Fortran configuration.
pub fn calculate(inputs: Inputs) !Window {
    if (inputs.runtime_node_count == 0 or
        inputs.maximum_concurrently_growing_nodes == 0)
        return error.InvalidStalkGrowingNodeWindowInput;
    if (inputs.newest_growing_node >= inputs.runtime_node_count)
        return error.StalkGrowingNodeIndexOutOfBounds;

    const emergence_lower_bound: i128 = if (inputs.emergence_date_is_set) 1 else 0;
    const newest: i128 = @intCast(inputs.newest_growing_node);
    const concurrent: i128 = @intCast(inputs.maximum_concurrently_growing_nodes);
    const rolling_previous: i128 = @intCast(inputs.maximum_previous_nodes_in_rolling_window);

    // MNNOD=MAX(MIN(NN,MAX(NN,MXNOD-NNOD)),KVSTG-23)
    const concurrent_difference = newest - concurrent;
    const inner_max = @max(emergence_lower_bound, concurrent_difference);
    const inner_min = @min(emergence_lower_bound, inner_max);
    const rolling_first = newest - rolling_previous;
    const first_signed = @max(inner_min, rolling_first);
    const last_signed = @max(newest, first_signed);
    if (first_signed < 0 or last_signed < 0)
        return error.InvalidStalkGrowingNodeWindowResult;

    const first_node: usize = @intCast(first_signed);
    const last_node: usize = @intCast(last_signed);
    if (last_node >= inputs.runtime_node_count)
        return error.StalkGrowingNodeIndexOutOfBounds;
    const node_count = last_node - first_node + 1;
    const allocation_fraction = 1.0 / @as(f64, @floatFromInt(node_count));
    if (!std.math.isFinite(allocation_fraction) or allocation_fraction <= 0)
        return error.InvalidStalkGrowingNodeWindowResult;
    return .{
        .first_node = first_node,
        .last_node = last_node,
        .node_count = node_count,
        .allocation_fraction = allocation_fraction,
    };
}

test "GROSUB nested MIN MAX does not apply concurrent-node truncation" {
    const window = try calculate(.{
        .newest_growing_node = 10,
        .maximum_concurrently_growing_nodes = 3,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 40,
        .emergence_date_is_set = true,
    });
    // A conventional newest+1-maximum calculation would start at eight;
    // the literal source expression starts at the emergence lower bound.
    try std.testing.expectEqual(@as(usize, 1), window.first_node);
    try std.testing.expectEqual(@as(usize, 10), window.last_node);
    try std.testing.expectEqual(@as(usize, 10), window.node_count);
    try std.testing.expectEqual(@as(f64, 0.1), window.allocation_fraction);
}

test "runtime rolling span replaces source twenty three constant" {
    const source_window = try calculate(.{
        .newest_growing_node = 30,
        .maximum_concurrently_growing_nodes = 2,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 48,
        .emergence_date_is_set = true,
    });
    try std.testing.expectEqual(@as(usize, 7), source_window.first_node);
    try std.testing.expectEqual(@as(usize, 24), source_window.node_count);

    const expanded_window = try calculate(.{
        .newest_growing_node = 30,
        .maximum_concurrently_growing_nodes = 2,
        .maximum_previous_nodes_in_rolling_window = 29,
        .runtime_node_count = 48,
        .emergence_date_is_set = true,
    });
    try std.testing.expectEqual(@as(usize, 1), expanded_window.first_node);
    try std.testing.expectEqual(@as(usize, 30), expanded_window.node_count);
}

test "emergence state controls node zero and source MAX advances last node" {
    const pre_emergence = try calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 4,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 4,
        .emergence_date_is_set = false,
    });
    try std.testing.expectEqual(@as(usize, 0), pre_emergence.first_node);
    try std.testing.expectEqual(@as(usize, 0), pre_emergence.last_node);

    const emerged = try calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 4,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 4,
        .emergence_date_is_set = true,
    });
    try std.testing.expectEqual(@as(usize, 1), emerged.first_node);
    try std.testing.expectEqual(@as(usize, 1), emerged.last_node);
}

test "invalid runtime topology fails explicitly" {
    try std.testing.expectError(error.InvalidStalkGrowingNodeWindowInput, calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 0,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 1,
        .emergence_date_is_set = false,
    }));
    try std.testing.expectError(error.StalkGrowingNodeIndexOutOfBounds, calculate(.{
        .newest_growing_node = 2,
        .maximum_concurrently_growing_nodes = 1,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 2,
        .emergence_date_is_set = false,
    }));
    try std.testing.expectError(error.StalkGrowingNodeIndexOutOfBounds, calculate(.{
        .newest_growing_node = 0,
        .maximum_concurrently_growing_nodes = 1,
        .maximum_previous_nodes_in_rolling_window = 23,
        .runtime_node_count = 1,
        .emergence_date_is_set = true,
    }));
}
