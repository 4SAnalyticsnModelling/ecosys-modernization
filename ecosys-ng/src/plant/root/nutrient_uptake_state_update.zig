const std = @import("std");

pub const nutrient_count: usize = 8;

/// EXTRACT order: non-band NH4-N, NO3-N, H2PO4-P, HPO4-P, followed by
/// the same four band pools. Values are accepted uptake in g element h-1.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    uptake_g_element_per_h_by_nutrient_and_layer: [nutrient_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootNutrientStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, nutrient_count, layer_count),
        );
        @memset(values, 0);
        var slices: [nutrient_count][]f64 = undefined;
        for (&slices, 0..) |*slice, nutrient| {
            const first = nutrient * layer_count;
            slice.* = values[first .. first + layer_count];
        }
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .uptake_g_element_per_h_by_nutrient_and_layer = slices,
        };
    }

    pub fn deinit(self: *State) void {
        const layer_count = self.cell_count * self.soil_layer_capacity;
        self.allocator.free(
            self.uptake_g_element_per_h_by_nutrient_and_layer[0]
                .ptr[0 .. nutrient_count * layer_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    uptake_g_element_per_h_by_nutrient_and_root: [nutrient_count][]const f64,
};

/// Exact EXTRACT lines 799–806. Every destination is preflighted before the
/// eight-array state_update, preserving source order and positive uptake sign.
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
        return error.InvalidRootNutrientStateUpdateDimensions;
    inline for (inputs.uptake_g_element_per_h_by_nutrient_and_root) |values|
        if (values.len != root_count)
            return error.InvalidRootNutrientStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootNutrientStateUpdateDimensions;
        for (0..active_layers) |layer| {
            for (0..nutrient_count) |nutrient|
                _ = try totalFor(state, inputs, cell, layer, nutrient);
        }
    }

    inline for (state.uptake_g_element_per_h_by_nutrient_and_layer) |values|
        @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            for (0..nutrient_count) |nutrient|
                state.uptake_g_element_per_h_by_nutrient_and_layer[nutrient][output] =
                    totalFor(state, inputs, cell, layer, nutrient) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    nutrient: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootNutrientStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const uptake =
                inputs.uptake_g_element_per_h_by_nutrient_and_root[nutrient][root];
            if (!std.math.isFinite(uptake))
                return error.NonFiniteRootNutrientStateUpdateInput;
            if (uptake < 0)
                return error.InvalidRootNutrientStateUpdateInput;
            total += uptake;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootNutrientStateUpdate;
    return total;
}

test "root nutrient state_update preserves EXTRACT pool order and runtime axes" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const pool0 = [_]f64{ 1, 10, -99, 999 };
    const pool1 = [_]f64{ 2, 20, -99, 999 };
    const pool2 = [_]f64{ 3, 30, -99, 999 };
    const pool3 = [_]f64{ 4, 40, -99, 999 };
    const pool4 = [_]f64{ 5, 50, -99, 999 };
    const pool5 = [_]f64{ 6, 60, -99, 999 };
    const pool6 = [_]f64{ 7, 70, -99, 999 };
    const pool7 = [_]f64{ 8, 80, -99, 999 };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, false },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .uptake_g_element_per_h_by_nutrient_and_root = .{
            &pool0, &pool1, &pool2, &pool3, &pool4, &pool5, &pool6, &pool7,
        },
    });
    const expected = [_]f64{ 11, 22, 33, 44, 55, 66, 77, 88 };
    for (
        state.uptake_g_element_per_h_by_nutrient_and_layer,
        expected,
    ) |values, value| try std.testing.expectEqual(value, values[0]);
}

test "late invalid root nutrient preserves all published arrays" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    for (
        state.uptake_g_element_per_h_by_nutrient_and_layer,
        0..,
    ) |values, nutrient| @memset(
        values,
        @as(f64, @floatFromInt(nutrient + 1)),
    );
    const one = [_]f64{1};
    const invalid = [_]f64{std.math.nan(f64)};
    try std.testing.expectError(
        error.NonFiniteRootNutrientStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .uptake_g_element_per_h_by_nutrient_and_root = .{
                &one, &one, &one, &one, &one, &one, &one, &invalid,
            },
        }),
    );
    for (
        state.uptake_g_element_per_h_by_nutrient_and_layer,
        0..,
    ) |values, nutrient| try std.testing.expectEqual(
        @as(f64, @floatFromInt(nutrient + 1)),
        values[0],
    );
}
