const std = @import("std");

/// Runtime EXTRACT `TCO2P/TUPOXP` cell-layer state_update.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    carbon_dioxide_source_g_c_per_h_by_layer: []f64,
    oxygen_uptake_g_o_per_h_by_layer: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootInternalGasStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const carbon_dioxide = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(carbon_dioxide);
        const oxygen = try allocator.alloc(f64, layer_count);
        @memset(carbon_dioxide, 0);
        @memset(oxygen, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .carbon_dioxide_source_g_c_per_h_by_layer = carbon_dioxide,
            .oxygen_uptake_g_o_per_h_by_layer = oxygen,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.oxygen_uptake_g_o_per_h_by_layer);
        self.allocator.free(self.carbon_dioxide_source_g_c_per_h_by_layer);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    aqueous_carbon_dioxide_reaction_g_c_per_h_by_root: []const f64,
    oxygen_uptake_from_root_pool_g_o_per_h_by_root: []const f64,
};

const Totals = struct {
    carbon_dioxide_source_g_c_per_h: f64 = 0,
    oxygen_uptake_g_o_per_h: f64 = 0,
};

/// Exact EXTRACT lines 790–791. `TCO2P -= RCO2P` preserves the explicit
/// negative source sign; `TUPOXP += RUPOXP` preserves positive oxygen uptake.
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
        inputs.aqueous_carbon_dioxide_reaction_g_c_per_h_by_root.len !=
            root_count or
        inputs.oxygen_uptake_from_root_pool_g_o_per_h_by_root.len != root_count)
        return error.InvalidRootInternalGasStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootInternalGasStateUpdateDimensions;
        for (0..active_layers) |layer|
            _ = try totalsFor(state, inputs, cell, layer);
    }

    @memset(state.carbon_dioxide_source_g_c_per_h_by_layer, 0);
    @memset(state.oxygen_uptake_g_o_per_h_by_layer, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            const totals = totalsFor(state, inputs, cell, layer) catch unreachable;
            state.carbon_dioxide_source_g_c_per_h_by_layer[output] =
                totals.carbon_dioxide_source_g_c_per_h;
            state.oxygen_uptake_g_o_per_h_by_layer[output] =
                totals.oxygen_uptake_g_o_per_h;
        }
    }
}

fn totalsFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
) !Totals {
    var result: Totals = .{};
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootInternalGasStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const carbon_dioxide =
                inputs.aqueous_carbon_dioxide_reaction_g_c_per_h_by_root[root];
            const oxygen =
                inputs.oxygen_uptake_from_root_pool_g_o_per_h_by_root[root];
            if (!std.math.isFinite(carbon_dioxide) or carbon_dioxide < 0 or
                !std.math.isFinite(oxygen) or oxygen < 0)
                return error.InvalidRootInternalGasStateUpdateInput;
            result.carbon_dioxide_source_g_c_per_h -= carbon_dioxide;
            result.oxygen_uptake_g_o_per_h += oxygen;
        }
    }
    if (!std.math.isFinite(result.carbon_dioxide_source_g_c_per_h) or
        !std.math.isFinite(result.oxygen_uptake_g_o_per_h))
        return error.NonFiniteRootInternalGasStateUpdate;
    return result;
}

test "root internal gas state_update preserves asymmetric source signs" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .aqueous_carbon_dioxide_reaction_g_c_per_h_by_root = &.{ 1, 2, 3, 99 },
        .oxygen_uptake_from_root_pool_g_o_per_h_by_root = &.{ 0.1, 0.2, 0.3, 99 },
    });
    try std.testing.expectEqual(
        @as(f64, -6),
        state.carbon_dioxide_source_g_c_per_h_by_layer[0],
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6),
        state.oxygen_uptake_g_o_per_h_by_layer[0],
        1e-15,
    );
}

test "late invalid internal gas preserves complete state_update" {
    var state = try State.init(std.testing.allocator, 1, 1, 2, 1);
    defer state.deinit();
    @memset(state.carbon_dioxide_source_g_c_per_h_by_layer, 7);
    @memset(state.oxygen_uptake_g_o_per_h_by_layer, 8);
    try std.testing.expectError(
        error.InvalidRootInternalGasStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{2},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .aqueous_carbon_dioxide_reaction_g_c_per_h_by_root = &.{ 1, 2 },
            .oxygen_uptake_from_root_pool_g_o_per_h_by_root = &.{ 1, std.math.nan(f64) },
        }),
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 7, 7 },
        state.carbon_dioxide_source_g_c_per_h_by_layer,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 8, 8 },
        state.oxygen_uptake_g_o_per_h_by_layer,
    );
}
