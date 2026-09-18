const std = @import("std");

/// Runtime EXTRACT `TUPNF` owner in g N h-1 by cell and soil layer.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    fixation_g_n_per_h_by_layer: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootFixationStateUpdateDimensions;
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, cell_count, soil_layer_capacity),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .fixation_g_n_per_h_by_layer = values,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.fixation_g_n_per_h_by_layer);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    fixation_g_n_per_h_by_root: []const f64,
};

/// Exact EXTRACT lines 915–917. ecosys-ng's accepted per-domain fixation
/// owners are summed to reconstruct the legacy plant-layer `RUPNF` total.
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
        inputs.root_domain_count_by_plant.len != plant_count or
        inputs.fixation_g_n_per_h_by_root.len != root_count)
        return error.InvalidRootFixationStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootFixationStateUpdateDimensions;
        for (0..active_layers) |layer|
            _ = try totalFor(state, inputs, cell, layer);
    }

    @memset(state.fixation_g_n_per_h_by_layer, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            state.fixation_g_n_per_h_by_layer[output] =
                totalFor(state, inputs, cell, layer) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootFixationStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const fixation = inputs.fixation_g_n_per_h_by_root[root];
            if (!std.math.isFinite(fixation))
                return error.NonFiniteRootFixationStateUpdateInput;
            if (fixation < 0)
                return error.InvalidRootFixationStateUpdateInput;
            total += fixation;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootFixationStateUpdate;
    return total;
}

test "root fixation state_update sums runtime species and biological domains" {
    var state = try State.init(std.testing.allocator, 1, 3, 1, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, true, false },
        .root_domain_count_by_plant = &.{ 2, 1, 2 },
        .fixation_g_n_per_h_by_root = &.{ 1, 10, 100, 999, 999, 999 },
    });
    try std.testing.expectEqual(
        @as(f64, 111),
        state.fixation_g_n_per_h_by_layer[0],
    );
}

test "late invalid root fixation preserves published layers" {
    var state = try State.init(std.testing.allocator, 1, 1, 2, 2);
    defer state.deinit();
    @memset(state.fixation_g_n_per_h_by_layer, 7);
    try std.testing.expectError(
        error.NonFiniteRootFixationStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{2},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{2},
            .fixation_g_n_per_h_by_root = &.{
                1, 1, 1, std.math.nan(f64),
            },
        }),
    );
    for (state.fixation_g_n_per_h_by_layer) |value|
        try std.testing.expectEqual(@as(f64, 7), value);
}
