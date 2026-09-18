const std = @import("std");

pub const gas_count: usize = 6;

/// EXTRACT gas order: CO2-C, O2-O, CH4-C, N2O-N, NH3-N, H2-H.
pub const Gas = enum(u3) {
    carbon_dioxide_carbon,
    oxygen_oxygen,
    methane_carbon,
    nitrous_oxide_nitrogen,
    ammonia_nitrogen,
    hydrogen_hydrogen,
};

/// Runtime `TLCO2P/TLOXYP/TLCH4P/TLN2OP/TLNH3P/TLH2GP` owner.
/// Each gas slice is cell-major then soil-layer-major, in g of its named
/// element.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    total_g_by_gas_and_layer: [gas_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootGasContentStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, gas_count, layer_count),
        );
        @memset(values, 0);
        var slices: [gas_count][]f64 = undefined;
        for (&slices, 0..) |*slice, gas| {
            const first = gas * layer_count;
            slice.* = values[first .. first + layer_count];
        }
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .total_g_by_gas_and_layer = slices,
        };
    }

    pub fn deinit(self: *State) void {
        const layer_count = self.cell_count * self.soil_layer_capacity;
        self.allocator.free(
            self.total_g_by_gas_and_layer[0].ptr[0 .. gas_count * layer_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    gaseous_g_by_gas: [gas_count][]const f64,
    aqueous_g_by_gas: [gas_count][]const f64,
};

/// Exact EXTRACT lines 739–758 state_update from already accepted root phase
/// inventories. Traversal is cell, species, domain, layer, then source gas
/// order. Every total is proven finite and nonnegative before mutation.
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
        return error.InvalidRootGasContentStateUpdateDimensions;
    inline for (.{
        inputs.gaseous_g_by_gas,
        inputs.aqueous_g_by_gas,
    }) |phases| inline for (phases) |values|
        if (values.len != root_count)
            return error.InvalidRootGasContentStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootGasContentStateUpdateDimensions;
        for (0..active_layers) |layer| {
            for (0..gas_count) |gas|
                _ = try totalFor(state, inputs, cell, layer, gas);
        }
    }

    inline for (state.total_g_by_gas_and_layer) |values| @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            for (0..gas_count) |gas|
                state.total_g_by_gas_and_layer[gas][output] =
                    totalFor(state, inputs, cell, layer, gas) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    gas: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootGasContentStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const gaseous = inputs.gaseous_g_by_gas[gas][root];
            const aqueous = inputs.aqueous_g_by_gas[gas][root];
            if (!std.math.isFinite(gaseous) or gaseous < 0 or
                !std.math.isFinite(aqueous) or aqueous < 0)
                return error.InvalidRootGasContentStateUpdateInput;
            total += gaseous + aqueous;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootGasContentStateUpdate;
    return total;
}

test "root gas content state_update conserves all phases and source gas order" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const gaseous = [_]f64{ 1, 2, 3, 99 };
    const aqueous = [_]f64{ 10, 20, 30, 99 };
    const gas_phases = [_][]const f64{
        &gaseous, &gaseous, &gaseous, &gaseous, &gaseous, &gaseous,
    };
    const aqueous_phases = [_][]const f64{
        &aqueous, &aqueous, &aqueous, &aqueous, &aqueous, &aqueous,
    };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .gaseous_g_by_gas = gas_phases,
        .aqueous_g_by_gas = aqueous_phases,
    });
    for (state.total_g_by_gas_and_layer) |values|
        try std.testing.expectEqual(@as(f64, 66), values[0]);
}

test "late invalid root gas preserves every published gas" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    for (state.total_g_by_gas_and_layer, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 1)));
    const valid = [_]f64{1};
    const invalid = [_]f64{std.math.nan(f64)};
    const gaseous = [_][]const f64{
        &valid, &valid, &valid, &valid, &valid, &invalid,
    };
    const aqueous = [_][]const f64{
        &valid, &valid, &valid, &valid, &valid, &valid,
    };
    try std.testing.expectError(
        error.InvalidRootGasContentStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .gaseous_g_by_gas = gaseous,
            .aqueous_g_by_gas = aqueous,
        }),
    );
    for (state.total_g_by_gas_and_layer, 0..) |values, gas|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 1)),
            values[0],
        );
}
