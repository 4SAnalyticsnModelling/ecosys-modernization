const std = @import("std");
const harvest = @import("harvest.zig");
const surface_chemistry = @import("../../surface/litter_chemistry.zig");
const soil_chemistry = @import("../../soil/solute/chemistry_state.zig");
const solute_transport = @import("../../soil/solute/transport.zig");
const AqueousSpecies = @import("../../soil/solute/transport_species.zig").AqueousSpecies;

pub const salt_count = harvest.salt_count;

/// Heap-owned extensive salt awaiting an aqueous volume. Exchange layer zero
/// is surface litter; exchange layer `L + 1` is soil layer `L`.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    soil_layer_capacity: usize,
    pending_mol: []f64,
    staged_mol: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        soil_layer_capacity: usize,
    ) !State {
        if (cell_count == 0 or soil_layer_capacity == 0)
            return error.InvalidPlantLitterSaltIngressDimensions;
        const exchange_layers = std.math.add(usize, soil_layer_capacity, 1) catch
            return error.InvalidPlantLitterSaltIngressDimensions;
        const values = std.math.mul(usize, cell_count, exchange_layers) catch
            return error.InvalidPlantLitterSaltIngressDimensions;
        const value_count = std.math.mul(usize, values, salt_count) catch
            return error.InvalidPlantLitterSaltIngressDimensions;
        const pending = try allocator.alloc(f64, value_count);
        errdefer allocator.free(pending);
        const staged = try allocator.alloc(f64, value_count);
        errdefer allocator.free(staged);
        @memset(pending, 0);
        @memset(staged, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .soil_layer_capacity = soil_layer_capacity,
            .pending_mol = pending,
            .staged_mol = staged,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.staged_mol);
        self.allocator.free(self.pending_mol);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    species_count: usize,
    active_soil_layer_count_by_cell: []const usize,
    litter_salt_mol_by_plant_exchange_layer: []const f64,
    surface_water_m3: []const f64,
    soil_water_m3: []const f64,
    water_absolute_tolerance_m3: f64,
    physical_relative_tolerance: f64,
};

/// Binds GROSUB's `ALSNT..CLSNT` state_update to REDIST's surface and
/// micropore owners. All values are preflighted before chemistry or pending
/// storage is mutated, so a failed hour cannot partially transfer salt.
pub fn apply(
    state: *State,
    inputs: Inputs,
    surface: *surface_chemistry.State,
    soil: *soil_chemistry.State,
    micropore: *solute_transport.State,
) !void {
    try validateDimensions(state.*, inputs, surface.*, soil.*, micropore.*);
    try micropore.validateFinite();
    @memcpy(state.staged_mol, state.pending_mol);

    const exchange_layer_count = state.soil_layer_capacity + 1;
    for (0..state.cell_count) |cell| {
        for (0..inputs.species_count) |species| {
            const plant = cell * inputs.species_count + species;
            for (0..exchange_layer_count) |exchange_layer| {
                const active = exchange_layer == 0 or
                    exchange_layer <= inputs.active_soil_layer_count_by_cell[cell];
                for (0..salt_count) |salt| {
                    const source_index =
                        (plant * exchange_layer_count + exchange_layer) * salt_count + salt;
                    const amount_mol =
                        inputs.litter_salt_mol_by_plant_exchange_layer[source_index];
                    if (!std.math.isFinite(amount_mol) or amount_mol < 0)
                        return error.InvalidPlantLitterSaltInput;
                    if (!active and amount_mol != 0)
                        return error.PlantLitterSaltTargetsInactiveSoilLayer;
                    const target_index =
                        (cell * exchange_layer_count + exchange_layer) * salt_count + salt;
                    const total_mol = state.staged_mol[target_index] + amount_mol;
                    if (!std.math.isFinite(total_mol))
                        return error.NonFinitePlantLitterSaltInventory;
                    state.staged_mol[target_index] = total_mol;
                }
            }
        }
    }

    // Preflight every resulting concentration before state_updateting any owner.
    for (0..state.cell_count) |cell| {
        try validateWater(inputs.surface_water_m3[cell]);
        try preflightExchangeLayer(
            state,
            cell,
            0,
            inputs.surface_water_m3[cell],
            inputs.water_absolute_tolerance_m3,
            inputs.physical_relative_tolerance,
            surface.cells[cell],
            null,
        );
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const soil_index = cell * state.soil_layer_capacity + layer;
            try validateWater(inputs.soil_water_m3[soil_index]);
            try preflightExchangeLayer(
                state,
                cell,
                layer + 1,
                inputs.soil_water_m3[soil_index],
                inputs.water_absolute_tolerance_m3,
                inputs.physical_relative_tolerance,
                null,
                soil.aqueous[soil_index],
            );
            if (present(inputs.soil_water_m3[soil_index], inputs.water_absolute_tolerance_m3, inputs.physical_relative_tolerance)) {
                const amounts = try micropore.cellAmountsConst(soil_index);
                for (0..salt_count) |salt| {
                    const ingress_index = ((cell * (state.soil_layer_capacity + 1) + layer + 1) * salt_count) + salt;
                    const species = transportSpecies(@enumFromInt(salt));
                    const next = amounts[@intFromEnum(species)] + state.staged_mol[ingress_index];
                    if (!std.math.isFinite(next) or next < 0)
                        return error.NonFinitePlantLitterSaltTransportInventory;
                }
            }
        }
    }

    for (0..state.cell_count) |cell| {
        state_updateExchangeLayer(
            state,
            cell,
            0,
            inputs.surface_water_m3[cell],
            inputs.water_absolute_tolerance_m3,
            inputs.physical_relative_tolerance,
            &surface.cells[cell],
            null,
        );
        for (0..inputs.active_soil_layer_count_by_cell[cell]) |layer| {
            const soil_index = cell * state.soil_layer_capacity + layer;
            state_updateExchangeLayer(
                state,
                cell,
                layer + 1,
                inputs.soil_water_m3[soil_index],
                inputs.water_absolute_tolerance_m3,
                inputs.physical_relative_tolerance,
                null,
                &soil.aqueous[soil_index],
            );
            if (present(inputs.soil_water_m3[soil_index], inputs.water_absolute_tolerance_m3, inputs.physical_relative_tolerance)) {
                const amounts = micropore.cellAmounts(soil_index) catch unreachable;
                for (0..salt_count) |salt| {
                    const ingress_index = ((cell * (state.soil_layer_capacity + 1) + layer + 1) * salt_count) + salt;
                    amounts[@intFromEnum(transportSpecies(@enumFromInt(salt)))] += state.staged_mol[ingress_index];
                }
            }
        }
    }
}

fn validateDimensions(
    state: State,
    inputs: Inputs,
    surface: surface_chemistry.State,
    soil: soil_chemistry.State,
    micropore: solute_transport.State,
) !void {
    if (inputs.species_count == 0 or
        !std.math.isFinite(inputs.water_absolute_tolerance_m3) or
        inputs.water_absolute_tolerance_m3 < 0 or
        !std.math.isFinite(inputs.physical_relative_tolerance) or
        inputs.physical_relative_tolerance < 0 or
        inputs.active_soil_layer_count_by_cell.len != state.cell_count or
        inputs.surface_water_m3.len != state.cell_count or
        inputs.soil_water_m3.len != state.cell_count * state.soil_layer_capacity or
        surface.cells.len != state.cell_count or
        soil.aqueous.len != inputs.soil_water_m3.len or
        micropore.cell_count != inputs.soil_water_m3.len or
        micropore.species_count != AqueousSpecies.count)
        return error.InvalidPlantLitterSaltIngressDimensions;
    const plant_count = std.math.mul(usize, state.cell_count, inputs.species_count) catch
        return error.InvalidPlantLitterSaltIngressDimensions;
    const exchange_layers = state.soil_layer_capacity + 1;
    const expected = std.math.mul(usize, plant_count, exchange_layers * salt_count) catch
        return error.InvalidPlantLitterSaltIngressDimensions;
    if (inputs.litter_salt_mol_by_plant_exchange_layer.len != expected)
        return error.InvalidPlantLitterSaltIngressDimensions;
    for (inputs.active_soil_layer_count_by_cell) |active| {
        if (active == 0 or active > state.soil_layer_capacity)
            return error.InvalidPlantLitterSaltIngressDimensions;
    }
    for (state.pending_mol) |amount_mol| {
        if (!std.math.isFinite(amount_mol) or amount_mol < 0)
            return error.InvalidPendingPlantLitterSaltInventory;
    }
}

fn transportSpecies(salt: harvest.Salt) AqueousSpecies {
    return switch (salt) {
        .aluminum => .aluminum,
        .iron => .iron,
        .calcium => .calcium,
        .magnesium => .magnesium,
        .sodium => .sodium,
        .potassium => .potassium,
        .sulfate => .sulfate,
        .chloride => .chloride,
    };
}

fn validateWater(water_m3: f64) !void {
    if (!std.math.isFinite(water_m3) or water_m3 < 0)
        return error.InvalidPlantLitterSaltWaterVolume;
}

fn preflightExchangeLayer(
    state: *const State,
    cell: usize,
    exchange_layer: usize,
    water_m3: f64,
    water_absolute_tolerance_m3: f64,
    physical_relative_tolerance: f64,
    surface: ?surface_chemistry.Cell,
    soil: ?@import("../../soil/solute/aqueous_network.zig").State,
) !void {
    for (0..salt_count) |salt| {
        const index = ((cell * (state.soil_layer_capacity + 1) + exchange_layer) * salt_count) + salt;
        const existing = if (surface) |value|
            surfaceConcentration(value, @enumFromInt(salt))
        else
            soilConcentration(soil.?, @enumFromInt(salt));
        if (!std.math.isFinite(existing) or existing < 0)
            return error.InvalidPlantLitterSaltChemistryState;
        if (!present(water_m3, water_absolute_tolerance_m3, physical_relative_tolerance)) continue;
        const next = existing + state.staged_mol[index] / water_m3;
        if (!std.math.isFinite(next) or next < 0)
            return error.InvalidPlantLitterSaltChemistryState;
    }
}

fn state_updateExchangeLayer(
    state: *State,
    cell: usize,
    exchange_layer: usize,
    water_m3: f64,
    water_absolute_tolerance_m3: f64,
    physical_relative_tolerance: f64,
    surface: ?*surface_chemistry.Cell,
    soil: ?*@import("../../soil/solute/aqueous_network.zig").State,
) void {
    if (!present(water_m3, water_absolute_tolerance_m3, physical_relative_tolerance)) {
        for (0..salt_count) |salt| {
            const index = ((cell * (state.soil_layer_capacity + 1) + exchange_layer) * salt_count) + salt;
            state.pending_mol[index] = state.staged_mol[index];
        }
        return;
    }
    for (0..salt_count) |salt| {
        const species: harvest.Salt = @enumFromInt(salt);
        const index = ((cell * (state.soil_layer_capacity + 1) + exchange_layer) * salt_count) + salt;
        const increment = state.staged_mol[index] / water_m3;
        if (surface) |value| addSurfaceConcentration(value, species, increment) else addSoilConcentration(soil.?, species, increment);
        state.pending_mol[index] = 0;
    }
}

fn present(value: f64, absolute_tolerance: f64, relative_tolerance: f64) bool {
    return value > absolute_tolerance + relative_tolerance * @abs(value);
}

fn surfaceConcentration(cell: surface_chemistry.Cell, salt: harvest.Salt) f64 {
    return switch (salt) {
        .aluminum => cell.aluminum_mol_per_m3,
        .iron => cell.iron_mol_per_m3,
        .calcium => cell.calcium_mol_per_m3,
        .magnesium => cell.magnesium_mol_per_m3,
        .sodium => cell.sodium_mol_per_m3,
        .potassium => cell.potassium_mol_per_m3,
        .sulfate => cell.sulfate_mol_per_m3,
        .chloride => cell.chloride_mol_per_m3,
    };
}

fn addSurfaceConcentration(cell: *surface_chemistry.Cell, salt: harvest.Salt, increment: f64) void {
    switch (salt) {
        .aluminum => cell.aluminum_mol_per_m3 += increment,
        .iron => cell.iron_mol_per_m3 += increment,
        .calcium => cell.calcium_mol_per_m3 += increment,
        .magnesium => cell.magnesium_mol_per_m3 += increment,
        .sodium => cell.sodium_mol_per_m3 += increment,
        .potassium => cell.potassium_mol_per_m3 += increment,
        .sulfate => cell.sulfate_mol_per_m3 += increment,
        .chloride => cell.chloride_mol_per_m3 += increment,
    }
}

fn soilConcentration(cell: @import("../../soil/solute/aqueous_network.zig").State, salt: harvest.Salt) f64 {
    return switch (salt) {
        .aluminum => cell.aluminum,
        .iron => cell.iron,
        .calcium => cell.calcium,
        .magnesium => cell.magnesium,
        .sodium => cell.sodium,
        .potassium => cell.potassium,
        .sulfate => cell.sulfate,
        .chloride => cell.chloride,
    };
}

fn addSoilConcentration(cell: *@import("../../soil/solute/aqueous_network.zig").State, salt: harvest.Salt, increment: f64) void {
    switch (salt) {
        .aluminum => cell.aluminum += increment,
        .iron => cell.iron += increment,
        .calcium => cell.calcium += increment,
        .magnesium => cell.magnesium += increment,
        .sodium => cell.sodium += increment,
        .potassium => cell.potassium += increment,
        .sulfate => cell.sulfate += increment,
        .chloride => cell.chloride += increment,
    }
}

test "plant litter salt ingress conserves eight salts and defers dry layers" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 2, 2);
    defer state.deinit();
    var surface = try surface_chemistry.State.init(allocator, 2);
    defer surface.deinit();
    var soil = try soil_chemistry.State.init(allocator, 4);
    defer soil.deinit();
    var micropore = try solute_transport.State.init(allocator, 4, AqueousSpecies.count);
    defer micropore.deinit();
    const source = try allocator.alloc(f64, 2 * 2 * 3 * salt_count);
    defer allocator.free(source);
    @memset(source, 0);
    for (0..2) |cell| for (0..2) |species| for (0..3) |layer| for (0..salt_count) |salt| {
        const plant = cell * 2 + species;
        source[(plant * 3 + layer) * salt_count + salt] =
            @as(f64, @floatFromInt(1 + cell * 100 + species * 20 + layer * 5 + salt)) * 1e-6;
    };
    const active = [_]usize{ 2, 2 };
    var surface_water = [_]f64{ 0.25, 0.5 };
    var soil_water = [_]f64{ 0.4, 0, 0.6, 0.8 };
    try apply(&state, .{
        .species_count = 2,
        .active_soil_layer_count_by_cell = &active,
        .litter_salt_mol_by_plant_exchange_layer = source,
        .surface_water_m3 = &surface_water,
        .soil_water_m3 = &soil_water,
        .water_absolute_tolerance_m3 = 1e-12,
        .physical_relative_tolerance = 1e-12,
    }, &surface, &soil, &micropore);

    for (0..2) |cell| for (0..3) |layer| for (0..salt_count) |salt| {
        var expected_mol: f64 = 0;
        for (0..2) |species| {
            const plant = cell * 2 + species;
            expected_mol += source[(plant * 3 + layer) * salt_count + salt];
        }
        const water = if (layer == 0) surface_water[cell] else soil_water[cell * 2 + layer - 1];
        const concentration = if (layer == 0)
            surfaceConcentration(surface.cells[cell], @enumFromInt(salt))
        else
            soilConcentration(soil.aqueous[cell * 2 + layer - 1], @enumFromInt(salt));
        const pending = state.pending_mol[(cell * 3 + layer) * salt_count + salt];
        try std.testing.expectApproxEqAbs(expected_mol, concentration * water + pending, 1e-15);
        if (layer > 0) {
            const transported = micropore.amount_mol[((cell * 2 + layer - 1) * AqueousSpecies.count) + @intFromEnum(transportSpecies(@enumFromInt(salt)))];
            try std.testing.expectApproxEqAbs(expected_mol - pending, transported, 1e-15);
        }
    };

    @memset(source, 0);
    soil_water[1] = 0.2;
    try apply(&state, .{
        .species_count = 2,
        .active_soil_layer_count_by_cell = &active,
        .litter_salt_mol_by_plant_exchange_layer = source,
        .surface_water_m3 = &surface_water,
        .soil_water_m3 = &soil_water,
        .water_absolute_tolerance_m3 = 1e-12,
        .physical_relative_tolerance = 1e-12,
    }, &surface, &soil, &micropore);
    for (0..salt_count) |salt|
        try std.testing.expectEqual(@as(f64, 0), state.pending_mol[(2 * salt_count) + salt]);
    for (0..salt_count) |salt| {
        const expected_mol = @as(f64, @floatFromInt(42 + 2 * salt)) * 1e-6;
        const transported = micropore.amount_mol[AqueousSpecies.count + @intFromEnum(transportSpecies(@enumFromInt(salt)))];
        try std.testing.expectApproxEqAbs(expected_mol, transported, 1e-15);
    }
}

test "plant litter salt ingress rejects a late invalid value atomically" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 1, 1);
    defer state.deinit();
    var surface = try surface_chemistry.State.init(allocator, 1);
    defer surface.deinit();
    var soil = try soil_chemistry.State.init(allocator, 1);
    defer soil.deinit();
    var micropore = try solute_transport.State.init(allocator, 1, AqueousSpecies.count);
    defer micropore.deinit();
    var source = [_]f64{0} ** (2 * salt_count);
    source[source.len - 1] = std.math.nan(f64);
    surface.cells[0].calcium_mol_per_m3 = 7;
    const active = [_]usize{1};
    const surface_water = [_]f64{1};
    const soil_water = [_]f64{1};
    try std.testing.expectError(error.InvalidPlantLitterSaltInput, apply(&state, .{
        .species_count = 1,
        .active_soil_layer_count_by_cell = &active,
        .litter_salt_mol_by_plant_exchange_layer = &source,
        .surface_water_m3 = &surface_water,
        .soil_water_m3 = &soil_water,
        .water_absolute_tolerance_m3 = 1e-12,
        .physical_relative_tolerance = 1e-12,
    }, &surface, &soil, &micropore));
    try std.testing.expectEqual(@as(f64, 7), surface.cells[0].calcium_mol_per_m3);
    for (state.pending_mol) |amount_mol| try std.testing.expectEqual(@as(f64, 0), amount_mol);
    for (micropore.amount_mol) |amount_mol| try std.testing.expectEqual(@as(f64, 0), amount_mol);
}
