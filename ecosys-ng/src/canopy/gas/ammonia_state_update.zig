const std = @import("std");

/// Runtime EXTRACT `RNH3C` current-hour and `TNH3C` daily plant owners.
pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    current_exchange_g_n_per_h_by_plant: []f64,
    cumulative_exchange_g_n_by_plant: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0)
            return error.InvalidCanopyAmmoniaStateUpdateDimensions;
        const values = try allocator.alloc(f64, 2 * plant_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .current_exchange_g_n_per_h_by_plant = values[0..plant_count],
            .cumulative_exchange_g_n_by_plant = values[plant_count..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.current_exchange_g_n_per_h_by_plant.ptr[0 .. 2 * self.plant_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    plant_branch_offsets: []const usize,
    branch_exchange_g_n_per_h: []const f64,
    preceding_cumulative_exchange_g_n_by_plant: []const f64,
};

/// Exact EXTRACT lines 965–969. Every current branch sum and next daily
/// cumulative owner is preflighted before either plant array changes.
pub fn refresh(state: *State, inputs: Inputs) !void {
    if (inputs.plant_branch_offsets.len != state.plant_count + 1 or
        inputs.plant_branch_offsets[0] != 0 or
        inputs.preceding_cumulative_exchange_g_n_by_plant.len !=
            state.plant_count)
        return error.InvalidCanopyAmmoniaStateUpdateDimensions;
    const branch_count = inputs.plant_branch_offsets[state.plant_count];
    if (inputs.branch_exchange_g_n_per_h.len != branch_count)
        return error.InvalidCanopyAmmoniaStateUpdateDimensions;
    var previous: usize = 0;
    for (inputs.plant_branch_offsets) |offset| {
        if (offset < previous or offset > branch_count)
            return error.InvalidCanopyAmmoniaStateUpdateTopology;
        previous = offset;
    }

    for (0..state.plant_count) |plant|
        _ = try totalsFor(inputs, plant);

    for (0..state.plant_count) |plant| {
        const totals = totalsFor(inputs, plant) catch unreachable;
        state.current_exchange_g_n_per_h_by_plant[plant] = totals.current;
        state.cumulative_exchange_g_n_by_plant[plant] = totals.cumulative;
    }
}

const Totals = struct {
    current: f64,
    cumulative: f64,
};

fn totalsFor(inputs: Inputs, plant: usize) !Totals {
    const preceding = inputs.preceding_cumulative_exchange_g_n_by_plant[plant];
    if (!std.math.isFinite(preceding))
        return error.NonFiniteCanopyAmmoniaStateUpdateInput;
    var current: f64 = 0;
    var cumulative = preceding;
    for (
        inputs.branch_exchange_g_n_per_h[inputs.plant_branch_offsets[plant]..inputs.plant_branch_offsets[plant + 1]],
    ) |exchange| {
        if (!std.math.isFinite(exchange))
            return error.NonFiniteCanopyAmmoniaStateUpdateInput;
        current += exchange;
        cumulative += exchange;
    }
    if (!std.math.isFinite(current) or !std.math.isFinite(cumulative))
        return error.NonFiniteCanopyAmmoniaStateUpdate;
    return .{ .current = current, .cumulative = cumulative };
}

test "canopy ammonia state_update preserves branch order and daily carry" {
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    try refresh(&state, .{
        .plant_branch_offsets = &.{ 0, 2, 3, 5 },
        .branch_exchange_g_n_per_h = &.{ 1, -0.25, 2, -3, 1 },
        .preceding_cumulative_exchange_g_n_by_plant = &.{ 10, 20, 30 },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0.75, 2, -2 },
        state.current_exchange_g_n_per_h_by_plant,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 10.75, 22, 28 },
        state.cumulative_exchange_g_n_by_plant,
    );
}

test "daily canopy ammonia advances branch by branch" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try refresh(&state, .{
        .plant_branch_offsets = &.{ 0, 3 },
        .branch_exchange_g_n_per_h = &.{ 1.0e16, -1.0e16, 1 },
        .preceding_cumulative_exchange_g_n_by_plant = &.{1},
    });
    try std.testing.expectEqual(@as(f64, 1), state.current_exchange_g_n_per_h_by_plant[0]);
    try std.testing.expectEqual(@as(f64, 1), state.cumulative_exchange_g_n_by_plant[0]);
}

test "late invalid canopy ammonia preserves current and cumulative owners" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.current_exchange_g_n_per_h_by_plant, 7);
    @memset(state.cumulative_exchange_g_n_by_plant, 8);
    try std.testing.expectError(
        error.NonFiniteCanopyAmmoniaStateUpdateInput,
        refresh(&state, .{
            .plant_branch_offsets = &.{ 0, 1, 2 },
            .branch_exchange_g_n_per_h = &.{ 1, std.math.nan(f64) },
            .preceding_cumulative_exchange_g_n_by_plant = &.{ 2, 3 },
        }),
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 7, 7 },
        state.current_exchange_g_n_per_h_by_plant,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 8, 8 },
        state.cumulative_exchange_g_n_by_plant,
    );
}
