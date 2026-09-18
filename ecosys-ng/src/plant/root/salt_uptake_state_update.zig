const std = @import("std");

pub const salt_species_count: usize = 8;

/// EXTRACT order: Al, Fe, Ca, Mg, Na, K, SO4, and Cl.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    uptake_mol_per_h_by_layer_and_salt: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootSaltStateUpdateDimensions;
        const layer_count = try std.math.mul(
            usize,
            cell_count,
            soil_layer_capacity,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, layer_count, salt_species_count),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .uptake_mol_per_h_by_layer_and_salt = values,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.uptake_mol_per_h_by_layer_and_salt);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    salinity_enabled_by_cell: []const bool,
    active_soil_layer_count_by_cell: []const usize,
    active_by_plant: []const bool,
    root_domain_count_by_plant: []const u8,
    uptake_mol_per_h_by_root_and_salt: []const f64,
};

/// Exact EXTRACT lines 829–844. The `ISALTG != 0` gate and all eight
/// source-signed additions are preserved as one atomic state_update.
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
    if (inputs.salinity_enabled_by_cell.len != state.cell_count or
        inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.active_by_plant.len != plant_count or
        inputs.root_domain_count_by_plant.len != plant_count or
        inputs.uptake_mol_per_h_by_root_and_salt.len !=
            try std.math.mul(usize, root_count, salt_species_count))
        return error.InvalidRootSaltStateUpdateDimensions;
    for (inputs.active_soil_layer_count_by_cell) |active_layers|
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootSaltStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        if (!inputs.salinity_enabled_by_cell[cell]) continue;
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            for (0..salt_species_count) |salt|
                _ = try totalFor(state, inputs, cell, layer, salt);
        }
    }

    @memset(state.uptake_mol_per_h_by_layer_and_salt, 0);
    for (0..state.cell_count) |cell| {
        if (!inputs.salinity_enabled_by_cell[cell]) continue;
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output =
                (cell * state.soil_layer_capacity + layer) *
                salt_species_count;
            for (0..salt_species_count) |salt|
                state.uptake_mol_per_h_by_layer_and_salt[output + salt] =
                    totalFor(state, inputs, cell, layer, salt) catch unreachable;
        }
    }
}

fn totalFor(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    salt: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.species_count) |species| {
        const plant = cell * state.species_count + species;
        if (!inputs.active_by_plant[plant]) continue;
        const domain_count = inputs.root_domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > state.root_domain_capacity)
            return error.InvalidRootSaltStateUpdateInput;
        for (0..domain_count) |domain| {
            const root =
                (plant * state.root_domain_capacity + domain) *
                state.soil_layer_capacity +
                layer;
            const uptake = inputs.uptake_mol_per_h_by_root_and_salt[
                root * salt_species_count + salt
            ];
            if (!std.math.isFinite(uptake))
                return error.NonFiniteRootSaltStateUpdateInput;
            total += uptake;
        }
    }
    if (!std.math.isFinite(total))
        return error.NonFiniteRootSaltStateUpdate;
    return total;
}

test "dynamic root salt state_update preserves species order and source signs" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const uptake = [_]f64{
        1,   2,   3,   4,   5,   6,   7,   8,
        10,  20,  30,  40,  50,  60,  70,  80,
        -9,  -9,  -9,  -9,  -9,  -9,  -9,  -9,
        999, 999, 999, 999, 999, 999, 999, 999,
    };
    try refresh(&state, .{
        .salinity_enabled_by_cell = &.{true},
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{ true, false },
        .root_domain_count_by_plant = &.{ 2, 1 },
        .uptake_mol_per_h_by_root_and_salt = &uptake,
    });
    const expected = [_]f64{ 11, 22, 33, 44, 55, 66, 77, 88 };
    try std.testing.expectEqualSlices(
        f64,
        &expected,
        state.uptake_mol_per_h_by_layer_and_salt,
    );
}

test "disabled salt state_update does not read transactions and publishes zero" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    @memset(state.uptake_mol_per_h_by_layer_and_salt, 7);
    try refresh(&state, .{
        .salinity_enabled_by_cell = &.{false},
        .active_soil_layer_count_by_cell = &.{1},
        .active_by_plant = &.{true},
        .root_domain_count_by_plant = &.{1},
        .uptake_mol_per_h_by_root_and_salt = &.{
            std.math.nan(f64), 1, 1, 1, 1, 1, 1, 1,
        },
    });
    for (state.uptake_mol_per_h_by_layer_and_salt) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
}

test "late invalid salt transaction preserves published array" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    @memset(state.uptake_mol_per_h_by_layer_and_salt, 7);
    try std.testing.expectError(
        error.NonFiniteRootSaltStateUpdateInput,
        refresh(&state, .{
            .salinity_enabled_by_cell = &.{true},
            .active_soil_layer_count_by_cell = &.{1},
            .active_by_plant = &.{true},
            .root_domain_count_by_plant = &.{1},
            .uptake_mol_per_h_by_root_and_salt = &.{
                1, 1, 1, 1, 1, 1, 1, std.math.nan(f64),
            },
        }),
    );
    for (state.uptake_mol_per_h_by_layer_and_salt) |value|
        try std.testing.expectEqual(@as(f64, 7), value);
}
