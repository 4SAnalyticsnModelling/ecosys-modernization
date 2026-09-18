// STARTE lines 1981--2050 seed surface-litter aqueous complexes from the
// equilibrated top mineral layer only when that cell's site enables salinity.
const std = @import("std");
const ChemistryState = @import("../soil/solute/chemistry_state.zig").State;
const aqueous_transport_bridge = @import("../soil/solute/aqueous_transport_bridge.zig");
const surface_routing = @import("../soil/solute/surface_solute_routing.zig");
const Species = @import("../soil/solute/transport_species.zig").AqueousSpecies;

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

/// Named anion values; units are supplied by the owning aggregate.
pub const Anions = struct {
    sulfate: f64,
    chloride: f64,
    carbonate: f64,
    bicarbonate: f64,
};

pub const AluminumComplexes = struct {
    monohydroxide: f64,
    dihydroxide: f64,
    trihydroxide: f64,
    tetrahydroxide: f64,
    sulfate: f64,
};

pub const IronComplexes = struct {
    monohydroxide: f64,
    dihydroxide: f64,
    trihydroxide: f64,
    tetrahydroxide: f64,
    sulfate: f64,
};

pub const BaseCationComplexes = struct {
    calcium_hydroxide: f64,
    calcium_carbonate: f64,
    calcium_bicarbonate: f64,
    calcium_sulfate: f64,
    magnesium_hydroxide: f64,
    magnesium_carbonate: f64,
    magnesium_bicarbonate: f64,
    magnesium_sulfate: f64,
    sodium_carbonate: f64,
    sodium_sulfate: f64,
    potassium_sulfate: f64,
};

pub const PhosphateComplexes = struct {
    phosphate: f64,
    phosphoric_acid: f64,
    iron_monophosphate: f64,
    iron_diphosphate: f64,
    calcium_phosphate: f64,
    calcium_hydrogen_phosphate: f64,
    calcium_dihydrogen_phosphate: f64,
    magnesium_hydrogen_phosphate: f64,
};

/// Every leaf value is an aqueous concentration in mol m-3 (mol P m-3 for
/// phosphate-bearing species).
pub const Concentrations = struct {
    anions: Anions,
    aluminum: AluminumComplexes,
    iron: IronComplexes,
    base_cations: BaseCationComplexes,
    phosphate: PhosphateComplexes,
};

/// Every leaf value is an extensive inventory in mol (mol P for
/// phosphate-bearing species).
pub const Inventories = struct {
    anions: Anions,
    aluminum: AluminumComplexes,
    iron: IronComplexes,
    base_cations: BaseCationComplexes,
    phosphate: PhosphateComplexes,
};

pub const State = struct {
    inventories: Inventories,
    proton_balance_mol: f64,
};

fn validateAndScale(comptime T: type, input: T, water_m3: f64) !T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        const concentration = @field(input, field.name);
        if (!std.math.isFinite(concentration))
            return error.NonFiniteSurfaceIonComplexConcentration;
        if (concentration < 0)
            return error.InvalidSurfaceIonComplexConcentration;
        const inventory = concentration * water_m3;
        if (!std.math.isFinite(inventory))
            return error.NonFiniteSurfaceIonComplexInventory;
        @field(result, field.name) = inventory;
    }
    return result;
}

/// Direct translation of `starte.f` lines 1981--2050 for one surface litter cell.
/// In dynamic mode, topsoil concentrations are converted to extensive litter
/// inventories. The static branch zeros those inventories and, as in STARTE,
/// deliberately leaves the existing proton-balance inventory unchanged.
pub fn initialize(
    state: *State,
    mode: SaltEquilibriumMode,
    water_capacity_m3: f64,
    concentrations: Concentrations,
    initial_proton_balance_concentration: f64,
) !void {
    if (!std.math.isFinite(water_capacity_m3))
        return error.NonFiniteSurfaceIonComplexWaterCapacity;
    if (water_capacity_m3 < 0)
        return error.InvalidSurfaceIonComplexWaterCapacity;

    switch (mode) {
        .static => state.inventories = std.mem.zeroes(Inventories),
        .dynamic => {
            if (!std.math.isFinite(initial_proton_balance_concentration))
                return error.NonFiniteSurfaceProtonBalanceConcentration;
            if (initial_proton_balance_concentration < 0)
                return error.InvalidSurfaceProtonBalanceConcentration;
            const next: Inventories = .{
                .anions = try validateAndScale(
                    Anions,
                    concentrations.anions,
                    water_capacity_m3,
                ),
                .aluminum = try validateAndScale(
                    AluminumComplexes,
                    concentrations.aluminum,
                    water_capacity_m3,
                ),
                .iron = try validateAndScale(
                    IronComplexes,
                    concentrations.iron,
                    water_capacity_m3,
                ),
                .base_cations = try validateAndScale(
                    BaseCationComplexes,
                    concentrations.base_cations,
                    water_capacity_m3,
                ),
                .phosphate = try validateAndScale(
                    PhosphateComplexes,
                    concentrations.phosphate,
                    water_capacity_m3,
                ),
            };
            const proton_balance_mol =
                initial_proton_balance_concentration * water_capacity_m3;
            if (!std.math.isFinite(proton_balance_mol))
                return error.NonFiniteSurfaceProtonBalanceInventory;
            state.* = .{
                .inventories = next,
                .proton_balance_mol = proton_balance_mol,
            };
        },
    }
}

/// Initializes the production extensive owner for all STARTE surface aqueous
/// complex coordinates. The transaction validates every enabled cell before
/// publishing anything; disabled cells deliberately do not read salt state.
pub fn initializeTransportFromTopsoil(
    transport: *surface_routing.State,
    topsoil: *const ChemistryState,
    soil_layer_capacity: usize,
    litter_water_m3: []const f64,
    salinity_enabled_by_cell: []const bool,
) !void {
    const cells = try std.math.mul(usize, transport.columns, transport.rows);
    const soil_cells = std.math.mul(usize, cells, soil_layer_capacity) catch
        return error.SurfaceIonComplexInitializationDimensionMismatch;
    if (transport.species_count != Species.count or
        transport.carrier_volume_m3.len != cells or
        transport.amount_mol.len != cells * Species.count or
        soil_layer_capacity == 0 or topsoil.cell_count != soil_cells or
        litter_water_m3.len != cells or
        salinity_enabled_by_cell.len != cells)
        return error.SurfaceIonComplexInitializationDimensionMismatch;

    for (0..cells) |cell| {
        const water = litter_water_m3[cell];
        if (!std.math.isFinite(water) or water < 0)
            return error.InvalidSurfaceIonComplexWaterCapacity;
        const topsoil_cell = cell * soil_layer_capacity;
        if (!salinity_enabled_by_cell[cell]) continue;
        for (12..42) |species_index| {
            const concentration = aqueous_transport_bridge.concentration(
                topsoil,
                topsoil_cell,
                @enumFromInt(species_index),
            );
            if (!std.math.isFinite(concentration) or concentration < 0)
                return error.InvalidSurfaceIonComplexConcentration;
            const amount = concentration * water;
            if (!std.math.isFinite(amount))
                return error.NonFiniteSurfaceIonComplexInventory;
        }
    }

    @memset(transport.amount_mol, 0);
    @memcpy(transport.carrier_volume_m3, litter_water_m3);
    for (0..cells) |cell| {
        if (!salinity_enabled_by_cell[cell]) continue;
        const base = cell * Species.count;
        for (12..42) |species_index| {
            transport.amount_mol[base + species_index] =
                aqueous_transport_bridge.concentration(
                    topsoil,
                    cell * soil_layer_capacity,
                    @enumFromInt(species_index),
                ) * litter_water_m3[cell];
        }
    }
}

fn uniformConcentrations(value: f64) Concentrations {
    return .{
        .anions = .{
            .sulfate = value,
            .chloride = value,
            .carbonate = value,
            .bicarbonate = value,
        },
        .aluminum = .{
            .monohydroxide = value,
            .dihydroxide = value,
            .trihydroxide = value,
            .tetrahydroxide = value,
            .sulfate = value,
        },
        .iron = .{
            .monohydroxide = value,
            .dihydroxide = value,
            .trihydroxide = value,
            .tetrahydroxide = value,
            .sulfate = value,
        },
        .base_cations = .{
            .calcium_hydroxide = value,
            .calcium_carbonate = value,
            .calcium_bicarbonate = value,
            .calcium_sulfate = value,
            .magnesium_hydroxide = value,
            .magnesium_carbonate = value,
            .magnesium_bicarbonate = value,
            .magnesium_sulfate = value,
            .sodium_carbonate = value,
            .sodium_sulfate = value,
            .potassium_sulfate = value,
        },
        .phosphate = .{
            .phosphate = value,
            .phosphoric_acid = value,
            .iron_monophosphate = value,
            .iron_diphosphate = value,
            .calcium_phosphate = value,
            .calcium_hydrogen_phosphate = value,
            .calcium_dihydrogen_phosphate = value,
            .magnesium_hydrogen_phosphate = value,
        },
    };
}

test "STARTE dynamic surface ion complexes scale topsoil concentrations" {
    var state: State = undefined;
    try initialize(&state, .dynamic, 2.5, uniformConcentrations(4), 1.0e-3);
    try std.testing.expectEqual(
        @as(f64, 10),
        state.inventories.anions.sulfate,
    );
    try std.testing.expectEqual(
        @as(f64, 10),
        state.inventories.base_cations.potassium_sulfate,
    );
    try std.testing.expectEqual(
        @as(f64, 10),
        state.inventories.phosphate.magnesium_hydrogen_phosphate,
    );
    try std.testing.expectEqual(@as(f64, 2.5e-3), state.proton_balance_mol);
}

test "STARTE static surface salt branch zeros complexes but retains proton balance" {
    var state: State = .{
        .inventories = undefined,
        .proton_balance_mol = 7,
    };
    try initialize(&state, .static, 3, uniformConcentrations(std.math.nan(f64)), -1);
    try std.testing.expectEqual(
        @as(f64, 0),
        state.inventories.aluminum.monohydroxide,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        state.inventories.phosphate.phosphoric_acid,
    );
    try std.testing.expectEqual(@as(f64, 7), state.proton_balance_mol);
}

test "STARTE dynamic surface ion initialization is atomic on invalid input" {
    var state: State = .{
        .inventories = std.mem.zeroes(Inventories),
        .proton_balance_mol = 9,
    };
    var invalid = uniformConcentrations(1);
    invalid.iron.sulfate = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteSurfaceIonComplexConcentration,
        initialize(&state, .dynamic, 2, invalid, 1.0e-3),
    );
    try std.testing.expectEqual(@as(f64, 9), state.proton_balance_mol);
    try std.testing.expectEqual(
        @as(f64, 0),
        state.inventories.anions.sulfate,
    );
}

test "production surface complex owner follows mixed per-cell salinity and is atomic" {
    var topsoil = try ChemistryState.init(std.testing.allocator, 2);
    defer topsoil.deinit();
    topsoil.aqueous[0].aluminum_hydroxide_1 = std.math.nan(f64);
    topsoil.aqueous[1].aluminum_hydroxide_1 = 3;
    topsoil.aqueous[1].potassium_sulfate = 5;
    topsoil.non_band_phosphate[1].iron_hpo4_pair_mol_per_m3 = 7;
    topsoil.non_band_phosphate[1].magnesium_hpo4_pair_mol_per_m3 = 11;

    var transport = try surface_routing.State.init(std.testing.allocator, 2, 1, Species.count);
    defer transport.deinit();
    try initializeTransportFromTopsoil(&transport, &topsoil, 1, &.{ 0.5, 2 }, &.{ false, true });
    const zeros: [Species.count]f64 = @splat(0);
    try std.testing.expectEqualSlices(f64, &zeros, transport.amount_mol[0..Species.count]);
    const enabled = transport.amount_mol[Species.count..][0..Species.count];
    try std.testing.expectEqual(@as(f64, 6), enabled[@intFromEnum(Species.aluminum_hydroxide_1)]);
    try std.testing.expectEqual(@as(f64, 10), enabled[@intFromEnum(Species.potassium_sulfate)]);
    try std.testing.expectEqual(@as(f64, 14), enabled[@intFromEnum(Species.non_band_iron_hpo4)]);
    try std.testing.expectEqual(@as(f64, 22), enabled[@intFromEnum(Species.non_band_magnesium_hpo4)]);
    try std.testing.expectEqualSlices(f64, &.{ 0.5, 2 }, transport.carrier_volume_m3);

    const before = try std.testing.allocator.dupe(f64, transport.amount_mol);
    defer std.testing.allocator.free(before);
    topsoil.aqueous[1].iron_sulfate = -1;
    try std.testing.expectError(
        error.InvalidSurfaceIonComplexConcentration,
        initializeTransportFromTopsoil(&transport, &topsoil, 1, &.{ 1, 3 }, &.{ false, true }),
    );
    try std.testing.expectEqualSlices(f64, before, transport.amount_mol);
    try std.testing.expectEqualSlices(f64, &.{ 0.5, 2 }, transport.carrier_volume_m3);
}
