const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    non_band_exchange_g_n_per_h_by_layer: []f64,
    band_exchange_g_n_per_h_by_layer: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootSoilAmmoniaStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, 2, layer_count),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .non_band_exchange_g_n_per_h_by_layer = values[0..layer_count],
            .band_exchange_g_n_per_h_by_layer = values[layer_count .. 2 * layer_count],
        };
    }

    pub fn deinit(self: *State) void {
        const layer_count = self.non_band_exchange_g_n_per_h_by_layer.len;
        self.allocator.free(
            self.non_band_exchange_g_n_per_h_by_layer
                .ptr[0 .. 2 * layer_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    non_band_exchange_g_n_per_h_by_root: []const f64, // RUPN3S
    band_exchange_g_n_per_h_by_root: []const f64, // RUPN3B
};

/// Exact EXTRACT lines 796--797. Publishes separate non-band and band NH3-N
/// root-soil exchanges in source order with runtime plant/domain/layer axes.
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
        inputs.non_band_exchange_g_n_per_h_by_root.len != root_count or
        inputs.band_exchange_g_n_per_h_by_root.len != root_count)
        return error.InvalidRootSoilAmmoniaStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootSoilAmmoniaStateUpdateDimensions;
        for (0..active_layers) |layer| {
            _ = try totalFor(state, inputs, cell, layer, .non_band);
            _ = try totalFor(state, inputs, cell, layer, .band);
        }
    }

    @memset(state.non_band_exchange_g_n_per_h_by_layer, 0);
    @memset(state.band_exchange_g_n_per_h_by_layer, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            state.non_band_exchange_g_n_per_h_by_layer[output] =
                totalFor(state, inputs, cell, layer, .non_band) catch unreachable;
            state.band_exchange_g_n_per_h_by_layer[output] =
                totalFor(state, inputs, cell, layer, .band) catch unreachable;
        }
    }
}

const Pool = enum { non_band, band };

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    pool: Pool,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootSoilAmmoniaStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const exchange = switch (pool) {
                .non_band => inputs.non_band_exchange_g_n_per_h_by_root[root],
                .band => inputs.band_exchange_g_n_per_h_by_root[root],
            };
            if (!std.math.isFinite(exchange))
                return error.NonFiniteRootSoilAmmoniaStateUpdateInput;
            total += exchange;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootSoilAmmoniaStateUpdate;
    return total;
}

test "root-soil ammonia state_update preserves separate non-band and band totals" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .non_band_exchange_g_n_per_h_by_root = &.{ 1, 10, -1, 999 },
        .band_exchange_g_n_per_h_by_root = &.{ 2, 20, -2, 999 },
    });
    try std.testing.expectEqual(@as(f64, 10), state.non_band_exchange_g_n_per_h_by_layer[0]);
    try std.testing.expectEqual(@as(f64, 20), state.band_exchange_g_n_per_h_by_layer[0]);
}

test "late invalid exchange preserves both published arrays" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    @memset(state.non_band_exchange_g_n_per_h_by_layer, 7);
    @memset(state.band_exchange_g_n_per_h_by_layer, 8);
    try std.testing.expectError(
        error.NonFiniteRootSoilAmmoniaStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .non_band_exchange_g_n_per_h_by_root = &.{std.math.nan(f64)},
            .band_exchange_g_n_per_h_by_root = &.{1},
        }),
    );
    try std.testing.expectEqual(@as(f64, 7), state.non_band_exchange_g_n_per_h_by_layer[0]);
    try std.testing.expectEqual(@as(f64, 8), state.band_exchange_g_n_per_h_by_layer[0]);
}
