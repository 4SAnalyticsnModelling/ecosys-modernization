const std = @import("std");

pub const gas_count: usize = 6;

/// EXTRACT order: CO2-C, O2-O, CH4-C, N2O-N, NH3-N, H2-H.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    loss_g_element_per_h_by_gas_and_cell: [gas_count][]f64,
    loss_g_element_per_h_by_gas_and_layer: [gas_count][]f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootGasWithdrawalStateUpdateDimensions;
        const layer_count = try std.math.mul(usize, cell_count, soil_layer_capacity);
        const stride = try std.math.add(usize, cell_count, layer_count);
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, gas_count, stride),
        );
        @memset(values, 0);
        var cells: [gas_count][]f64 = undefined;
        var layers: [gas_count][]f64 = undefined;
        for (0..gas_count) |gas| {
            const first = gas * stride;
            cells[gas] = values[first .. first + cell_count];
            layers[gas] = values[first + cell_count .. first + stride];
        }
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .loss_g_element_per_h_by_gas_and_cell = cells,
            .loss_g_element_per_h_by_gas_and_layer = layers,
        };
    }

    pub fn deinit(self: *State) void {
        const stride = self.cell_count + self.cell_count * self.soil_layer_capacity;
        self.allocator.free(self.loss_g_element_per_h_by_gas_and_cell[0].ptr[0 .. gas_count * stride]);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    loss_g_element_per_h_by_gas_and_plant: [gas_count][]const f64,
    loss_g_element_per_h_by_gas_and_root: [gas_count][]const f64,
};

/// Exact EXTRACT lines 952–957. Source-signed withdrawal ledgers from every
/// configured plant species are preflighted and published atomically.
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
    inline for (inputs.loss_g_element_per_h_by_gas_and_plant) |values|
        if (values.len != plant_count)
            return error.InvalidRootGasWithdrawalStateUpdateDimensions;
    inline for (inputs.loss_g_element_per_h_by_gas_and_root) |values|
        if (values.len != root_count)
            return error.InvalidRootGasWithdrawalStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        for (0..gas_count) |gas| {
            const cell_total = try totalFor(state, inputs, cell, gas);
            var layer_total: f64 = 0;
            var absolute_sum: f64 = 0;
            for (0..state.soil_layer_capacity) |layer| {
                const local = try layerTotalFor(state, inputs, cell, layer, gas);
                layer_total += local;
                absolute_sum += @abs(local);
            }
            const scale = @max(1, @max(absolute_sum, @max(@abs(cell_total), @abs(layer_total))));
            const roundoff_bound = 64 * std.math.floatEps(f64) *
                @as(f64, @floatFromInt(state.species_count * state.root_domain_capacity * state.soil_layer_capacity + 1)) * scale;
            if (!std.math.isFinite(layer_total) or !std.math.isFinite(absolute_sum) or
                @abs(layer_total - cell_total) > roundoff_bound)
                return error.RootGasWithdrawalSpatialProvenanceMismatch;
        }
    }

    inline for (state.loss_g_element_per_h_by_gas_and_cell) |values|
        @memset(values, 0);
    inline for (state.loss_g_element_per_h_by_gas_and_layer) |values|
        @memset(values, 0);
    for (0..state.cell_count) |cell| {
        for (0..gas_count) |gas|
            state.loss_g_element_per_h_by_gas_and_cell[gas][cell] =
                totalFor(state, inputs, cell, gas) catch unreachable;
        for (0..state.soil_layer_capacity) |layer| {
            const output = cell * state.soil_layer_capacity + layer;
            for (0..gas_count) |gas|
                state.loss_g_element_per_h_by_gas_and_layer[gas][output] =
                    layerTotalFor(state, inputs, cell, layer, gas) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    gas: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        const loss = inputs.loss_g_element_per_h_by_gas_and_plant[gas][plant];
        if (!std.math.isFinite(loss) or loss > 0)
            return error.InvalidRootGasWithdrawalStateUpdateInput;
        total += loss;
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootGasWithdrawalStateUpdate;
    return total;
}

fn layerTotalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    gas: usize,
) !f64 {
    var total: f64 = 0;
    const first_plant = cell * state.species_count;
    for (first_plant..first_plant + state.species_count) |plant|
        for (0..state.root_domain_capacity) |domain| {
            const root = (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity + layer;
            const loss = inputs.loss_g_element_per_h_by_gas_and_root[gas][root];
            if (!std.math.isFinite(loss) or loss > 0)
                return error.InvalidRootGasWithdrawalStateUpdateInput;
            total += loss;
        };
    if (!std.math.isFinite(total))
        return error.NonFiniteRootGasWithdrawalStateUpdate;
    return total;
}

test "root gas withdrawal state_update preserves gas order and source signs" {
    var state = try State.init(std.testing.allocator, 2, 3, 1, 1);
    defer state.deinit();
    const gas0 = [_]f64{ -1, -2, -1, -3, -4, -2 };
    const gas1 = [_]f64{ -2, -4, -2, -6, -8, -4 };
    const gas2 = [_]f64{ -3, -6, -3, -9, -12, -6 };
    const gas3 = [_]f64{ -4, -8, -4, -12, -16, -8 };
    const gas4 = [_]f64{ -5, -10, -5, -15, -20, -10 };
    const gas5 = [_]f64{ -6, -12, -6, -18, -24, -12 };
    const gases: [gas_count][]const f64 = .{ &gas0, &gas1, &gas2, &gas3, &gas4, &gas5 };
    try refresh(&state, .{
        .loss_g_element_per_h_by_gas_and_plant = gases,
        .loss_g_element_per_h_by_gas_and_root = gases,
    });
    const expected_first = [_]f64{ -4, -8, -12, -16, -20, -24 };
    const expected_second = [_]f64{ -9, -18, -27, -36, -45, -54 };
    for (
        state.loss_g_element_per_h_by_gas_and_cell,
        expected_first,
        expected_second,
    ) |values, first, second| {
        try std.testing.expectEqual(first, values[0]);
        try std.testing.expectEqual(second, values[1]);
    }
    for (
        state.loss_g_element_per_h_by_gas_and_layer,
        expected_first,
        expected_second,
    ) |values, first, second| {
        try std.testing.expectEqual(first, values[0]);
        try std.testing.expectEqual(second, values[1]);
    }
}

test "late invalid root gas withdrawal preserves every published array" {
    var state = try State.init(std.testing.allocator, 2, 1, 1, 1);
    defer state.deinit();
    for (state.loss_g_element_per_h_by_gas_and_cell, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 1)));
    for (state.loss_g_element_per_h_by_gas_and_layer, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 7)));
    const valid = [_]f64{ -1, -1 };
    const invalid = [_]f64{ -1, std.math.nan(f64) };
    try std.testing.expectError(
        error.InvalidRootGasWithdrawalStateUpdateInput,
        refresh(&state, .{
            .loss_g_element_per_h_by_gas_and_plant = .{
                &valid, &valid, &valid, &valid, &valid, &invalid,
            },
            .loss_g_element_per_h_by_gas_and_root = .{
                &valid, &valid, &valid, &valid, &valid, &invalid,
            },
        }),
    );
    for (
        state.loss_g_element_per_h_by_gas_and_cell,
        0..,
    ) |values, gas| for (values) |value|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 1)),
            value,
        );
    for (
        state.loss_g_element_per_h_by_gas_and_layer,
        0..,
    ) |values, gas| for (values) |value|
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 7)),
            value,
        );
}

test "root gas withdrawal rejects spatial provenance mismatch atomically" {
    var state = try State.init(std.testing.allocator, 1, 1, 2, 1);
    defer state.deinit();
    for (state.loss_g_element_per_h_by_gas_and_cell, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 1)));
    for (state.loss_g_element_per_h_by_gas_and_layer, 0..) |values, gas|
        @memset(values, @as(f64, @floatFromInt(gas + 7)));

    const aggregate = [_]f64{-1};
    const matching_roots = [_]f64{ -0.5, -0.5 };
    const mismatched_roots = [_]f64{ -0.5, -0.25 };
    try std.testing.expectError(
        error.RootGasWithdrawalSpatialProvenanceMismatch,
        refresh(&state, .{
            .loss_g_element_per_h_by_gas_and_plant = .{
                &aggregate, &aggregate, &aggregate, &aggregate, &aggregate, &aggregate,
            },
            .loss_g_element_per_h_by_gas_and_root = .{
                &matching_roots,
                &matching_roots,
                &matching_roots,
                &matching_roots,
                &matching_roots,
                &mismatched_roots,
            },
        }),
    );
    for (state.loss_g_element_per_h_by_gas_and_cell, 0..) |values, gas|
        for (values) |value| try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 1)),
            value,
        );
    for (state.loss_g_element_per_h_by_gas_and_layer, 0..) |values, gas|
        for (values) |value| try std.testing.expectEqual(
            @as(f64, @floatFromInt(gas + 7)),
            value,
        );
}
