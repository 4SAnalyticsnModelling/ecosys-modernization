const std = @import("std");

pub const gas_count: usize = 5;

/// Bound EXTRACT order: CO2-C, O2-O, CH4-C, N2O-N, H2-H.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    exchange_g_per_h_by_gas_and_layer: [gas_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootSoilGasStateUpdateDimensions;
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
            .exchange_g_per_h_by_gas_and_layer = slices,
        };
    }

    pub fn deinit(self: *State) void {
        const layer_count = self.cell_count * self.soil_layer_capacity;
        self.allocator.free(
            self.exchange_g_per_h_by_gas_and_layer[0]
                .ptr[0 .. gas_count * layer_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    soil_to_root_exchange_g_per_h_by_root_and_transport_gas: []const f64,
    oxygen_uptake_from_soil_g_o_per_h_by_root: []const f64,
};

const transported_root_gas_count: usize = 6;
// Root transport slots are CO2, CH4, N2O, NH3, H2, O2. O2 state_update reads
// its accepted metabolic uptake owner instead of an exchange slot.
const transport_slot_by_output_gas =
    [gas_count]?usize{ 0, null, 1, 2, 4 };

/// Exact EXTRACT lines 792–795 and 798. All five totals use source addition
/// and retain gas-specific elemental units. Lines 796–797 are handled by
/// root_soil_ammonia_exchange_state_update using separate per-root band arrays.
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
        inputs.oxygen_uptake_from_soil_g_o_per_h_by_root.len != root_count or
        inputs.soil_to_root_exchange_g_per_h_by_root_and_transport_gas.len !=
            try std.math.mul(usize, root_count, transported_root_gas_count))
        return error.InvalidRootSoilGasStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootSoilGasStateUpdateDimensions;
        for (0..active_layers) |layer| {
            for (0..gas_count) |gas|
                _ = try totalFor(state, inputs, cell, layer, gas);
        }
    }

    inline for (state.exchange_g_per_h_by_gas_and_layer) |values|
        @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            for (0..gas_count) |gas|
                state.exchange_g_per_h_by_gas_and_layer[gas][output] =
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
            return error.InvalidRootSoilGasStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const exchange = if (transport_slot_by_output_gas[gas]) |slot|
                inputs.soil_to_root_exchange_g_per_h_by_root_and_transport_gas[
                    root * transported_root_gas_count + slot
                ]
            else
                inputs.oxygen_uptake_from_soil_g_o_per_h_by_root[root];
            if (!std.math.isFinite(exchange))
                return error.NonFiniteRootSoilGasStateUpdateInput;
            if (gas == 1 and exchange < 0)
                return error.InvalidRootSoilGasStateUpdateInput;
            total += exchange;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootSoilGasStateUpdate;
    return total;
}

test "root soil gas state_update preserves owner mapping signs and order" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const exchange = [_]f64{
        1,   2,   3,   99,  5,   99,
        10,  20,  30,  99,  50,  99,
        -1,  -2,  -3,  99,  -5,  99,
        999, 999, 999, 999, 999, 999,
    };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .soil_to_root_exchange_g_per_h_by_root_and_transport_gas = &exchange,
        .oxygen_uptake_from_soil_g_o_per_h_by_root = &.{ 4, 40, 4, 999 },
    });
    const expected = [_]f64{ 10, 48, 20, 30, 50 };
    for (state.exchange_g_per_h_by_gas_and_layer, expected) |values, value|
        try std.testing.expectEqual(value, values[0]);
}

test "late invalid soil gas preserves all published arrays" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    for (state.exchange_g_per_h_by_gas_and_layer, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 1)));
    try std.testing.expectError(
        error.NonFiniteRootSoilGasStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .soil_to_root_exchange_g_per_h_by_root_and_transport_gas = &.{ 1, 1, 1, 1, std.math.nan(f64), 1 },
            .oxygen_uptake_from_soil_g_o_per_h_by_root = &.{1},
        }),
    );
    for (state.exchange_g_per_h_by_gas_and_layer, 0..) |values, gas|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 1)),
            values[0],
        );
}
