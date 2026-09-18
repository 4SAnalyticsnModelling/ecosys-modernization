const std = @import("std");
const PlantDailyOutput = @import("../../io/output/plant_daily_output.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    carbon_balance_g_c_by_plant: []f64,
    nitrogen_balance_g_n_by_plant: []f64,
    phosphorus_balance_g_p_by_plant: []f64,
    carbon_balance_g_c_by_cell: []f64,
    nitrogen_balance_g_n_by_cell: []f64,
    phosphorus_balance_g_p_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0)
            return error.InvalidPlantBalanceStateUpdateDimensions;
        const plant_count = try std.math.mul(
            usize,
            cell_count,
            plant_species_per_cell,
        );
        const plant_values = try std.math.mul(usize, plant_count, 3);
        const value_count = try std.math.add(
            usize,
            plant_values,
            try std.math.mul(usize, cell_count, 3),
        );
        const values = try allocator.alloc(f64, value_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .carbon_balance_g_c_by_plant = values[0..plant_count],
            .nitrogen_balance_g_n_by_plant = values[plant_count .. 2 * plant_count],
            .phosphorus_balance_g_p_by_plant = values[2 * plant_count .. 3 * plant_count],
            .carbon_balance_g_c_by_cell = values[plant_values .. plant_values + cell_count],
            .nitrogen_balance_g_n_by_cell = values[plant_values + cell_count .. plant_values + 2 * cell_count],
            .phosphorus_balance_g_p_by_cell = values[plant_values + 2 * cell_count ..],
        };
    }

    pub fn deinit(self: *State) void {
        const plant_count = self.cell_count * self.plant_species_per_cell;
        self.allocator.free(
            self.carbon_balance_g_c_by_plant.ptr[0 .. 3 * plant_count + 3 * self.cell_count],
        );
        self.* = undefined;
    }
};

/// Reusable owner contract for one hourly EXTRACT state_update.
///
/// Every slice uses the runtime plant axis
/// `cell * plant_species_per_cell + species`. Pool inventories must be
/// assembled from current mutable canopy/root state. Ledger terms must be
/// read directly from `plant_daily_flux_ledger.State`; derived output rows
/// are not valid inputs.
pub const Inputs = struct {
    /// GROSUB `IFLGC == 1`; inactive plants are published as exact zeros.
    active_by_plant: []const bool,
    /// Current GROSUB `BALC` constituents, all in g C per plant.
    carbon_by_plant: []const PlantDailyOutput.CarbonBalanceInputs,
    /// Current GROSUB `BALN` constituents, all in g N per plant.
    nitrogen_by_plant: []const PlantDailyOutput.NutrientBalanceInputs,
    /// Current GROSUB `BALP` constituents, all in g P per plant. Atmospheric
    /// exchange and biological fixation must both be exact zero.
    phosphorus_by_plant: []const PlantDailyOutput.NutrientBalanceInputs,
};

const Balance = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

/// grosub.f lines 13071–13165 and EXTRACT lines 949–951. Each current
/// per-plant balance is evaluated in source order before the runtime species
/// axis is reduced to the cell totals formerly named TBALC/TBALN/TBALP.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (@field(inputs, field.name).len != plant_count)
            return error.InvalidPlantBalanceStateUpdateDimensions;
    }

    for (0..plant_count) |plant| _ = try balanceForPlant(inputs, plant);
    for (0..state.cell_count) |cell| _ = try balanceForCell(state, inputs, cell);

    for (0..plant_count) |plant| {
        const balance = balanceForPlant(inputs, plant) catch unreachable;
        state.carbon_balance_g_c_by_plant[plant] = balance.carbon_g_c;
        state.nitrogen_balance_g_n_by_plant[plant] = balance.nitrogen_g_n;
        state.phosphorus_balance_g_p_by_plant[plant] = balance.phosphorus_g_p;
    }
    for (0..state.cell_count) |cell| {
        const balance = balanceForCell(state, inputs, cell) catch unreachable;
        state.carbon_balance_g_c_by_cell[cell] = balance.carbon_g_c;
        state.nitrogen_balance_g_n_by_cell[cell] = balance.nitrogen_g_n;
        state.phosphorus_balance_g_p_by_cell[cell] = balance.phosphorus_g_p;
    }
}

fn balanceForPlant(inputs: Inputs, plant: usize) !Balance {
    if (!inputs.active_by_plant[plant]) return .{};
    return .{
        .carbon_g_c = try PlantDailyOutput.carbonBalance(inputs.carbon_by_plant[plant]),
        .nitrogen_g_n = try PlantDailyOutput.nitrogenBalance(inputs.nitrogen_by_plant[plant]),
        .phosphorus_g_p = try PlantDailyOutput.phosphorusBalance(inputs.phosphorus_by_plant[plant]),
    };
}

fn balanceForCell(
    state: *const State,
    inputs: Inputs,
    cell: usize,
) !Balance {
    var total: Balance = .{};
    const first = cell * state.plant_species_per_cell;
    for (first..first + state.plant_species_per_cell) |plant| {
        const balance = try balanceForPlant(inputs, plant);
        total.carbon_g_c += balance.carbon_g_c;
        total.nitrogen_g_n += balance.nitrogen_g_n;
        total.phosphorus_g_p += balance.phosphorus_g_p;
        inline for (std.meta.fields(Balance)) |field|
            if (!std.math.isFinite(@field(total, field.name)))
                return error.NonFinitePlantBalanceStateUpdate;
    }
    return total;
}

fn carbonInputs(value: f64) PlantDailyOutput.CarbonBalanceInputs {
    return .{
        .shoot_carbon_g = value,
        .root_carbon_g = value,
        .nodule_carbon_g = value,
        .storage_carbon_g = value,
        .standing_dead_carbon_g = value,
        .cumulative_carbon_sink_g = value,
        .cumulative_root_soil_carbon_exchange_g = value,
        .cumulative_carbon_balance_g = value,
        .cumulative_harvested_carbon_g = value,
        .harvested_carbon_g = value,
        .carbon_oxidation_g = value,
        .cumulative_net_primary_productivity_g = value,
    };
}

fn nutrientInputs(value: f64) PlantDailyOutput.NutrientBalanceInputs {
    return .{
        .shoot_g = value,
        .root_g = value,
        .nodule_g = value,
        .storage_g = value,
        .standing_dead_g = value,
        .cumulative_sink_g = value,
        .cumulative_root_soil_exchange_g = value,
        .cumulative_balance_g = value,
        .cumulative_harvested_g = value,
        .harvested_g = value,
        .oxidation_g = value,
        .atmospheric_exchange_g = value,
        .biological_fixation_g = value,
    };
}

test "plant balances preserve runtime species order and EXTRACT totals" {
    var state = try State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    try refresh(&state, .{
        .active_by_plant = &.{ true, true, false, true },
        .carbon_by_plant = &.{
            carbonInputs(1),
            carbonInputs(2),
            carbonInputs(std.math.nan(f64)),
            carbonInputs(4),
        },
        .nitrogen_by_plant = &.{
            nutrientInputs(1),
            nutrientInputs(2),
            nutrientInputs(std.math.nan(f64)),
            nutrientInputs(4),
        },
        .phosphorus_by_plant = &.{
            phosphorusInputs(1),
            phosphorusInputs(2),
            phosphorusInputs(std.math.nan(f64)),
            phosphorusInputs(4),
        },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 12, 16 },
        state.carbon_balance_g_c_by_cell,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 3, 6, 0, 12 },
        state.nitrogen_balance_g_n_by_plant,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 15, 20 },
        state.phosphorus_balance_g_p_by_cell,
    );
}

fn phosphorusInputs(value: f64) PlantDailyOutput.NutrientBalanceInputs {
    var inputs = nutrientInputs(value);
    inputs.atmospheric_exchange_g = 0;
    inputs.biological_fixation_g = 0;
    return inputs;
}

test "late invalid active balance preserves every published owner" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 7);
    try std.testing.expectError(
        error.NonFinitePlantOutput,
        refresh(&state, .{
            .active_by_plant = &.{ true, true },
            .carbon_by_plant = &.{ carbonInputs(1), carbonInputs(2) },
            .nitrogen_by_plant = &.{ nutrientInputs(1), nutrientInputs(std.math.nan(f64)) },
            .phosphorus_by_plant = &.{ phosphorusInputs(1), phosphorusInputs(2) },
        }),
    );
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 7), value);
}
