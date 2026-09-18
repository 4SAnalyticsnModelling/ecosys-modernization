const std = @import("std");

const water_heat_capacity_megajoules_per_m3_k = 4.19;

/// Runtime-sized EXTRACT `ENGYC/ENGYX/THFLXC` state_update. Plant arrays use
/// cell-major then species-major ordering; cell arrays are exact plant sums.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    water_energy_megajoules_by_plant: []f64,
    water_energy_change_megajoules_per_h_by_plant: []f64,
    water_energy_megajoules_by_cell: []f64,
    water_energy_change_megajoules_per_h_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        species_count: usize,
    ) !State {
        if (cell_count == 0 or species_count == 0)
            return error.InvalidCanopyWaterEnergyStateUpdateDimensions;
        const plant_count = try std.math.mul(usize, cell_count, species_count);
        const plant_energy = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(plant_energy);
        const plant_change = try allocator.alloc(f64, plant_count);
        errdefer allocator.free(plant_change);
        const cell_energy = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(cell_energy);
        const cell_change = try allocator.alloc(f64, cell_count);
        @memset(plant_energy, 0);
        @memset(plant_change, 0);
        @memset(cell_energy, 0);
        @memset(cell_change, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .water_energy_megajoules_by_plant = plant_energy,
            .water_energy_change_megajoules_per_h_by_plant = plant_change,
            .water_energy_megajoules_by_cell = cell_energy,
            .water_energy_change_megajoules_per_h_by_cell = cell_change,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.water_energy_change_megajoules_per_h_by_cell);
        self.allocator.free(self.water_energy_megajoules_by_cell);
        self.allocator.free(self.water_energy_change_megajoules_per_h_by_plant);
        self.allocator.free(self.water_energy_megajoules_by_plant);
        self.* = undefined;
    }
};

pub const Inputs = struct {
    air_temperature_k_by_cell: []const f64,
    canopy_temperature_k_by_plant: []const f64,
    /// UPTAKE/EXTRACT `VOLWC`: accepted living intercepted-water inventory.
    living_surface_water_m3_by_plant: []const f64,
    /// UPTAKE/EXTRACT `VOLWQ`: accepted standing-dead water inventory.
    standing_dead_surface_water_m3_by_plant: []const f64,
    /// EXTRACT `FLWC`: retained living-canopy precipitation for this hour.
    living_retention_m3_per_h_by_plant: []const f64,
    /// EXTRACT `FLWD`: retained standing-dead precipitation for this hour.
    standing_dead_retention_m3_per_h_by_plant: []const f64,
};

const Candidate = struct {
    water_energy_megajoules: f64,
    water_energy_change_megajoules_per_h: f64,
};

/// Exact EXTRACT lines 643–649 under ecosys-ng whole-hour endpoint semantics.
/// Accepted `VOLWC/VOLWQ` surface inventories already contain `FLWC/FLWD` and
/// `EVAPC` changes, so those are not added to current storage a second time;
/// only retained precipitation carries incoming atmospheric enthalpy.
/// `VOLWP` is deliberately absent: EXTRACT includes it in `TVOLWP` water
/// storage (lines 639–640) but not in `ENGYC` (lines 643–645). Its root-carried
/// sensible heat remains the separately translated `TUPHT` soil-layer term.
/// Every candidate and cell sum is proven before published or persistent
/// `previous_water_energy_megajoules_by_plant` state changes.
pub fn refresh(
    state: *State,
    inputs: Inputs,
    previous_water_energy_megajoules_by_plant: []f64,
) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.species_count,
    );
    if (inputs.air_temperature_k_by_cell.len != state.cell_count or
        previous_water_energy_megajoules_by_plant.len != plant_count)
        return error.InvalidCanopyWaterEnergyStateUpdateDimensions;
    inline for (@typeInfo(Inputs).@"struct".fields[1..]) |field|
        if (@field(inputs, field.name).len != plant_count)
            return error.InvalidCanopyWaterEnergyStateUpdateDimensions;

    for (0..plant_count) |plant| _ = try candidate(
        state.species_count,
        inputs,
        previous_water_energy_megajoules_by_plant,
        plant,
    );
    for (0..state.cell_count) |cell| {
        var cell_energy: f64 = 0;
        var cell_change: f64 = 0;
        const first = cell * state.species_count;
        for (first..first + state.species_count) |plant| {
            const next = candidate(
                state.species_count,
                inputs,
                previous_water_energy_megajoules_by_plant,
                plant,
            ) catch unreachable;
            cell_energy += next.water_energy_megajoules;
            cell_change += next.water_energy_change_megajoules_per_h;
        }
        if (!std.math.isFinite(cell_energy) or !std.math.isFinite(cell_change))
            return error.NonFiniteCanopyWaterEnergyStateUpdate;
    }

    @memset(state.water_energy_megajoules_by_cell, 0);
    @memset(state.water_energy_change_megajoules_per_h_by_cell, 0);
    for (0..plant_count) |plant| {
        const next = candidate(
            state.species_count,
            inputs,
            previous_water_energy_megajoules_by_plant,
            plant,
        ) catch unreachable;
        const cell = plant / state.species_count;
        state.water_energy_megajoules_by_plant[plant] = next.water_energy_megajoules;
        state.water_energy_change_megajoules_per_h_by_plant[plant] =
            next.water_energy_change_megajoules_per_h;
        state.water_energy_megajoules_by_cell[cell] += next.water_energy_megajoules;
        state.water_energy_change_megajoules_per_h_by_cell[cell] +=
            next.water_energy_change_megajoules_per_h;
        previous_water_energy_megajoules_by_plant[plant] = next.water_energy_megajoules;
    }
}

fn candidate(
    species_count: usize,
    inputs: Inputs,
    previous_water_energy_megajoules_by_plant: []const f64,
    plant: usize,
) !Candidate {
    const cell = plant / species_count;
    const air_temperature = inputs.air_temperature_k_by_cell[cell];
    const canopy_temperature = inputs.canopy_temperature_k_by_plant[plant];
    const living_water = inputs.living_surface_water_m3_by_plant[plant];
    const dead_water = inputs.standing_dead_surface_water_m3_by_plant[plant];
    const living_retention =
        inputs.living_retention_m3_per_h_by_plant[plant];
    const dead_retention =
        inputs.standing_dead_retention_m3_per_h_by_plant[plant];
    const previous = previous_water_energy_megajoules_by_plant[plant];
    inline for (.{
        air_temperature,
        canopy_temperature,
        living_water,
        dead_water,
        living_retention,
        dead_retention,
        previous,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteCanopyWaterEnergyStateUpdateInput;
    if (air_temperature <= 0 or canopy_temperature <= 0 or living_water < 0 or
        dead_water < 0 or
        previous < 0)
        return error.InvalidCanopyWaterEnergyStateUpdateInput;
    const current = water_heat_capacity_megajoules_per_m3_k *
        (living_water + dead_water) * canopy_temperature;
    const incoming = water_heat_capacity_megajoules_per_m3_k *
        (living_retention + dead_retention) * air_temperature;
    const result: Candidate = .{
        .water_energy_megajoules = current,
        .water_energy_change_megajoules_per_h = current - previous - incoming,
    };
    if (!std.math.isFinite(result.water_energy_megajoules) or
        result.water_energy_megajoules < 0 or
        !std.math.isFinite(result.water_energy_change_megajoules_per_h))
        return error.NonFiniteCanopyWaterEnergyStateUpdate;
    return result;
}

test "canopy water energy state_update preserves runtime order and cell sums" {
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    var previous = [_]f64{ 1, 2, 3, 4, 5, 6 };
    try refresh(&state, .{
        .air_temperature_k_by_cell = &.{ 280, 290 },
        .canopy_temperature_k_by_plant = &.{ 281, 282, 283, 291, 292, 293 },
        .living_surface_water_m3_by_plant = &.{ 1, 2, 3, 4, 5, 6 },
        .standing_dead_surface_water_m3_by_plant = &.{ 6, 5, 4, 3, 2, 1 },
        .living_retention_m3_per_h_by_plant = &.{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 },
        .standing_dead_retention_m3_per_h_by_plant = &.{ 0.6, 0.5, 0.4, 0.3, 0.2, 0.1 },
    }, &previous);
    const expected_last = 4.19 * 7 * 293;
    const expected_last_change = expected_last - 6 - 4.19 * 0.7 * 290;
    try std.testing.expectApproxEqAbs(
        expected_last,
        state.water_energy_megajoules_by_plant[5],
        32 * std.math.floatEps(f64) * @max(1, @abs(expected_last)),
    );
    try std.testing.expectApproxEqAbs(
        expected_last_change,
        state.water_energy_change_megajoules_per_h_by_plant[5],
        32 * std.math.floatEps(f64) * @max(1, @abs(expected_last_change)),
    );
    var second_cell_energy: f64 = 0;
    var second_cell_change: f64 = 0;
    for (3..6) |plant| {
        second_cell_energy += state.water_energy_megajoules_by_plant[plant];
        second_cell_change +=
            state.water_energy_change_megajoules_per_h_by_plant[plant];
    }
    try std.testing.expectApproxEqAbs(
        second_cell_energy,
        state.water_energy_megajoules_by_cell[1],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        second_cell_change,
        state.water_energy_change_megajoules_per_h_by_cell[1],
        1e-12,
    );
    try std.testing.expectEqualSlices(
        f64,
        state.water_energy_megajoules_by_plant,
        &previous,
    );
}

test "late invalid energy input preserves state_update and previous energy" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    @memset(state.water_energy_megajoules_by_plant, 7);
    @memset(state.water_energy_change_megajoules_per_h_by_plant, 8);
    @memset(state.water_energy_megajoules_by_cell, 9);
    @memset(state.water_energy_change_megajoules_per_h_by_cell, 10);
    var previous = [_]f64{ 11, 12 };
    const invalid = [_]f64{ 280, std.math.nan(f64) };
    try std.testing.expectError(
        error.NonFiniteCanopyWaterEnergyStateUpdateInput,
        refresh(&state, .{
            .air_temperature_k_by_cell = &.{280},
            .canopy_temperature_k_by_plant = &invalid,
            .living_surface_water_m3_by_plant = &.{ 1, 1 },
            .standing_dead_surface_water_m3_by_plant = &.{ 1, 1 },
            .living_retention_m3_per_h_by_plant = &.{ 0, 0 },
            .standing_dead_retention_m3_per_h_by_plant = &.{ 0, 0 },
        }, &previous),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 7 }, state.water_energy_megajoules_by_plant);
    try std.testing.expectEqualSlices(
        f64,
        &.{ 8, 8 },
        state.water_energy_change_megajoules_per_h_by_plant,
    );
    try std.testing.expectEqualSlices(f64, &.{9}, state.water_energy_megajoules_by_cell);
    try std.testing.expectEqualSlices(
        f64,
        &.{10},
        state.water_energy_change_megajoules_per_h_by_cell,
    );
    try std.testing.expectEqualSlices(f64, &.{ 11, 12 }, &previous);
}

test "production keeps live VOLWP out of EXTRACT ENGYC" {
    const production = @embedFile("../../ecosys_ng.zig");
    const transaction = std.mem.indexOf(u8, production, "try ecosys.uptake_coupled_transaction.apply(") orelse
        return error.MissingCanopyEnergyTransaction;
    const living_surface_binding = std.mem.indexOfPos(
        u8,
        production,
        transaction,
        ".living_surface_water_m3_by_plant = retention.living_surface_water_m3",
    ) orelse return error.MissingLivingSurfaceWaterBinding;
    const dead_surface_binding = std.mem.indexOfPos(
        u8,
        production,
        living_surface_binding,
        ".standing_dead_surface_water_m3_by_plant = retention.standing_dead_surface_water_m3",
    ) orelse return error.MissingStandingDeadSurfaceWaterBinding;
    try std.testing.expect(transaction < living_surface_binding and
        living_surface_binding < dead_surface_binding);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(
            u8,
            production,
            ".living_surface_water_m3_by_plant = retention.living_surface_water_m3",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, production, ".internal_canopy_water_m3_by_plant"),
    );
}

test "signed retention follows exact EXTRACT THFLXC identity" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    const air_temperature_k: f64 = 280;
    const canopy_temperature_k: f64 = 290;
    const retained_water_m3: f64 = -0.2;
    const previous_energy: f64 = 4.19 * 1.0 * 288;
    var previous = [_]f64{previous_energy};
    try refresh(&state, .{
        .air_temperature_k_by_cell = &.{air_temperature_k},
        .canopy_temperature_k_by_plant = &.{canopy_temperature_k},
        .living_surface_water_m3_by_plant = &.{0.8},
        .standing_dead_surface_water_m3_by_plant = &.{0},
        .living_retention_m3_per_h_by_plant = &.{retained_water_m3},
        .standing_dead_retention_m3_per_h_by_plant = &.{0},
    }, &previous);
    const current = 4.19 * 0.8 * canopy_temperature_k;
    const retained_enthalpy = 4.19 * retained_water_m3 * air_temperature_k;
    try std.testing.expectApproxEqAbs(
        current - previous_energy - retained_enthalpy,
        state.water_energy_change_megajoules_per_h_by_cell[0],
        32 * std.math.floatEps(f64) * @max(1, @abs(current)),
    );
}
