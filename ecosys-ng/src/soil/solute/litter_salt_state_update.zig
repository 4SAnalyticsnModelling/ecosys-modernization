const std = @import("std");
const plant_salt = @import("../../plant/salt/harvest.zig");

pub const salt_count = plant_salt.salt_count;

/// Current-hour EXTRACT `ALSNT..CLSNT` owners. Exchange layer zero is
/// surface litter; positive exchange layer `L` maps to soil layer `L - 1`.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    soil_layer_capacity: usize,
    mol_by_cell_exchange_layer_salt: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
        soil_layer_capacity: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0 or
            soil_layer_capacity == 0)
            return error.InvalidLitterSaltStateUpdateDimensions;
        const exchange_layers = try std.math.add(usize, soil_layer_capacity, 1);
        const cell_layers = try std.math.mul(usize, cell_count, exchange_layers);
        const value_count = try std.math.mul(usize, cell_layers, salt_count);
        const values = try allocator.alloc(f64, value_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .soil_layer_capacity = soil_layer_capacity,
            .mol_by_cell_exchange_layer_salt = values,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.mol_by_cell_exchange_layer_salt);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    active_soil_layer_count_by_cell: []const usize,
    mol_by_plant_exchange_layer_salt: []const f64,
};

/// Exact EXTRACT lines 79–98. Plant contributions are added in configured
/// species order for Al, Fe, Ca, Mg, Na, K, SO4, and Cl.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const exchange_layers = state.soil_layer_capacity + 1;
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    const expected = try std.math.mul(
        usize,
        try std.math.mul(usize, plant_count, exchange_layers),
        salt_count,
    );
    if (inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.mol_by_plant_exchange_layer_salt.len != expected)
        return error.InvalidLitterSaltStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        const active_layers = inputs.active_soil_layer_count_by_cell[cell];
        if (active_layers == 0 or active_layers > state.soil_layer_capacity)
            return error.InvalidLitterSaltStateUpdateDimensions;
        for (0..exchange_layers) |exchange_layer| {
            for (0..salt_count) |salt| {
                _ = try totalFor(state, inputs, cell, exchange_layer, salt);
            }
        }
    }

    for (0..state.cell_count) |cell| {
        for (0..exchange_layers) |exchange_layer| {
            for (0..salt_count) |salt| {
                const target =
                    (cell * exchange_layers + exchange_layer) * salt_count + salt;
                state.mol_by_cell_exchange_layer_salt[target] =
                    totalFor(state, inputs, cell, exchange_layer, salt) catch
                        unreachable;
            }
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    exchange_layer: usize,
    salt: usize,
) !f64 {
    const exchange_layers = state.soil_layer_capacity + 1;
    const active = exchange_layer == 0 or
        exchange_layer <= inputs.active_soil_layer_count_by_cell[cell];
    var total_mol: f64 = 0;
    const first_plant = cell * state.plant_species_per_cell;
    for (first_plant..first_plant + state.plant_species_per_cell) |plant| {
        const source =
            (plant * exchange_layers + exchange_layer) * salt_count + salt;
        const amount_mol = inputs.mol_by_plant_exchange_layer_salt[source];
        if (!std.math.isFinite(amount_mol) or amount_mol < 0)
            return error.InvalidLitterSaltStateUpdateInput;
        if (!active and amount_mol != 0)
            return error.LitterSaltTargetsInactiveSoilLayer;
        total_mol += amount_mol;
        if (!std.math.isFinite(total_mol))
            return error.NonFiniteLitterSaltStateUpdate;
    }
    return total_mol;
}

test "EXTRACT litter salts retain runtime plant layer and salt order" {
    var state = try State.init(std.testing.allocator, 2, 2, 2);
    defer state.deinit();
    const exchange_layers: usize = 3;
    var source = [_]f64{0} ** (4 * exchange_layers * salt_count);
    for (0..4) |plant|
        for (0..exchange_layers) |layer|
            for (0..salt_count) |salt| {
                const index = (plant * exchange_layers + layer) * salt_count + salt;
                source[index] = @floatFromInt(100 * plant + 10 * layer + salt);
            };
    try refresh(&state, .{
        .active_soil_layer_count_by_cell = &.{ 2, 2 },
        .mol_by_plant_exchange_layer_salt = &source,
    });
    try std.testing.expectEqual(
        @as(f64, 1 + 101),
        state.mol_by_cell_exchange_layer_salt[1],
    );
    const second_cell_layer_two_chloride =
        (1 * exchange_layers + 2) * salt_count + 7;
    try std.testing.expectEqual(
        @as(f64, 227 + 327),
        state.mol_by_cell_exchange_layer_salt[
            second_cell_layer_two_chloride
        ],
    );
}

test "late invalid litter salt preserves complete state_update" {
    var state = try State.init(std.testing.allocator, 2, 2, 1);
    defer state.deinit();
    @memset(state.mol_by_cell_exchange_layer_salt, 9);
    var source = [_]f64{1} ** (4 * 2 * salt_count);
    source[source.len - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidLitterSaltStateUpdateInput,
        refresh(&state, .{
            .active_soil_layer_count_by_cell = &.{ 1, 1 },
            .mol_by_plant_exchange_layer_salt = &source,
        }),
    );
    for (state.mol_by_cell_exchange_layer_salt) |value|
        try std.testing.expectEqual(@as(f64, 9), value);
}
