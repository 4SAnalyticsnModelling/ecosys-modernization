const std = @import("std");

pub const salt_species_count: usize = 8;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    soil_layer_capacity: usize,
    root_domain_capacity: usize,
    released_mol_per_h_by_layer_and_salt: []f64,
    total_released_mol_per_h_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
        soil_layer_capacity: usize,
        root_domain_capacity: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0 or
            soil_layer_capacity == 0 or root_domain_capacity == 0)
            return error.InvalidRootCombustionSaltStateUpdateDimensions;
        const layer_count = try std.math.mul(usize, cell_count, soil_layer_capacity);
        const layer_value_count = try std.math.mul(usize, layer_count, salt_species_count);
        const values = try allocator.alloc(
            f64,
            try std.math.add(usize, layer_value_count, cell_count),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .soil_layer_capacity = soil_layer_capacity,
            .root_domain_capacity = root_domain_capacity,
            .released_mol_per_h_by_layer_and_salt = values[0..layer_value_count],
            .total_released_mol_per_h_by_cell = values[layer_value_count..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.released_mol_per_h_by_layer_and_salt.ptr[0 .. self.released_mol_per_h_by_layer_and_salt.len + self.cell_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    salinity_enabled_by_cell: []const bool,
    fire_active_by_cell: []const bool,
    active_soil_layer_count_by_cell: []const usize,
    root_domain_count_by_plant: []const u8,
    released_mol_per_h_by_root_and_salt: []const f64,
};

/// EXTRACT lines 531–562. Root-combustion salts retain the source order
/// Al, Fe, Ca, Mg, Na, K, SO4, Cl and publish atomically.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    const root_count = try std.math.mul(
        usize,
        try std.math.mul(usize, plant_count, state.root_domain_capacity),
        state.soil_layer_capacity,
    );
    if (inputs.salinity_enabled_by_cell.len != state.cell_count or
        inputs.fire_active_by_cell.len != state.cell_count or
        inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.root_domain_count_by_plant.len != plant_count or
        inputs.released_mol_per_h_by_root_and_salt.len !=
            try std.math.mul(usize, root_count, salt_species_count))
        return error.InvalidRootCombustionSaltStateUpdateDimensions;
    for (inputs.active_soil_layer_count_by_cell) |active_layers|
        if (active_layers > state.soil_layer_capacity)
            return error.InvalidRootCombustionSaltStateUpdateDimensions;

    for (0..state.cell_count) |cell| {
        if (!inputs.salinity_enabled_by_cell[cell]) continue;
        if (!inputs.fire_active_by_cell[cell]) continue;
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            for (0..salt_species_count) |salt| {
                _ = try totalForLayerSalt(state, inputs, cell, layer, salt);
            }
        }
        _ = try totalForCell(state, inputs, cell);
    }

    @memset(state.released_mol_per_h_by_layer_and_salt, 0);
    @memset(state.total_released_mol_per_h_by_cell, 0);
    for (0..state.cell_count) |cell| {
        if (!inputs.salinity_enabled_by_cell[cell]) continue;
        if (!inputs.fire_active_by_cell[cell]) continue;
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const output = (cell * state.soil_layer_capacity + layer) *
                salt_species_count;
            for (0..salt_species_count) |salt| {
                state.released_mol_per_h_by_layer_and_salt[output + salt] =
                    totalForLayerSalt(state, inputs, cell, layer, salt) catch unreachable;
            }
        }
        state.total_released_mol_per_h_by_cell[cell] =
            totalForCell(state, inputs, cell) catch unreachable;
    }
}

fn rootIndex(
    state: *const State,
    plant: usize,
    domain: usize,
    layer: usize,
) usize {
    return (plant * state.root_domain_capacity + domain) *
        state.soil_layer_capacity + layer;
}

fn checkedInput(inputs: Inputs, root: usize, salt: usize) !f64 {
    const value = inputs.released_mol_per_h_by_root_and_salt[
        root * salt_species_count + salt
    ];
    if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootCombustionSaltStateUpdateInput;
    return value;
}

fn domainCount(state: *const State, inputs: Inputs, plant: usize) !usize {
    const count = inputs.root_domain_count_by_plant[plant];
    if (count == 0 or count > state.root_domain_capacity)
        return error.InvalidRootCombustionSaltStateUpdateInput;
    return count;
}

fn totalForLayerSalt(
    state: *const State,
    inputs: Inputs,
    cell: usize,
    layer: usize,
    salt: usize,
) !f64 {
    var total: f64 = 0;
    for (0..state.plant_species_per_cell) |species| {
        const plant = cell * state.plant_species_per_cell + species;
        for (0..try domainCount(state, inputs, plant)) |domain| {
            total += try checkedInput(
                inputs,
                rootIndex(state, plant, domain, layer),
                salt,
            );
            if (!std.math.isFinite(total))
                return error.NonFiniteRootCombustionSaltStateUpdate;
        }
    }
    return total;
}

fn totalForCell(state: *const State, inputs: Inputs, cell: usize) !f64 {
    var total: f64 = 0;
    for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
        for (0..state.plant_species_per_cell) |species| {
            const plant = cell * state.plant_species_per_cell + species;
            for (0..try domainCount(state, inputs, plant)) |domain| {
                for (0..salt_species_count) |salt| {
                    total += try checkedInput(
                        inputs,
                        rootIndex(state, plant, domain, layer),
                        salt,
                    );
                    if (!std.math.isFinite(total))
                        return error.NonFiniteRootCombustionSaltStateUpdate;
                }
            }
        }
    }
    return total;
}

test "root combustion salt state_update preserves source axes and total order" {
    var state = try State.init(std.testing.allocator, 1, 2, 1, 2);
    defer state.deinit();
    const released = [_]f64{
        1,    2,    3,    4,    5,    6,    7,    8,
        10,   20,   30,   40,   50,   60,   70,   80,
        100,  200,  300,  400,  500,  600,  700,  800,
        1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000,
    };
    try refresh(&state, .{
        .salinity_enabled_by_cell = &.{true},
        .fire_active_by_cell = &.{true},
        .active_soil_layer_count_by_cell = &.{1},
        .root_domain_count_by_plant = &.{ 2, 1 },
        .released_mol_per_h_by_root_and_salt = &released,
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 111, 222, 333, 444, 555, 666, 777, 888 },
        state.released_mol_per_h_by_layer_and_salt,
    );
    try std.testing.expectEqual(@as(f64, 3996), state.total_released_mol_per_h_by_cell[0]);
}

test "disabled and inactive cells publish zero without reading transactions" {
    var state = try State.init(std.testing.allocator, 1, 1, 1, 1);
    defer state.deinit();
    @memset(state.released_mol_per_h_by_layer_and_salt, 7);
    @memset(state.total_released_mol_per_h_by_cell, 7);
    const invalid = [_]f64{std.math.nan(f64)} ** salt_species_count;
    try refresh(&state, .{
        .salinity_enabled_by_cell = &.{false},
        .fire_active_by_cell = &.{true},
        .active_soil_layer_count_by_cell = &.{1},
        .root_domain_count_by_plant = &.{1},
        .released_mol_per_h_by_root_and_salt = &invalid,
    });
    for (state.released_mol_per_h_by_layer_and_salt) |value|
        try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 0), state.total_released_mol_per_h_by_cell[0]);
}

test "late invalid active root salt preserves complete state_update" {
    var state = try State.init(std.testing.allocator, 2, 1, 1, 1);
    defer state.deinit();
    @memset(state.released_mol_per_h_by_layer_and_salt, 7);
    @memset(state.total_released_mol_per_h_by_cell, 7);
    var released = [_]f64{1} ** (2 * salt_species_count);
    released[released.len - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidRootCombustionSaltStateUpdateInput,
        refresh(&state, .{
            .salinity_enabled_by_cell = &.{ true, true },
            .fire_active_by_cell = &.{ true, true },
            .active_soil_layer_count_by_cell = &.{ 1, 1 },
            .root_domain_count_by_plant = &.{ 1, 1 },
            .released_mol_per_h_by_root_and_salt = &released,
        }),
    );
    for (state.released_mol_per_h_by_layer_and_salt) |value|
        try std.testing.expectEqual(@as(f64, 7), value);
    for (state.total_released_mol_per_h_by_cell) |value|
        try std.testing.expectEqual(@as(f64, 7), value);
}
