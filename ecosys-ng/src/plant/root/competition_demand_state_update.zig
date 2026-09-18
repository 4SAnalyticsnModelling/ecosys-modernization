const std = @import("std");

pub const demand_count: usize = 9;

/// EXTRACT order: O2-O, non-band NH4-N, NO3-N, H2PO4-P, HPO4-P,
/// then the four corresponding band nutrient demands.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    demand_g_element_per_h_by_kind_and_layer: [demand_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootCompetitionStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, demand_count, layer_count),
        );
        @memset(values, 0);
        var slices: [demand_count][]f64 = undefined;
        for (&slices, 0..) |*slice, demand| {
            const first = demand * layer_count;
            slice.* = values[first .. first + layer_count];
        }
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .demand_g_element_per_h_by_kind_and_layer = slices,
        };
    }

    pub fn deinit(self: *State) void {
        const layer_count = self.cell_count * self.soil_layer_capacity;
        self.allocator.free(
            self.demand_g_element_per_h_by_kind_and_layer[0]
                .ptr[0 .. demand_count * layer_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    demand_g_element_per_h_by_kind_and_root: [demand_count][]const f64,
};

/// Exact EXTRACT lines 899–907. All nine positive demand additions are
/// preflighted and then published in one transaction.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    const root_count = try std.math.mul(
        usize,
        try std.math.mul(usize, plant_count, state.root_domain_capacity),
        state.soil_layer_capacity,
    );
    if (inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.active_by_plant.len != plant_count or
        inputs.root_domain_count_by_plant.len != plant_count)
        return error.InvalidRootCompetitionStateUpdateDimensions;
    inline for (inputs.demand_g_element_per_h_by_kind_and_root) |values|
        if (values.len != root_count)
            return error.InvalidRootCompetitionStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootCompetitionStateUpdateDimensions;
        for (0..active_layers) |layer| {
            for (0..demand_count) |demand|
                _ = try totalFor(state, inputs, cell, layer, demand);
        }
    }

    inline for (state.demand_g_element_per_h_by_kind_and_layer) |values|
        @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            for (0..demand_count) |demand|
                state.demand_g_element_per_h_by_kind_and_layer[demand][output] =
                    totalFor(state, inputs, cell, layer, demand) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    demand: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootCompetitionStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const value =
                inputs.demand_g_element_per_h_by_kind_and_root[demand][root];
            if (!std.math.isFinite(value))
                return error.NonFiniteRootCompetitionStateUpdateInput;
            if (value < 0)
                return error.InvalidRootCompetitionStateUpdateInput;
            total += value;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootCompetitionStateUpdate;
    return total;
}

test "root competition state_update preserves demand order and runtime axes" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const demand0 = [_]f64{ 1, 10, 999, 999 };
    const demand1 = [_]f64{ 2, 20, 999, 999 };
    const demand2 = [_]f64{ 3, 30, 999, 999 };
    const demand3 = [_]f64{ 4, 40, 999, 999 };
    const demand4 = [_]f64{ 5, 50, 999, 999 };
    const demand5 = [_]f64{ 6, 60, 999, 999 };
    const demand6 = [_]f64{ 7, 70, 999, 999 };
    const demand7 = [_]f64{ 8, 80, 999, 999 };
    const demand8 = [_]f64{ 9, 90, 999, 999 };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, false },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .demand_g_element_per_h_by_kind_and_root = .{
            &demand0, &demand1, &demand2, &demand3, &demand4,
            &demand5, &demand6, &demand7, &demand8,
        },
    });
    const expected = [_]f64{ 11, 22, 33, 44, 55, 66, 77, 88, 99 };
    for (
        state.demand_g_element_per_h_by_kind_and_layer,
        expected,
    ) |values, value| try std.testing.expectEqual(value, values[0]);
}

test "late invalid competition demand preserves every published array" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    for (
        state.demand_g_element_per_h_by_kind_and_layer,
        0..,
    ) |values, demand| @memset(
        values,
        @as(f64, @floatFromInt(demand + 1)),
    );
    const one = [_]f64{1};
    const invalid = [_]f64{std.math.nan(f64)};
    try std.testing.expectError(
        error.NonFiniteRootCompetitionStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .demand_g_element_per_h_by_kind_and_root = .{
                &one, &one, &one, &one, &one, &one, &one, &one, &invalid,
            },
        }),
    );
    for (
        state.demand_g_element_per_h_by_kind_and_layer,
        0..,
    ) |values, demand| try std.testing.expectEqual(
        @as(f64, @floatFromInt(demand + 1)),
        values[0],
    );
}
