const std = @import("std");

pub const element_count: usize = 3;

/// EXTRACT element order: C, N, P. Values are soil-side changes by cell.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    change_g_element_per_h_by_element_and_cell: [element_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0)
            return error.InvalidRootSoilElementStateUpdateDimensions;
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, element_count, cell_count),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .change_g_element_per_h_by_element_and_cell = .{
                values[0..cell_count],
                values[cell_count .. 2 * cell_count],
                values[2 * cell_count .. 3 * cell_count],
            },
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.change_g_element_per_h_by_element_and_cell[0]
                .ptr[0 .. element_count * self.cell_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_by_plant: []const bool,
    exchange_g_element_per_h_by_element_and_plant: [element_count][]const f64,
};

/// Exact EXTRACT lines 946–948. `ZCSNC/ZZSNC/ZPSNC -= H*UPTK` is
/// preserved across runtime active plant species as one atomic state_update.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    if (inputs.active_by_plant.len != plant_count)
        return error.InvalidRootSoilElementStateUpdateDimensions;
    inline for (
        inputs.exchange_g_element_per_h_by_element_and_plant,
    ) |values| if (values.len != plant_count)
        return error.InvalidRootSoilElementStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        for (0..element_count) |element|
            _ = try totalFor(state, inputs, cell, element);
    }

    inline for (state.change_g_element_per_h_by_element_and_cell) |values|
        @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..element_count) |element|
            state.change_g_element_per_h_by_element_and_cell[element][cell] =
                totalFor(state, inputs, cell, element) catch unreachable;
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    element: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const exchange =
            inputs.exchange_g_element_per_h_by_element_and_plant[element][plant];
        if (!std.math.isFinite(exchange))
            return error.NonFiniteRootSoilElementStateUpdateInput;
        total -= exchange;
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootSoilElementStateUpdate;
    return total;
}

test "root soil element state_update preserves subtraction and runtime species" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    try refresh(&state, .{
        .active_by_plant = &.{ true, false, true, true, true, false },
        .exchange_g_element_per_h_by_element_and_plant = .{
            &.{ 10, 999, -2, 3, 4, 999 },
            &.{ 1, 999, -0.2, 0.3, 0.4, 999 },
            &.{ 0.1, 999, -0.02, 0.03, 0.04, 999 },
        },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ -8, -7 },
        state.change_g_element_per_h_by_element_and_cell[0],
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ -0.8, -0.7 },
        state.change_g_element_per_h_by_element_and_cell[1],
    );
}

test "late invalid root soil element preserves every published array" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    for (
        state.change_g_element_per_h_by_element_and_cell,
        0..,
    ) |values, element| @memset(
        values,
        @as(f64, @floatFromInt(element + 1)),
    );
    try std.testing.expectError(
        error.NonFiniteRootSoilElementStateUpdateInput,
        refresh(&state, .{
            .active_by_plant = &.{ true, true },
            .exchange_g_element_per_h_by_element_and_plant = .{
                &.{ 1, 1 },
                &.{ 1, 1 },
                &.{ 1, std.math.nan(f64) },
            },
        }),
    );
    for (
        state.change_g_element_per_h_by_element_and_cell,
        0..,
    ) |values, element| for (values) |value|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(element + 1)),
            value,
        );
}
