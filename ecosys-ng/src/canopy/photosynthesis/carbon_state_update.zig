const std = @import("std");

/// Runtime EXTRACT `TCCAN`, `XCNET`, and `XONET` owners by cell.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    hourly_net_fixation_g_c_per_h_by_cell: []f64,
    canopy_carbon_exchange_g_c_per_h_by_cell: []f64,
    canopy_oxygen_exchange_g_o_per_h_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0)
            return error.InvalidCanopyCarbonStateUpdateDimensions;
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, cell_count, 3),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .hourly_net_fixation_g_c_per_h_by_cell = values[0..cell_count],
            .canopy_carbon_exchange_g_c_per_h_by_cell = values[cell_count .. 2 * cell_count],
            .canopy_oxygen_exchange_g_o_per_h_by_cell = values[2 * cell_count .. 3 * cell_count],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.hourly_net_fixation_g_c_per_h_by_cell.ptr[0 .. 3 * self.cell_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_by_plant: []const bool,
    net_fixation_g_c_per_h_by_plant: []const f64,
    oxygen_g_o_per_g_c: f64,
};

/// Exact EXTRACT lines 939–943 under ecosys-ng whole-hour endpoint timing.
/// The accepted endpoint supplies both legacy HCNET and CNET state_updates.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    if (inputs.active_by_plant.len != plant_count or
        inputs.net_fixation_g_c_per_h_by_plant.len != plant_count)
        return error.InvalidCanopyCarbonStateUpdateDimensions;
    if (!std.math.isFinite(inputs.oxygen_g_o_per_g_c) or
        inputs.oxygen_g_o_per_g_c <= 0)
        return error.InvalidCanopyCarbonStateUpdateInput;

    for (0..state.cell_count) |cell|
        _ = try totalForCell(state, inputs, cell);

    @memset(state.hourly_net_fixation_g_c_per_h_by_cell, 0);
    @memset(state.canopy_carbon_exchange_g_c_per_h_by_cell, 0);
    @memset(state.canopy_oxygen_exchange_g_o_per_h_by_cell, 0);
    for (0..state.cell_count) |cell| {
        const carbon = totalForCell(state, inputs, cell) catch unreachable;
        const oxygen = -carbon * inputs.oxygen_g_o_per_g_c;
        state.hourly_net_fixation_g_c_per_h_by_cell[cell] = carbon;
        state.canopy_carbon_exchange_g_c_per_h_by_cell[cell] = carbon;
        state.canopy_oxygen_exchange_g_o_per_h_by_cell[cell] = oxygen;
    }
}

fn totalForCell(state: *const State, inputs: Inputs, cell: usize) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const fixation = inputs.net_fixation_g_c_per_h_by_plant[plant];
        if (!std.math.isFinite(fixation))
            return error.NonFiniteCanopyCarbonStateUpdateInput;
        total += fixation;
    }
    if (!std.math.isFinite(total) or
        !std.math.isFinite(-total * inputs.oxygen_g_o_per_g_c))
        return error.NonFiniteCanopyCarbonStateUpdate;
    return total;
}

test "canopy carbon state_update preserves runtime species and oxygen sign" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    try refresh(&state, .{
        .active_by_plant = &.{ true, false, true, true, true, false },
        .net_fixation_g_c_per_h_by_plant = &.{ 10, 999, -2, 3, 4, 999 },
        .oxygen_g_o_per_g_c = 2.667,
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 8, 7 },
        state.hourly_net_fixation_g_c_per_h_by_cell,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 8, 7 },
        state.canopy_carbon_exchange_g_c_per_h_by_cell,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -8 * 2.667),
        state.canopy_oxygen_exchange_g_o_per_h_by_cell[0],
        1e-15,
    );
}

test "late invalid canopy carbon preserves all published arrays" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    @memset(state.hourly_net_fixation_g_c_per_h_by_cell, 1);
    @memset(state.canopy_carbon_exchange_g_c_per_h_by_cell, 2);
    @memset(state.canopy_oxygen_exchange_g_o_per_h_by_cell, 3);
    try std.testing.expectError(
        error.NonFiniteCanopyCarbonStateUpdateInput,
        refresh(&state, .{
            .active_by_plant = &.{ true, true },
            .net_fixation_g_c_per_h_by_plant = &.{ 1, std.math.nan(f64) },
            .oxygen_g_o_per_g_c = 2.667,
        }),
    );
    for (state.hourly_net_fixation_g_c_per_h_by_cell) |value|
        try std.testing.expectEqual(@as(f64, 1), value);
    for (state.canopy_carbon_exchange_g_c_per_h_by_cell) |value|
        try std.testing.expectEqual(@as(f64, 2), value);
    for (state.canopy_oxygen_exchange_g_o_per_h_by_cell) |value|
        try std.testing.expectEqual(@as(f64, 3), value);
}
