const std = @import("std");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    carbon_dioxide_emission_g_c_per_h_by_cell: []f64,
    methane_emission_g_c_per_h_by_cell: []f64,
    oxygen_consumption_g_o_per_h_by_cell: []f64,
    charcoal_production_g_c_per_h_by_cell: []f64,
    heat_release_megajoules_per_h_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0)
            return error.InvalidCanopyFireStateUpdateDimensions;
        const value_count = try std.math.mul(usize, cell_count, 5);
        const values = try allocator.alloc(f64, value_count);
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .carbon_dioxide_emission_g_c_per_h_by_cell = values[0..cell_count],
            .methane_emission_g_c_per_h_by_cell = values[cell_count .. 2 * cell_count],
            .oxygen_consumption_g_o_per_h_by_cell = values[2 * cell_count .. 3 * cell_count],
            .charcoal_production_g_c_per_h_by_cell = values[3 * cell_count .. 4 * cell_count],
            .heat_release_megajoules_per_h_by_cell = values[4 * cell_count ..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.carbon_dioxide_emission_g_c_per_h_by_cell.ptr[0 .. 5 * self.cell_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    fire_active_by_cell: []const bool,
    carbon_dioxide_emission_g_c_per_h_by_plant: []const f64,
    methane_emission_g_c_per_h_by_plant: []const f64,
    oxygen_consumption_g_o_per_h_by_plant: []const f64,
    charcoal_production_g_c_per_h_by_plant: []const f64,
    heat_release_megajoules_per_h_by_plant: []const f64,
};

/// EXTRACT lines 147–211 state_update of the accepted total-canopy fire
/// partition. Every cell result is preflighted before all five owners change.
pub fn refresh(state: *State, inputs: Inputs) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    if (inputs.fire_active_by_cell.len != state.cell_count)
        return error.InvalidCanopyFireStateUpdateDimensions;
    inline for (@typeInfo(Inputs).@"struct".fields[1..]) |field|
        if (@field(inputs, field.name).len != plant_count)
            return error.InvalidCanopyFireStateUpdateDimensions;

    for (0..state.cell_count) |cell|
        _ = try totalsForCell(state, inputs, cell);

    for (0..state.cell_count) |cell| {
        const totals = totalsForCell(state, inputs, cell) catch unreachable;
        state.carbon_dioxide_emission_g_c_per_h_by_cell[cell] = totals.co2;
        state.methane_emission_g_c_per_h_by_cell[cell] = totals.ch4;
        state.oxygen_consumption_g_o_per_h_by_cell[cell] = totals.oxygen;
        state.charcoal_production_g_c_per_h_by_cell[cell] = totals.charcoal;
        state.heat_release_megajoules_per_h_by_cell[cell] = totals.heat;
    }
}

const Totals = struct {
    co2: f64 = 0,
    ch4: f64 = 0,
    oxygen: f64 = 0,
    charcoal: f64 = 0,
    heat: f64 = 0,
};

fn totalsForCell(state: *const State, inputs: Inputs, cell: usize) !Totals {
    var totals: Totals = .{};
    if (!inputs.fire_active_by_cell[cell]) return totals;
    const first = cell * state.plant_species_per_cell;
    for (first..first + state.plant_species_per_cell) |plant| {
        const values = .{
            inputs.carbon_dioxide_emission_g_c_per_h_by_plant[plant],
            inputs.methane_emission_g_c_per_h_by_plant[plant],
            inputs.oxygen_consumption_g_o_per_h_by_plant[plant],
            inputs.charcoal_production_g_c_per_h_by_plant[plant],
            inputs.heat_release_megajoules_per_h_by_plant[plant],
        };
        inline for (values) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidCanopyFireStateUpdateInput;
        totals.co2 += values[0];
        totals.ch4 += values[1];
        totals.oxygen += values[2];
        totals.charcoal += values[3];
        totals.heat += values[4];
        inline for (@typeInfo(Totals).@"struct".fields) |field|
            if (!std.math.isFinite(@field(totals, field.name)))
                return error.NonFiniteCanopyFireStateUpdate;
    }
    return totals;
}

test "canopy fire state_update preserves runtime plant order and units" {
    var state = try State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    try refresh(&state, .{
        .fire_active_by_cell = &.{ true, false },
        .carbon_dioxide_emission_g_c_per_h_by_plant = &.{ 1, 10, 100, 1000 },
        .methane_emission_g_c_per_h_by_plant = &.{ 2, 20, 200, 2000 },
        .oxygen_consumption_g_o_per_h_by_plant = &.{ 3, 30, 300, 3000 },
        .charcoal_production_g_c_per_h_by_plant = &.{ 4, 40, 400, 4000 },
        .heat_release_megajoules_per_h_by_plant = &.{ 5, 50, 500, 5000 },
    });
    try std.testing.expectEqualSlices(
        f64,
        &.{ 11, 0 },
        state.carbon_dioxide_emission_g_c_per_h_by_cell,
    );
    try std.testing.expectEqual(@as(f64, 22), state.methane_emission_g_c_per_h_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 33), state.oxygen_consumption_g_o_per_h_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 44), state.charcoal_production_g_c_per_h_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 55), state.heat_release_megajoules_per_h_by_cell[0]);
}

test "late invalid active fire preserves complete state_update" {
    var state = try State.init(std.testing.allocator, 2, 2);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 7);
    try std.testing.expectError(
        error.InvalidCanopyFireStateUpdateInput,
        refresh(&state, .{
            .fire_active_by_cell = &.{ true, true },
            .carbon_dioxide_emission_g_c_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .methane_emission_g_c_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .oxygen_consumption_g_o_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .charcoal_production_g_c_per_h_by_plant = &.{ 1, 2, 3, 4 },
            .heat_release_megajoules_per_h_by_plant = &.{ 1, 2, 3, std.math.nan(f64) },
        }),
    );
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 7), value);
}
